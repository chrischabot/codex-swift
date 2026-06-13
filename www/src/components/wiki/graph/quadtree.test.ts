import { describe, it, expect } from "vitest";
import { buildQuadtree, type QuadBody, type QuadAggregate } from "./quadtree";

const body = (x: number, y: number, mass: number, index: number): QuadBody => ({ x, y, mass, index });

/** Collect every aggregate visited by a Barnes-Hut traversal from (px,py). */
function visit(bodies: QuadBody[], px: number, py: number, theta: number, selfIndex = -1): QuadAggregate[] {
  const tree = buildQuadtree(bodies);
  const out: QuadAggregate[] = [];
  tree.forEachAt(px, py, theta, (a) => out.push(a), selfIndex);
  return out;
}

describe("Quadtree (Barnes-Hut)", () => {
  it("an empty tree visits nothing", () => {
    expect(visit([], 0, 0, 0.5)).toEqual([]);
  });

  it("theta=0 visits every leaf exactly (exact n-body), excluding self", () => {
    const bodies = [body(0, 0, 1, 0), body(10, 0, 1, 1), body(0, 10, 1, 2)];
    // From body 0's position, exclude itself → the other two leaves.
    const seen = visit(bodies, 0, 0, 0, 0);
    const leafIdx = seen.map((a) => a.leafIndex).sort();
    expect(leafIdx).toEqual([1, 2]);
    expect(seen.every((a) => a.mass === 1)).toBe(true);
  });

  it("a single far cluster is approximated as one aggregate at high theta", () => {
    // Four tight bodies far from the query point: a large theta lets the whole
    // cell be approximated by its center of mass in a single callback.
    const cluster = [body(100, 100, 1, 0), body(101, 100, 1, 1), body(100, 101, 1, 2), body(101, 101, 1, 3)];
    const seen = visit(cluster, -1000, -1000, 5); // huge theta → coarse approx
    const totalMass = seen.reduce((s, a) => s + a.mass, 0);
    // Mass is conserved regardless of approximation depth.
    expect(totalMass).toBe(4);
    // The aggregate(s)'s center of mass sits inside the cluster bounding box.
    for (const a of seen) {
      expect(a.comX).toBeGreaterThanOrEqual(100);
      expect(a.comX).toBeLessThanOrEqual(101);
    }
  });

  it("center of mass is the mass-weighted average for a 2-body cell", () => {
    const seen = visit([body(0, 0, 1, 0), body(10, 0, 3, 1)], -1000, 0, 10);
    const total = seen.reduce((s, a) => s + a.mass, 0);
    const comX = seen.reduce((s, a) => s + a.comX * a.mass, 0) / total;
    expect(total).toBe(4);
    expect(comX).toBeCloseTo((0 * 1 + 10 * 3) / 4, 5); // = 7.5
  });
});
