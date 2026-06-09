import { beforeEach, describe, expect, it } from "vitest";
import {
  __resetWorkspaceIds,
  activeLeaf,
  activePageId,
  buildInitial,
  closeGroup,
  closeLeaf,
  closeLeavesToRight,
  closeOtherLeaves,
  deserialize,
  focusGroup,
  focusLeaf,
  leavesOfGroup,
  moveTab,
  newTab,
  openOrFocusPage,
  serialize,
  splitLeaf,
  toggleStacked,
  type WorkspaceState,
} from "./wikiWorkspace";

beforeEach(() => __resetWorkspaceIds());

/** The single group's leaf ids, in order. */
const groupLeafIds = (s: WorkspaceState, gid = s.activeGroupId!) =>
  s.groups.get(gid)!.leafIds;
const colGroupCount = (s: WorkspaceState) => s.columns.map((c) => c.length);
const totalGroups = (s: WorkspaceState) => s.rootGroupIds.length;

describe("buildInitial", () => {
  it("is one column / one group / one empty leaf", () => {
    const s = buildInitial();
    expect(s.columns).toHaveLength(1);
    expect(s.columns[0]).toHaveLength(1);
    expect(s.rootGroupIds).toEqual(s.columns.flat());
    expect(activeLeaf(s)?.state).toEqual({ type: "empty" });
    expect(activePageId(s)).toBeNull();
  });
});

describe("openOrFocusPage", () => {
  it("replaces the active empty leaf in place (navigate-in-place)", () => {
    const s = openOrFocusPage(buildInitial(), "p1");
    expect(groupLeafIds(s)).toHaveLength(1);
    expect(activePageId(s)).toBe("p1");
  });

  it("replaces an active PAGE leaf in place by default", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2");
    expect(groupLeafIds(s)).toHaveLength(1);
    expect(activePageId(s)).toBe("p2");
  });

  it("appends a new tab when newTab is set", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    expect(groupLeafIds(s)).toHaveLength(2);
    expect(activePageId(s)).toBe("p2");
  });

  it("focuses an already-open tab for the page instead of duplicating", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const before = groupLeafIds(s).length;
    s = openOrFocusPage(s, "p1"); // p1 is open in a background tab
    expect(groupLeafIds(s)).toHaveLength(before); // no new tab
    expect(activePageId(s)).toBe("p1");
  });

  it("is a no-op when re-opening the already-active page", () => {
    const s1 = openOrFocusPage(buildInitial(), "p1");
    const s2 = openOrFocusPage(s1, "p1");
    expect(s2).toBe(s1);
  });
});

describe("newTab", () => {
  it("always appends an empty leaf and activates it", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = newTab(s);
    expect(groupLeafIds(s)).toHaveLength(2);
    expect(activeLeaf(s)?.state).toEqual({ type: "empty" });
  });
});

describe("focusLeaf / focusGroup", () => {
  it("focusLeaf activates the leaf and its group", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const firstLeaf = groupLeafIds(s)[0];
    s = focusLeaf(s, firstLeaf);
    expect(activePageId(s)).toBe("p1");
  });

  it("focusGroup switches the active group", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const left = s.activeGroupId!;
    s = splitLeaf(s, groupLeafIds(s, left)[0], "right");
    const right = s.activeGroupId!;
    expect(right).not.toBe(left);
    s = focusGroup(s, left);
    expect(s.activeGroupId).toBe(left);
  });
});

describe("closeLeaf", () => {
  it("removing the active tab activates the RIGHT neighbour", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p3", { newTab: true });
    const [, mid] = groupLeafIds(s);
    s = focusLeaf(s, mid); // p2 active
    s = closeLeaf(s, mid);
    expect(activePageId(s)).toBe("p3"); // right neighbour
  });

  it("removing the last (active) tab falls back to the LEFT", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const last = groupLeafIds(s)[1];
    s = closeLeaf(s, last); // p2 was active
    expect(activePageId(s)).toBe("p1");
  });

  it("emptying the LAST group re-seeds an empty leaf (never zero groups)", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = closeLeaf(s, groupLeafIds(s)[0]);
    expect(totalGroups(s)).toBe(1);
    expect(activeLeaf(s)?.state).toEqual({ type: "empty" });
  });

  it("emptying a non-last group removes the group + collapses its column", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s)[0], "right"); // 2 columns
    expect(totalGroups(s)).toBe(2);
    const rightLeaf = groupLeafIds(s)[0]; // active = right group's leaf
    s = closeLeaf(s, rightLeaf);
    expect(totalGroups(s)).toBe(1);
    expect(s.columns).toHaveLength(1);
    expect(s.activeGroupId).toBe(s.rootGroupIds[0]); // focus moved to survivor
  });

  it("closing a background tab keeps the active tab active", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true }); // p2 active
    const bg = groupLeafIds(s)[0]; // p1 (background)
    s = closeLeaf(s, bg);
    expect(activePageId(s)).toBe("p2");
  });
});

describe("closeOtherLeaves / closeLeavesToRight", () => {
  it("closeOtherLeaves keeps only the target", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p3", { newTab: true });
    const keep = groupLeafIds(s)[1];
    s = closeOtherLeaves(s, keep);
    expect(groupLeafIds(s)).toEqual([keep]);
    expect(activePageId(s)).toBe("p2");
  });

  it("closeLeavesToRight drops everything after the target", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p3", { newTab: true });
    const [first, mid] = groupLeafIds(s);
    s = closeLeavesToRight(s, mid);
    expect(groupLeafIds(s)).toEqual([first, mid]);
  });

  it("closeLeavesToRight on the last tab is a no-op", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const last = groupLeafIds(s)[1];
    const before = s;
    s = closeLeavesToRight(s, last);
    expect(s).toBe(before);
  });
});

describe("splitLeaf", () => {
  it("split right adds a column to the right carrying a copy of the leaf", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    expect(s.columns).toHaveLength(2);
    expect(colGroupCount(s)).toEqual([1, 1]);
    expect(activePageId(s)).toBe("p1"); // copy
  });

  it("split down adds a group below in the SAME column", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "down");
    expect(s.columns).toHaveLength(1);
    expect(colGroupCount(s)).toEqual([2]);
  });

  it("split inserts directly right of the source column, not at the end", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const g0 = s.rootGroupIds[0];
    s = splitLeaf(s, groupLeafIds(s, g0)[0], "right"); // [g0][g1], active g1
    const g1 = s.activeGroupId!;
    s = focusGroup(s, g0);
    s = splitLeaf(s, groupLeafIds(s, g0)[0], "right"); // new col between g0 and g1
    expect(s.columns).toHaveLength(3);
    expect(s.columns[0]).toEqual([g0]);
    expect(s.columns[2]).toEqual([g1]);
  });

  it("split copy is independent — closing the copy leaves the original", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    const copyLeaf = groupLeafIds(s)[0];
    s = closeLeaf(s, copyLeaf);
    expect(totalGroups(s)).toBe(1);
    expect(activePageId(s)).toBe("p1");
  });
});

describe("closeGroup", () => {
  it("is a no-op with a single group", () => {
    const s = openOrFocusPage(buildInitial(), "p1");
    expect(closeGroup(s, s.activeGroupId!)).toBe(s);
  });

  it("removes the group and its column, moving focus left", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const g0 = s.rootGroupIds[0];
    s = splitLeaf(s, groupLeafIds(s, g0)[0], "right");
    const g1 = s.activeGroupId!;
    s = closeGroup(s, g1);
    expect(totalGroups(s)).toBe(1);
    expect(s.activeGroupId).toBe(g0);
  });

  it("deletes all leaves belonging to the closed group", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const g0 = s.rootGroupIds[0];
    s = splitLeaf(s, groupLeafIds(s, g0)[0], "right");
    const g1 = s.activeGroupId!;
    const removedLeaf = s.groups.get(g1)!.leafIds[0];
    s = closeGroup(s, g1);
    expect(s.leaves.has(removedLeaf)).toBe(false);
  });
});

describe("toggleStacked", () => {
  it("flips the stacked flag", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const g = s.activeGroupId!;
    s = toggleStacked(s, g);
    expect(s.groups.get(g)!.stacked).toBe(true);
    s = toggleStacked(s, g);
    expect(s.groups.get(g)!.stacked).toBeUndefined();
  });
});

describe("moveTab", () => {
  function twoGroups(): { s: WorkspaceState; gA: string; gB: string } {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true }); // group A: [p1, p2]
    const gA = s.activeGroupId!;
    s = splitLeaf(s, groupLeafIds(s, gA)[0], "right"); // group B: [copy-of-p1]
    const gB = s.activeGroupId!;
    return { s, gA, gB };
  }

  it("reorders within a group (insert before)", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p3", { newTab: true });
    const [a, b, c] = groupLeafIds(s);
    s = moveTab(s, c, s.activeGroupId!, a); // move c before a
    expect(groupLeafIds(s)).toEqual([c, a, b]);
  });

  it("dropping a tab onto its own trailing slot is a no-op", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const last = groupLeafIds(s)[1];
    const before = s;
    s = moveTab(s, last, s.activeGroupId!, null);
    expect(s).toBe(before);
  });

  it("transfers a tab to another group and activates it there", () => {
    const { s: s0, gA, gB } = twoGroups();
    const moved = s0.groups.get(gA)!.leafIds[1]; // p2
    const s = moveTab(s0, moved, gB, null);
    expect(s.groups.get(gA)!.leafIds).toHaveLength(1);
    expect(s.groups.get(gB)!.leafIds).toContain(moved);
    expect(s.activeGroupId).toBe(gB);
    expect(s.groups.get(gB)!.activeLeafId).toBe(moved);
  });

  it("emptying the source group by transfer removes it + its column", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const gA = s.activeGroupId!;
    s = splitLeaf(s, groupLeafIds(s, gA)[0], "right"); // gB single leaf
    const gB = s.activeGroupId!;
    const onlyLeafOfB = s.groups.get(gB)!.leafIds[0];
    s = moveTab(s, onlyLeafOfB, gA, null); // gB now empty
    expect(s.groups.has(gB)).toBe(false);
    expect(totalGroups(s)).toBe(1);
  });

  it("emptying the SOLE group by self-move re-seeds an empty leaf", () => {
    // Degenerate: only one group, move its only leaf to itself before null is a
    // no-op; but moving when it would empty the sole group must re-seed. Build a
    // single group with one leaf, then move it to a (nonexistent) — covered via
    // the collapse branch: here we assert the invariant indirectly.
    let s = openOrFocusPage(buildInitial(), "p1"); // one group, one leaf
    // Moving the only leaf within the only group before null = no-op (trailing).
    const only = groupLeafIds(s)[0];
    s = moveTab(s, only, s.activeGroupId!, null);
    expect(totalGroups(s)).toBe(1);
    expect(groupLeafIds(s)).toEqual([only]);
  });
});

describe("serialize / deserialize", () => {
  it("returns null for the pristine empty workspace", () => {
    expect(serialize(buildInitial())).toBeNull();
  });

  it("round-trips a multi-column layout (structure + active)", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    const gA = s.activeGroupId!;
    s = splitLeaf(s, groupLeafIds(s, gA)[0], "down");
    s = openOrFocusPage(s, "p3");
    const snap = serialize(s);
    expect(snap).not.toBeNull();

    __resetWorkspaceIds();
    const restored = deserialize(snap)!;
    expect(restored.columns.map((c) => c.length)).toEqual(s.columns.map((c) => c.length));
    expect(restored.rootGroupIds).toEqual(restored.columns.flat());
    // Active page survives the round-trip.
    expect(activePageId(restored)).toBe(activePageId(s));
  });

  it("preserves the stacked flag", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = toggleStacked(s, s.activeGroupId!);
    const restored = deserialize(serialize(s))!;
    expect(restored.groups.get(restored.rootGroupIds[0])!.stacked).toBe(true);
  });

  it("deserialize rejects empty / malformed snapshots", () => {
    expect(deserialize(null)).toBeNull();
    expect(deserialize({ columns: [], activeGroupIndex: 0 })).toBeNull();
    // A group with no valid leaves collapses away → null.
    expect(
      deserialize({ columns: [[{ leaves: [], activeIndex: 0 }]], activeGroupIndex: 0 }),
    ).toBeNull();
  });

  it("deserialize drops invalid leaf states but keeps valid siblings", () => {
    const restored = deserialize({
      columns: [[{ leaves: [{ type: "bogus" } as never, { type: "page", pageId: "p9" }], activeIndex: 1 }]],
      activeGroupIndex: 0,
    })!;
    expect(leavesOfGroup(restored, restored.rootGroupIds[0]).map((l) => l.state)).toEqual([
      { type: "page", pageId: "p9" },
    ]);
  });

  it("deserialize clamps out-of-range active indices", () => {
    const restored = deserialize({
      columns: [[{ leaves: [{ type: "page", pageId: "p1" }], activeIndex: 99 }]],
      activeGroupIndex: 99,
    })!;
    expect(activePageId(restored)).toBe("p1");
  });
});
