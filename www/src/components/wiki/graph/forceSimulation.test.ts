import { describe, it, expect } from "vitest";
import { ForceSimulation, seedPosition } from "./forceSimulation";

// Characterization tests for the force-directed layout engine. They assert
// DIRECTIONAL invariants (attraction pulls connected nodes together, repulsion
// pushes coincident nodes apart, pinned nodes never move) rather than exact
// coordinates, so they stay stable across force-tuning. The pin carry-over
// across a rebuild is covered separately in graphPinCarry.test.ts.

const edge = (a: string, b: string) => ({ source: a, target: b });
const dist = (sim: ForceSimulation, i: number, j: number) =>
  Math.hypot(sim.xAt(i) - sim.xAt(j), sim.yAt(i) - sim.yAt(j));

describe("seedPosition", () => {
  it("is deterministic and varies with the index", () => {
    expect(seedPosition(0, 10)).toEqual(seedPosition(0, 10));
    expect(seedPosition(1, 10)).not.toEqual(seedPosition(0, 10));
  });
});

describe("ForceSimulation", () => {
  it("attraction pulls two connected nodes closer together", () => {
    const sim = new ForceSimulation([{ id: "a" }, { id: "b" }], [edge("a", "b")]);
    sim.setNodePosition(0, -500, 0);
    sim.setNodePosition(1, 500, 0);
    const before = dist(sim, 0, 1);
    for (let i = 0; i < 200; i++) sim.step();
    expect(dist(sim, 0, 1)).toBeLessThan(before);
  });

  it("repulsion separates two coincident, unconnected nodes", () => {
    const sim = new ForceSimulation([{ id: "a" }, { id: "b" }], []);
    sim.setNodePosition(0, 0, 0);
    sim.setNodePosition(1, 0.01, 0);
    for (let i = 0; i < 100; i++) sim.step();
    expect(dist(sim, 0, 1)).toBeGreaterThan(1);
  });

  it("a pinned node never moves under stepping", () => {
    const sim = new ForceSimulation([{ id: "a" }, { id: "b" }], [edge("a", "b")]);
    sim.setNodePosition(0, 42, -7);
    sim.pin(0);
    sim.setNodePosition(1, 300, 300);
    for (let i = 0; i < 50; i++) sim.step();
    expect(sim.xAt(0)).toBe(42);
    expect(sim.yAt(0)).toBe(-7);
    // the free node DID move under the forces
    expect(sim.xAt(1) !== 300 || sim.yAt(1) !== 300).toBe(true);
  });

  it("setNodePosition + xAt/yAt round-trip; unpin restores mobility", () => {
    const sim = new ForceSimulation([{ id: "a" }, { id: "b" }], [edge("a", "b")]);
    sim.setNodePosition(0, 12, 34);
    expect([sim.xAt(0), sim.yAt(0)]).toEqual([12, 34]);
    sim.pin(0);
    expect(sim.isPinned(0)).toBe(true);
    sim.unpin(0);
    expect(sim.isPinned(0)).toBe(false);
  });
});
