import { describe, it, expect } from "vitest";
import { ForceSimulation } from "./forceSimulation";

// Regression guard for the pinned-nodes-reset bug (M22-class): a depth/seed
// change rebuilds the simulation from scratch. WikiGraphView carries each
// pinned node's {x,y} across the rebuild keyed by id, then re-applies
// setNodePosition + pin. This test exercises that exact mechanism on the sim
// API the view depends on — pins must survive a rebuild + further stepping.

const edge = (a: string, b: string) => ({ source: a, target: b });

describe("pinned-node carry-over across a sim rebuild", () => {
  it("re-pinned nodes keep their position after rebuild + stepping", () => {
    // Sim 1: a–b–c. Pin b at a known spot.
    const sim1 = new ForceSimulation(
      [{ id: "a" }, { id: "b" }, { id: "c" }],
      [edge("a", "b"), edge("b", "c")],
    );
    sim1.setNodePosition(1, 123, -45);
    sim1.pin(1);

    // Capture pins by id (what the view does before dropping the old sim).
    const idToIndex1 = new Map([["a", 0], ["b", 1], ["c", 2]]);
    const carried = new Map<string, { x: number; y: number }>();
    for (const [id, idx] of idToIndex1) {
      if (sim1.isPinned(idx)) carried.set(id, { x: sim1.xAt(idx), y: sim1.yAt(idx) });
    }
    expect([...carried.keys()]).toEqual(["b"]);

    // Sim 2 (depth grew): b–c–d–e, "a" gone, "d"/"e" new. Restore carried pins.
    const sim2 = new ForceSimulation(
      [{ id: "b" }, { id: "c" }, { id: "d" }, { id: "e" }],
      [edge("b", "c"), edge("c", "d"), edge("d", "e")],
    );
    const idToIndex2 = new Map([["b", 0], ["c", 1], ["d", 2], ["e", 3]]);
    for (const [id, pos] of carried) {
      const ni = idToIndex2.get(id);
      if (ni !== undefined) {
        sim2.setNodePosition(ni, pos.x, pos.y);
        sim2.pin(ni);
      }
    }

    const bIdx = idToIndex2.get("b")!;
    expect(sim2.isPinned(bIdx)).toBe(true);
    expect(sim2.xAt(bIdx)).toBe(123);
    expect(sim2.yAt(bIdx)).toBe(-45);

    // Stepping the simulation must NOT move the pinned node.
    for (let i = 0; i < 50; i++) sim2.step();
    expect(sim2.xAt(bIdx)).toBe(123);
    expect(sim2.yAt(bIdx)).toBe(-45);
  });
});
