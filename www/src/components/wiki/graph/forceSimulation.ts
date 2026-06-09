/**
 * Force-directed layout for the wiki graph view.
 *
 * Ported to pure, framework-agnostic TypeScript (no React, no DOM). This is the
 * layout engine consumed by the canvas view — keep the API clean and stable.
 *
 * Design choices (carried over from the granite original):
 *   - Repulsion uses a Barnes-Hut quadtree (O(n log n)) instead of pairwise
 *     loops. Theta defaults to 0.85 — empirically a sweet spot between speed
 *     and visual quality.
 *   - Edge attraction is a Hooke spring with `linkDistance` rest length and
 *     `attraction` stiffness.
 *   - Gentle center gravity prevents the cloud from drifting off-screen.
 *   - Velocity-Verlet style integrator with explicit damping per step. This
 *     handles large repulsion magnitudes without exploding because we cap
 *     per-step displacement at `maxStep`.
 *   - All numeric state lives in plain Float64Arrays so the simulation can be
 *     stepped from a rAF loop without allocating per frame.
 *
 * Determinism: initial positions are seeded from a golden-angle (sunflower)
 * spiral keyed purely on the node's array index. NO random API is called, so
 * the layout is fully reproducible across runs and runtimes (some workflow
 * runtimes do not expose Math.random / crypto). The same input always produces
 * the same layout.
 */

import { type QuadBody, buildQuadtree } from "./quadtree";

export const DEFAULT_THETA = 0.85;

/** A node as accepted by the simulation. Only `id` is required. */
export interface SimNode {
  /** Stable identity. Edges reference nodes by this id. */
  readonly id: string;
  /**
   * Mass. Defaults to `1 + log2(1 + weight)` when `weight` is supplied, else 1.
   * Heavier nodes repel harder and resist being flung around.
   */
  readonly mass?: number;
  /** Degree-ish weight (e.g. from WikiGraphNode.weight). Influences default mass. */
  readonly weight?: number;
}

/** An edge referencing two node ids. Unknown ids are ignored. */
export interface SimEdge {
  readonly source: string;
  readonly target: string;
}

/**
 * Tunable forces. All optional on the public `setForces` surface; the
 * constructor fills in defaults for anything omitted.
 */
export interface ForceConfig {
  /** Repulsion magnitude (k in -k*m_i*m_j/r^2). Higher = more spread out. */
  repulsion?: number;
  /** Spring stiffness for edges. Higher = tighter clusters. */
  attraction?: number;
  /** Spring rest length (target edge length in world units). */
  linkDistance?: number;
  /** Pull toward origin. Keeps the cloud centered. */
  centerGravity?: number;
}

/** Full parameter set, including integrator + annealing knobs. */
export interface ForceParams extends ForceConfig {
  /** Barnes-Hut opening angle. */
  theta?: number;
  /** Velocity damping (0..1, 1 = no damping). */
  damping?: number;
  /** Integration timestep — kept around 1 for stability with our forces. */
  dt?: number;
  /** Hard cap on per-step displacement to avoid blow-ups. */
  maxStep?: number;
  /** Starting "temperature". Forces (except center pull) scale by alpha. */
  alpha?: number;
  /** Multiplicative cooling factor applied each step (d3-style). */
  alphaDecay?: number;
  /** Floor below which the simulation is considered settled. */
  alphaMin?: number;
}

type ResolvedParams = Required<ForceParams>;

const DEFAULTS: ResolvedParams = {
  repulsion: 1200,
  attraction: 0.05,
  linkDistance: 80,
  centerGravity: 0.02,
  theta: DEFAULT_THETA,
  damping: 0.6,
  dt: 1,
  maxStep: 32,
  alpha: 1,
  alphaDecay: 0.0228,
  alphaMin: 0.001,
};

/** Golden angle in radians — the irrational rotation behind sunflower spirals. */
const GOLDEN_ANGLE = Math.PI * (3 - Math.sqrt(5));

/**
 * Deterministic initial position for node `i` of `n`, on a golden-angle spiral.
 * Radius grows as sqrt(i) so points are evenly area-distributed. `spread`
 * scales the whole layout. Pure function of the index — no randomness.
 */
export function seedPosition(i: number, n: number, spread = 30): { x: number; y: number } {
  const radius = spread * Math.sqrt(i + 0.5);
  const angle = i * GOLDEN_ANGLE;
  return { x: radius * Math.cos(angle), y: radius * Math.sin(angle) };
}

export class ForceSimulation {
  /** Number of nodes. */
  readonly count: number;
  /** Node x positions, indexed by node order. */
  readonly x: Float64Array;
  /** Node y positions, indexed by node order. */
  readonly y: Float64Array;
  /** Node x velocities. */
  readonly vx: Float64Array;
  /** Node y velocities. */
  readonly vy: Float64Array;
  /** Node masses. */
  readonly mass: Float64Array;
  /**
   * Per-node pin flag (1 = pinned). Pinned nodes ignore all forces and keep
   * their current position — used for drag-to-pin in the view. Mutated via
   * {@link pin} / {@link unpin} / {@link setNodePosition}.
   */
  readonly pinned: Uint8Array;
  /** Ordered node ids — index `i` here corresponds to x[i]/y[i]. */
  readonly ids: ReadonlyArray<string>;

  private readonly indexById: Map<string, number>;
  private readonly edgeSrc: Int32Array;
  private readonly edgeDst: Int32Array;
  private readonly edgeCount: number;
  private params: ResolvedParams;

  /** Last computed total kinetic energy — useful for early stopping. */
  energy = Number.POSITIVE_INFINITY;
  /** Current annealing temperature. Decays each step. */
  alpha: number;

  // Reused scratch buffers — avoid per-step allocation in the rAF loop.
  private readonly fx: Float64Array;
  private readonly fy: Float64Array;
  private readonly bodies: QuadBody[];

  constructor(
    nodes: ReadonlyArray<SimNode>,
    edges: ReadonlyArray<SimEdge>,
    params: ForceParams = {},
  ) {
    this.count = nodes.length;
    this.x = new Float64Array(this.count);
    this.y = new Float64Array(this.count);
    this.vx = new Float64Array(this.count);
    this.vy = new Float64Array(this.count);
    this.mass = new Float64Array(this.count);
    this.pinned = new Uint8Array(this.count);
    this.indexById = new Map();
    const ids: string[] = new Array(this.count);

    for (let i = 0; i < this.count; i++) {
      const n = nodes[i];
      ids[i] = n.id;
      this.indexById.set(n.id, i);
      const seed = seedPosition(i, this.count);
      this.x[i] = seed.x;
      this.y[i] = seed.y;
      this.mass[i] = resolveMass(n);
    }
    this.ids = ids;

    // Resolve edges to node indices; drop edges referencing unknown ids.
    const src: number[] = [];
    const dst: number[] = [];
    for (const e of edges) {
      const a = this.indexById.get(e.source);
      const b = this.indexById.get(e.target);
      if (a === undefined || b === undefined || a === b) continue;
      src.push(a);
      dst.push(b);
    }
    this.edgeCount = src.length;
    this.edgeSrc = Int32Array.from(src);
    this.edgeDst = Int32Array.from(dst);

    this.params = { ...DEFAULTS, ...stripUndefined(params) };
    this.alpha = this.params.alpha;

    this.fx = new Float64Array(this.count);
    this.fy = new Float64Array(this.count);
    this.bodies = new Array(this.count);
  }

  /**
   * Replace the tunable forces. Unspecified keys keep their current value.
   * Does NOT reheat — call `reheat()` afterwards if you want the layout to
   * react immediately to the new forces.
   */
  setForces(config: ForceConfig & Pick<ForceParams, "theta">): void {
    this.params = { ...this.params, ...stripUndefined(config) };
  }

  /** Read the full resolved parameter set (copy). */
  getParams(): ResolvedParams {
    return { ...this.params };
  }

  /** Re-anneal: bump alpha back up so the layout reacts to a graph change. */
  reheat(alpha = 1): void {
    this.alpha = alpha;
  }

  /** True while the layout is still "hot" (alpha above the settle floor). */
  get isHot(): boolean {
    return this.alpha > this.params.alphaMin;
  }

  /**
   * Advance the simulation by one step.
   * @returns `true` while still hot (alpha > alphaMin), `false` once settled.
   *          A rAF driver can stop ticking when this returns `false`.
   */
  tick(): boolean {
    this.step();
    return this.isHot;
  }

  /** Advance one step and return the total kinetic energy (low-level). */
  step(): number {
    const {
      repulsion,
      attraction,
      centerGravity,
      linkDistance,
      theta,
      damping,
      dt,
      maxStep,
      alphaDecay,
      alphaMin,
    } = this.params;

    // Anneal: cool the system each step. Once alpha < alphaMin we hold it there
    // and the simulation is essentially frozen.
    if (this.alpha > alphaMin) {
      this.alpha = Math.max(alphaMin, this.alpha - (this.alpha - alphaMin) * alphaDecay);
    }
    const alpha = this.alpha;

    // 1) Build quadtree from current positions (reuse the body objects).
    for (let i = 0; i < this.count; i++) {
      this.bodies[i] = {
        x: this.x[i] ?? 0,
        y: this.y[i] ?? 0,
        mass: this.mass[i] ?? 1,
        index: i,
      };
    }
    const tree = buildQuadtree(this.bodies);

    const fx = this.fx;
    const fy = this.fy;
    fx.fill(0);
    fy.fill(0);

    // 2) Repulsion via Barnes-Hut. Each cell exerts -repulsion*mi*mj/r^2 on the
    // query point, directed away from the cell's center of mass.
    for (let i = 0; i < this.count; i++) {
      const px = this.x[i] ?? 0;
      const py = this.y[i] ?? 0;
      const pm = this.mass[i] ?? 1;
      let ax = 0;
      let ay = 0;
      tree.forEachAt(
        px,
        py,
        theta,
        (agg) => {
          let dx = px - agg.comX;
          let dy = py - agg.comY;
          let d2 = dx * dx + dy * dy;
          if (d2 < 1e-6) {
            // Jitter coincident bodies deterministically based on indices.
            const seed = (i * 16807 + agg.leafIndex * 2147483647) | 0;
            dx = ((seed & 0xffff) / 0xffff - 0.5) * 0.02;
            dy = (((seed >> 16) & 0xffff) / 0xffff - 0.5) * 0.02;
            d2 = dx * dx + dy * dy + 1e-6;
          }
          // Soft minimum distance — avoid singularities.
          if (d2 < 1) d2 = 1;
          const invD = 1 / Math.sqrt(d2);
          const f = (repulsion * pm * agg.mass * alpha) / d2;
          ax += dx * invD * f;
          ay += dy * invD * f;
        },
        i,
      );
      fx[i] = (fx[i] ?? 0) + ax;
      fy[i] = (fy[i] ?? 0) + ay;
    }

    // 3) Spring attraction along edges.
    for (let e = 0; e < this.edgeCount; e++) {
      const a = this.edgeSrc[e] ?? -1;
      const b = this.edgeDst[e] ?? -1;
      if (a < 0 || b < 0 || a >= this.count || b >= this.count) continue;
      const ax = this.x[a] ?? 0;
      const ay = this.y[a] ?? 0;
      const bx = this.x[b] ?? 0;
      const by = this.y[b] ?? 0;
      let dx = bx - ax;
      let dy = by - ay;
      let dist = Math.sqrt(dx * dx + dy * dy);
      if (dist < 1e-6) {
        dx = 1;
        dy = 0;
        dist = 1;
      }
      const stretch = dist - linkDistance;
      const f = stretch * attraction * alpha;
      const fxComp = (dx / dist) * f;
      const fyComp = (dy / dist) * f;
      fx[a] = (fx[a] ?? 0) + fxComp;
      fy[a] = (fy[a] ?? 0) + fyComp;
      fx[b] = (fx[b] ?? 0) - fxComp;
      fy[b] = (fy[b] ?? 0) - fyComp;
    }

    // 4) Center pull + integrate (Verlet-style with damping).
    let energy = 0;
    for (let i = 0; i < this.count; i++) {
      // Pinned nodes are held fixed: zero velocity, ignore all accumulated
      // forces, keep position. (Used for drag-to-pin in the view.)
      if (this.pinned[i]) {
        this.vx[i] = 0;
        this.vy[i] = 0;
        continue;
      }
      const px = this.x[i] ?? 0;
      const py = this.y[i] ?? 0;
      const m = this.mass[i] ?? 1;
      // Center gravity scales with position (linear pull).
      const cx = -px * centerGravity * m * alpha;
      const cy = -py * centerGravity * m * alpha;
      const accX = ((fx[i] ?? 0) + cx) / m;
      const accY = ((fy[i] ?? 0) + cy) / m;

      let nvx = ((this.vx[i] ?? 0) + accX * dt) * damping;
      let nvy = ((this.vy[i] ?? 0) + accY * dt) * damping;

      // Clamp step length so a single huge repulsion can't fling a node out.
      const stepLen = Math.hypot(nvx * dt, nvy * dt);
      if (stepLen > maxStep) {
        const k = maxStep / stepLen;
        nvx *= k;
        nvy *= k;
      }

      // Guard against NaN / Infinity poisoning the simulation.
      if (!Number.isFinite(nvx) || !Number.isFinite(nvy)) {
        nvx = 0;
        nvy = 0;
      }

      this.vx[i] = nvx;
      this.vy[i] = nvy;
      this.x[i] = px + nvx * dt;
      this.y[i] = py + nvy * dt;
      energy += 0.5 * m * (nvx * nvx + nvy * nvy);
    }

    this.energy = energy;
    return energy;
  }

  // --- Readers / hit-testing -------------------------------------------------

  /** World-space x of node at index `i` (NaN if out of range). */
  xAt(i: number): number {
    return i >= 0 && i < this.count ? (this.x[i] ?? Number.NaN) : Number.NaN;
  }

  /** World-space y of node at index `i` (NaN if out of range). */
  yAt(i: number): number {
    return i >= 0 && i < this.count ? (this.y[i] ?? Number.NaN) : Number.NaN;
  }

  /** Map a node id to its array index, or -1 if unknown. */
  indexOf(id: string): number {
    return this.indexById.get(id) ?? -1;
  }

  /** Position of a node by id, or null if unknown. */
  positionOf(id: string): { x: number; y: number } | null {
    const i = this.indexById.get(id);
    if (i === undefined) return null;
    return { x: this.x[i] ?? 0, y: this.y[i] ?? 0 };
  }

  /**
   * Imperatively move node `i` to a world-space point and zero its velocity.
   * Used while dragging a node so it tracks the cursor without the integrator
   * fighting the move. No-op for out-of-range indices.
   */
  setNodePosition(i: number, x: number, y: number): void {
    if (i < 0 || i >= this.count) return;
    this.x[i] = x;
    this.y[i] = y;
    this.vx[i] = 0;
    this.vy[i] = 0;
  }

  /** Pin node `i` so the simulation holds it fixed. No-op if out of range. */
  pin(i: number): void {
    if (i < 0 || i >= this.count) return;
    this.pinned[i] = 1;
    this.vx[i] = 0;
    this.vy[i] = 0;
  }

  /** Release a previously pinned node so forces act on it again. */
  unpin(i: number): void {
    if (i < 0 || i >= this.count) return;
    this.pinned[i] = 0;
  }

  /** Whether node `i` is currently pinned. */
  isPinned(i: number): boolean {
    return i >= 0 && i < this.count && this.pinned[i] === 1;
  }

  /**
   * Nearest node to a world-space point, within `radius` world units.
   * @returns the matching node's index + id + distance, or null if none within radius.
   *          When `radius` is omitted, returns the globally nearest node.
   */
  hitTest(
    wx: number,
    wy: number,
    radius = Number.POSITIVE_INFINITY,
  ): { index: number; id: string; distance: number } | null {
    let best = -1;
    let bestD2 = radius * radius;
    for (let i = 0; i < this.count; i++) {
      const dx = (this.x[i] ?? 0) - wx;
      const dy = (this.y[i] ?? 0) - wy;
      const d2 = dx * dx + dy * dy;
      if (d2 <= bestD2) {
        bestD2 = d2;
        best = i;
      }
    }
    if (best < 0) return null;
    return { index: best, id: this.ids[best], distance: Math.sqrt(bestD2) };
  }

  /** Axis-aligned bounding box of all node positions ({x,y,width,height}). */
  bounds(): { minX: number; minY: number; maxX: number; maxY: number } {
    if (this.count === 0) return { minX: 0, minY: 0, maxX: 0, maxY: 0 };
    let minX = Number.POSITIVE_INFINITY;
    let minY = Number.POSITIVE_INFINITY;
    let maxX = Number.NEGATIVE_INFINITY;
    let maxY = Number.NEGATIVE_INFINITY;
    for (let i = 0; i < this.count; i++) {
      const px = this.x[i] ?? 0;
      const py = this.y[i] ?? 0;
      if (px < minX) minX = px;
      if (py < minY) minY = py;
      if (px > maxX) maxX = px;
      if (py > maxY) maxY = py;
    }
    return { minX, minY, maxX, maxY };
  }

  /** Snapshot positions into caller-provided typed arrays (avoids allocation). */
  copyPositionsInto(outX: Float64Array, outY: Float64Array): void {
    outX.set(this.x);
    outY.set(this.y);
  }
}

/**
 * Convenience factory mirroring the class constructor — some call sites prefer
 * a function over `new`.
 */
export function createForceSimulation(
  nodes: ReadonlyArray<SimNode>,
  edges: ReadonlyArray<SimEdge>,
  params?: ForceParams,
): ForceSimulation {
  return new ForceSimulation(nodes, edges, params);
}

/**
 * Run `steps` iterations eagerly and return the settled simulation. Useful for
 * pre-warming a layout off the render loop or for tests. `onStep` observes
 * per-step energy.
 */
export function runSimulation(
  nodes: ReadonlyArray<SimNode>,
  edges: ReadonlyArray<SimEdge>,
  params: ForceParams,
  steps: number,
  onStep?: (i: number, energy: number) => void,
): ForceSimulation {
  const sim = new ForceSimulation(nodes, edges, params);
  for (let i = 0; i < steps; i++) {
    const e = sim.step();
    onStep?.(i, e);
  }
  return sim;
}

function resolveMass(n: SimNode): number {
  if (typeof n.mass === "number" && n.mass > 0) return n.mass;
  if (typeof n.weight === "number" && n.weight > 0) {
    return 1 + Math.log2(1 + n.weight);
  }
  return 1;
}

/** Drop keys whose value is `undefined` so spreads don't clobber defaults. */
function stripUndefined<T extends object>(obj: T): Partial<T> {
  const out: Partial<T> = {};
  for (const k in obj) {
    const v = obj[k];
    if (v !== undefined) out[k] = v;
  }
  return out;
}
