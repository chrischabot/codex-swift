/**
 * Barnes-Hut quadtree for fast O(n log n) all-pairs repulsion.
 *
 * Ported, framework-agnostic (no React, no DOM). Build the tree by repeatedly
 * calling `insert` with a `{x, y, mass}` body, then call `forEachAt` for each
 * query point. The traversal callback is invoked with either:
 *   - a leaf body (when the node is a single point), or
 *   - an internal node treated as a single pseudo-body at its center of mass
 *     (when `(size + offset) / distance < theta`).
 *
 * The tree is allocated as flat parallel arrays to keep allocation low and
 * cache locality high — this is the inner loop of the simulation, so every
 * cycle matters.
 */

const ROOT = 0;

// Children are encoded as 4 ints per node; -1 = no child. A leaf is identified
// by having no children AND a non-negative bodyIndex.
const CHILD_NW = 0;
const CHILD_NE = 1;
const CHILD_SW = 2;
const CHILD_SE = 3;

export interface QuadBody {
  readonly x: number;
  readonly y: number;
  readonly mass: number;
  /** Caller-supplied payload; passed through to traversal callback. */
  readonly index: number;
}

export interface QuadAggregate {
  /** Total mass of the subtree (or a leaf body's mass). */
  readonly mass: number;
  /** Center-of-mass x. */
  readonly comX: number;
  /** Center-of-mass y. */
  readonly comY: number;
  /** Bounding box side length (max of width / height of region). */
  readonly size: number;
  /** Leaf body index, or -1 for internal nodes. */
  readonly leafIndex: number;
}

export class Quadtree {
  // Region (axis-aligned). Stays constant after construction.
  private readonly originX: number;
  private readonly originY: number;
  private readonly extent: number;

  // Parallel arrays — node i lives at offsets [4*i, 4*i+1, 4*i+2, 4*i+3] in
  // childArr; nodeX/Y/Mass/Size/Body track per-node state.
  private childArr: Int32Array;
  private nodeX: Float64Array;
  private nodeY: Float64Array;
  private nodeMass: Float64Array;
  private nodeSize: Float64Array;
  private nodeBody: Int32Array;
  private regionX: Float64Array;
  private regionY: Float64Array;
  private regionHalf: Float64Array;

  private nodeCount = 0;
  private capacity: number;

  constructor(originX: number, originY: number, extent: number) {
    if (!(extent > 0)) throw new Error("Quadtree extent must be > 0");
    this.originX = originX;
    this.originY = originY;
    this.extent = extent;
    this.capacity = 64;
    this.childArr = new Int32Array(this.capacity * 4).fill(-1);
    this.nodeX = new Float64Array(this.capacity);
    this.nodeY = new Float64Array(this.capacity);
    this.nodeMass = new Float64Array(this.capacity);
    this.nodeSize = new Float64Array(this.capacity);
    this.nodeBody = new Int32Array(this.capacity).fill(-1);
    this.regionX = new Float64Array(this.capacity);
    this.regionY = new Float64Array(this.capacity);
    this.regionHalf = new Float64Array(this.capacity);
    // Root node spans the whole region.
    this.allocateNode(originX, originY, extent / 2);
  }

  /** Helpful for tests / diagnostics. */
  get size(): number {
    return this.nodeCount;
  }

  private allocateNode(cx: number, cy: number, half: number): number {
    if (this.nodeCount === this.capacity) this.grow();
    const i = this.nodeCount++;
    this.nodeX[i] = 0;
    this.nodeY[i] = 0;
    this.nodeMass[i] = 0;
    this.nodeSize[i] = half * 2;
    this.nodeBody[i] = -1;
    this.regionX[i] = cx;
    this.regionY[i] = cy;
    this.regionHalf[i] = half;
    const base = i * 4;
    this.childArr[base] = -1;
    this.childArr[base + 1] = -1;
    this.childArr[base + 2] = -1;
    this.childArr[base + 3] = -1;
    return i;
  }

  private grow(): void {
    const next = this.capacity * 2;
    const newChild = new Int32Array(next * 4).fill(-1);
    newChild.set(this.childArr);
    this.childArr = newChild;
    const grow1 = (src: Float64Array) => {
      const dst = new Float64Array(next);
      dst.set(src);
      return dst;
    };
    const grow1i = (src: Int32Array, fill = 0) => {
      const dst = new Int32Array(next);
      if (fill !== 0) dst.fill(fill);
      dst.set(src);
      return dst;
    };
    this.nodeX = grow1(this.nodeX);
    this.nodeY = grow1(this.nodeY);
    this.nodeMass = grow1(this.nodeMass);
    this.nodeSize = grow1(this.nodeSize);
    this.nodeBody = grow1i(this.nodeBody, -1);
    this.regionX = grow1(this.regionX);
    this.regionY = grow1(this.regionY);
    this.regionHalf = grow1(this.regionHalf);
    this.capacity = next;
  }

  /** Insert a body. Coordinates outside the configured region are routed to the nearest quadrant (not clamped) and collapsed at the depth cap. */
  insert(body: QuadBody): void {
    if (!Number.isFinite(body.x) || !Number.isFinite(body.y) || !Number.isFinite(body.mass)) {
      return;
    }
    this.insertInto(ROOT, body, 0);
  }

  private insertInto(nodeIdx: number, body: QuadBody, depth: number): void {
    // Hard cap to avoid pathological recursion for near-coincident points.
    if (depth > 48) {
      // Merge into the current node as a virtual cluster. We treat this as
      // an internal node from here on (mark body=-1) so traversal averages
      // them with neighbours rather than spinning on a single leaf index.
      this.accumulate(nodeIdx, body.x, body.y, body.mass);
      this.nodeBody[nodeIdx] = -1;
      return;
    }

    const base = nodeIdx * 4;
    const existingBody = this.nodeBody[nodeIdx] ?? -1;
    const isInternal =
      this.childArr[base] !== -1 ||
      this.childArr[base + 1] !== -1 ||
      this.childArr[base + 2] !== -1 ||
      this.childArr[base + 3] !== -1;

    if (!isInternal && existingBody === -1) {
      // Empty leaf — store body directly.
      this.nodeBody[nodeIdx] = body.index;
      this.nodeX[nodeIdx] = body.x;
      this.nodeY[nodeIdx] = body.y;
      this.nodeMass[nodeIdx] = body.mass;
      return;
    }

    if (!isInternal && existingBody !== -1) {
      // Single-body leaf — must subdivide.
      const prevX = this.nodeX[nodeIdx] ?? 0;
      const prevY = this.nodeY[nodeIdx] ?? 0;
      const prevMass = this.nodeMass[nodeIdx] ?? 0;
      const prevIdx = existingBody;
      // Reset to internal-node state. Aggregate values will be filled in
      // after both bodies are pushed down.
      this.nodeBody[nodeIdx] = -1;
      this.nodeMass[nodeIdx] = 0;
      this.nodeX[nodeIdx] = 0;
      this.nodeY[nodeIdx] = 0;

      this.pushBodyDown(nodeIdx, prevX, prevY, prevMass, prevIdx, depth);
      this.pushBodyDown(nodeIdx, body.x, body.y, body.mass, body.index, depth);
      return;
    }

    // Internal node — accumulate into aggregate then descend.
    this.accumulate(nodeIdx, body.x, body.y, body.mass);
    const childIdx = this.childIndex(nodeIdx, body.x, body.y);
    let child = this.childArr[nodeIdx * 4 + childIdx];
    if (child === -1 || child === undefined) {
      child = this.createChild(nodeIdx, childIdx);
    }
    this.insertInto(child, body, depth + 1);
  }

  private pushBodyDown(
    parentIdx: number,
    x: number,
    y: number,
    mass: number,
    bodyIndex: number,
    depth: number,
  ): void {
    this.accumulate(parentIdx, x, y, mass);
    const ci = this.childIndex(parentIdx, x, y);
    let child = this.childArr[parentIdx * 4 + ci];
    if (child === -1 || child === undefined) {
      child = this.createChild(parentIdx, ci);
    }
    this.insertInto(child, { x, y, mass, index: bodyIndex }, depth + 1);
  }

  private accumulate(nodeIdx: number, x: number, y: number, mass: number): void {
    const m0 = this.nodeMass[nodeIdx] ?? 0;
    const m1 = m0 + mass;
    if (m1 <= 0) return;
    const x0 = this.nodeX[nodeIdx] ?? 0;
    const y0 = this.nodeY[nodeIdx] ?? 0;
    this.nodeX[nodeIdx] = (x0 * m0 + x * mass) / m1;
    this.nodeY[nodeIdx] = (y0 * m0 + y * mass) / m1;
    this.nodeMass[nodeIdx] = m1;
  }

  private childIndex(nodeIdx: number, x: number, y: number): number {
    const cx = this.regionX[nodeIdx] ?? 0;
    const cy = this.regionY[nodeIdx] ?? 0;
    const east = x >= cx;
    const south = y >= cy;
    if (south) return east ? CHILD_SE : CHILD_SW;
    return east ? CHILD_NE : CHILD_NW;
  }

  private createChild(parentIdx: number, childIdx: number): number {
    const half = (this.regionHalf[parentIdx] ?? 0) / 2;
    const cx = this.regionX[parentIdx] ?? 0;
    const cy = this.regionY[parentIdx] ?? 0;
    let nx = cx;
    let ny = cy;
    switch (childIdx) {
      case CHILD_NW:
        nx = cx - half;
        ny = cy - half;
        break;
      case CHILD_NE:
        nx = cx + half;
        ny = cy - half;
        break;
      case CHILD_SW:
        nx = cx - half;
        ny = cy + half;
        break;
      case CHILD_SE:
        nx = cx + half;
        ny = cy + half;
        break;
    }
    const newIdx = this.allocateNode(nx, ny, half);
    this.childArr[parentIdx * 4 + childIdx] = newIdx;
    return newIdx;
  }

  /**
   * Walk the tree from a query point, calling `fn` for each effective body.
   * `theta` controls the open-angle criterion: cell is summarized when
   * `cellSize / distance < theta`. Theta=0 forces an exact O(n) walk; the
   * typical Barnes-Hut value is around 0.85.
   *
   * `selfIndex` (optional) skips the same body when it appears as a leaf so
   * callers can iterate over their own positions safely.
   */
  forEachAt(
    px: number,
    py: number,
    theta: number,
    fn: (aggregate: QuadAggregate) => void,
    selfIndex = -1,
  ): void {
    const theta2 = theta * theta;
    // Stack for iterative traversal — avoids deep recursion at 10k+ nodes.
    const stack: number[] = [ROOT];
    while (stack.length > 0) {
      const nodeIdx = stack.pop();
      if (nodeIdx === undefined) break;
      const mass = this.nodeMass[nodeIdx] ?? 0;
      if (mass <= 0) continue;
      const comX = this.nodeX[nodeIdx] ?? 0;
      const comY = this.nodeY[nodeIdx] ?? 0;
      const size = this.nodeSize[nodeIdx] ?? 0;
      const leafIndex = this.nodeBody[nodeIdx] ?? -1;
      const base = nodeIdx * 4;
      const c0 = this.childArr[base] ?? -1;
      const c1 = this.childArr[base + 1] ?? -1;
      const c2 = this.childArr[base + 2] ?? -1;
      const c3 = this.childArr[base + 3] ?? -1;
      const isLeaf = c0 === -1 && c1 === -1 && c2 === -1 && c3 === -1;

      if (isLeaf) {
        if (leafIndex === selfIndex) continue;
        fn({ mass, comX, comY, size, leafIndex });
        continue;
      }

      const dx = comX - px;
      const dy = comY - py;
      const dist2 = dx * dx + dy * dy;
      // Theta criterion: (size + offset)/dist < theta. Including the offset
      // between geometric center and center-of-mass (Salmon & Warren correction)
      // gives noticeably better accuracy at the same theta because it accounts
      // for asymmetric mass distributions inside the cell.
      const rx = this.regionX[nodeIdx] ?? 0;
      const ry = this.regionY[nodeIdx] ?? 0;
      const offset = Math.hypot(comX - rx, comY - ry);
      const effective = size + offset;
      if (theta2 > 0 && effective * effective < theta2 * dist2) {
        fn({ mass, comX, comY, size, leafIndex: -1 });
        continue;
      }

      // Descend.
      if (c0 !== -1) stack.push(c0);
      if (c1 !== -1) stack.push(c1);
      if (c2 !== -1) stack.push(c2);
      if (c3 !== -1) stack.push(c3);
    }
  }

  /** Diagnostics for the test suite. */
  get rootMass(): number {
    return this.nodeMass[ROOT] ?? 0;
  }
}

/** Convenience factory: pick a region that contains all bodies. */
export function buildQuadtree(bodies: ReadonlyArray<QuadBody>, padding = 16): Quadtree {
  if (bodies.length === 0) {
    return new Quadtree(0, 0, 1);
  }
  let minX = Number.POSITIVE_INFINITY;
  let minY = Number.POSITIVE_INFINITY;
  let maxX = Number.NEGATIVE_INFINITY;
  let maxY = Number.NEGATIVE_INFINITY;
  for (const b of bodies) {
    if (!Number.isFinite(b.x) || !Number.isFinite(b.y)) continue;
    if (b.x < minX) minX = b.x;
    if (b.y < minY) minY = b.y;
    if (b.x > maxX) maxX = b.x;
    if (b.y > maxY) maxY = b.y;
  }
  if (!Number.isFinite(minX)) {
    return new Quadtree(0, 0, 1);
  }
  const cx = (minX + maxX) / 2;
  const cy = (minY + maxY) / 2;
  const extent = Math.max(maxX - minX, maxY - minY, 1) + padding;
  const tree = new Quadtree(cx, cy, extent);
  for (const b of bodies) tree.insert(b);
  return tree;
}
