import { describe, it, expect } from "vitest";
import { cloneSelection, type CanvasNode, type CanvasEdge } from "./canvasSchema";

const n = (id: string, x = 0, y = 0): CanvasNode => ({ id, type: "text", x, y, w: 100, h: 50, text: id });
const e = (id: string, from: string, to: string): CanvasEdge => ({ id, fromNode: from, toNode: to });

// Deterministic id generator for tests.
function counter(prefix = "c") {
  let i = 0;
  return () => `${prefix}${++i}`;
}

describe("cloneSelection", () => {
  it("clones selected nodes with fresh ids and an offset", () => {
    const nodes = [n("a", 10, 20), n("b", 30, 40)];
    const r = cloneSelection(nodes, [], new Set(["a"]), 16, counter());
    expect(r.nodes).toEqual([{ ...n("a", 26, 36), id: "c1" }]);
    expect(r.newIds).toEqual(["c1"]);
  });

  it("ignores unselected nodes", () => {
    const r = cloneSelection([n("a"), n("b")], [], new Set(["b"]), 0, counter());
    expect(r.nodes.map((x) => x.text)).toEqual(["b"]);
  });

  it("clones an edge only when BOTH endpoints are selected, remapping ids", () => {
    const nodes = [n("a"), n("b"), n("c")];
    const edges = [e("e1", "a", "b"), e("e2", "b", "c")]; // e2 → c is unselected
    const r = cloneSelection(nodes, edges, new Set(["a", "b"]), 16, counter());
    expect(r.nodes).toHaveLength(2);
    expect(r.edges).toHaveLength(1); // only e1 (a→b) survives
    // The cloned edge points at the CLONED node ids, not the originals.
    const [a2, b2] = r.newIds;
    expect(r.edges[0]).toMatchObject({ fromNode: a2, toNode: b2 });
    expect([r.edges[0].fromNode, r.edges[0].toNode]).not.toContain("a");
  });

  it("returns empties for an empty selection", () => {
    expect(cloneSelection([n("a")], [], new Set(), 16, counter())).toEqual({ nodes: [], edges: [], newIds: [] });
  });

  it("clones a self-loop edge (both endpoints the same selected node)", () => {
    const r = cloneSelection([n("a")], [e("loop", "a", "a")], new Set(["a"]), 8, counter());
    expect(r.nodes).toHaveLength(1);
    expect(r.edges).toHaveLength(1);
    expect(r.edges[0].fromNode).toBe(r.edges[0].toNode);
    expect(r.edges[0].fromNode).toBe(r.newIds[0]);
  });

  it("drops a dangling edge whose endpoint isn't a node", () => {
    const r = cloneSelection([n("a")], [e("d", "a", "ghost")], new Set(["a"]), 8, counter());
    expect(r.edges).toHaveLength(0);
  });

  it("preserves node properties (color, type) on the clone", () => {
    const node: CanvasNode = { id: "g", type: "group", x: 0, y: 0, w: 200, h: 200, label: "G", color: "3" };
    const r = cloneSelection([node], [], new Set(["g"]), 8, counter());
    expect(r.nodes[0]).toMatchObject({ type: "group", label: "G", color: "3", x: 8, y: 8 });
    expect(r.nodes[0].id).not.toBe("g");
  });
});
