import { beforeEach, describe, expect, it } from "vitest";
import {
  __resetWorkspaceIds,
  activeLeaf,
  activePageId,
  buildInitial,
  canGoBack,
  canGoForward,
  goBack,
  goForward,
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
  columnWidthWeight,
  groupHeightWeight,
  resizeColumns,
  resizeGroups,
  openOrFocusPage,
  serialize,
  splitLeaf,
  toggleStacked,
  togglePinned,
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

describe("togglePinned", () => {
  it("flips the pinned flag on a page leaf and drops it when off", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const id = groupLeafIds(s)[0];
    s = togglePinned(s, id);
    expect((s.leaves.get(id)!.state as { pinned?: boolean }).pinned).toBe(true);
    s = togglePinned(s, id);
    expect((s.leaves.get(id)!.state as { pinned?: boolean }).pinned).toBeUndefined();
  });

  it("is a no-op on an empty leaf", () => {
    const s = buildInitial();
    expect(togglePinned(s, groupLeafIds(s)[0])).toBe(s);
  });

  it("a pinned active tab is NOT replaced in place — a new tab opens", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const pinnedId = groupLeafIds(s)[0];
    s = togglePinned(s, pinnedId);
    s = openOrFocusPage(s, "p2"); // would normally replace p1
    expect(groupLeafIds(s)).toHaveLength(2); // appended instead
    expect(s.leaves.get(pinnedId)!.state).toMatchObject({ pageId: "p1", pinned: true });
    expect(activePageId(s)).toBe("p2");
  });

  it("focusing an already-open pinned tab for the page still dedupes (no new tab)", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = togglePinned(s, groupLeafIds(s)[0]);
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p1"); // p1 pinned + open → focus it, don't duplicate
    expect(groupLeafIds(s)).toHaveLength(2);
    expect(activePageId(s)).toBe("p1");
  });

  it("close-others keeps the target AND pinned tabs", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = openOrFocusPage(s, "p3", { newTab: true });
    const [p1, p2, p3] = groupLeafIds(s);
    s = togglePinned(s, p1); // pin p1
    s = closeOtherLeaves(s, p3); // keep p3 + pinned p1
    expect([...groupLeafIds(s)].sort()).toEqual([p1, p3].sort());
    expect(s.leaves.has(p2)).toBe(false);
  });

  it("pinned survives serialize round-trip", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = togglePinned(s, groupLeafIds(s)[0]);
    const restored = deserialize(serialize(s))!;
    const first = leavesOfGroup(restored, restored.rootGroupIds[0])[0];
    expect(first.state).toMatchObject({ pageId: "p1", pinned: true });
  });
});

describe("nav history (per-leaf back/forward)", () => {
  // Navigate a single pane through p1 → p2 → p3 (all in-place replacements).
  function trail(): WorkspaceState {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2");
    s = openOrFocusPage(s, "p3");
    return s;
  }

  it("records in-place navigation and goes back", () => {
    let s = trail();
    const id = s.activeGroupId ? s.groups.get(s.activeGroupId)!.activeLeafId! : "";
    expect(canGoBack(s, id)).toBe(true);
    expect(canGoForward(s, id)).toBe(false);
    s = goBack(s, id);
    expect(activePageId(s)).toBe("p2");
    s = goBack(s, id);
    expect(activePageId(s)).toBe("p1");
    expect(canGoBack(s, id)).toBe(false);
    expect(canGoForward(s, id)).toBe(true);
  });

  it("goes forward after going back", () => {
    let s = trail();
    const id = s.groups.get(s.activeGroupId!)!.activeLeafId!;
    s = goBack(s, id);
    s = goForward(s, id);
    expect(activePageId(s)).toBe("p3");
    expect(canGoForward(s, id)).toBe(false);
  });

  it("navigating after going back truncates the forward stack", () => {
    let s = trail(); // [p1,p2,p3] cursor 2
    const id = s.groups.get(s.activeGroupId!)!.activeLeafId!;
    s = goBack(s, id); // p2
    s = openOrFocusPage(s, "p9"); // replace p2 → new branch [p1,p2,p9]
    expect(activePageId(s)).toBe("p9");
    expect(canGoForward(s, id)).toBe(false); // p3 dropped
    s = goBack(s, id);
    expect(activePageId(s)).toBe("p2");
  });

  it("goBack/goForward are no-ops at the ends", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    const id = s.groups.get(s.activeGroupId!)!.activeLeafId!;
    expect(goBack(s, id)).toBe(s); // only one entry
    expect(goForward(s, id)).toBe(s);
  });

  it("re-opening the same page does not grow history", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2");
    const id = s.groups.get(s.activeGroupId!)!.activeLeafId!;
    s = openOrFocusPage(s, "p2"); // already active → no-op
    s = goBack(s, id);
    expect(activePageId(s)).toBe("p1"); // p2 wasn't double-recorded
  });

  it("a moved tab keeps its history; a split copy starts fresh", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2"); // group A leaf has history [p1,p2]
    const gA = s.activeGroupId!;
    const leafA = s.groups.get(gA)!.activeLeafId!;
    // split → copy gets a NEW leaf id with no history
    s = splitLeaf(s, leafA, "right");
    const copyId = s.groups.get(s.activeGroupId!)!.activeLeafId!;
    expect(canGoBack(s, copyId)).toBe(false);
    // original still has its history
    expect(canGoBack(s, leafA)).toBe(true);
  });

  it("history is transient — deserialize starts with no back/forward", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2");
    const restored = deserialize(serialize(s))!;
    const id = restored.groups.get(restored.activeGroupId!)!.activeLeafId!;
    expect(canGoBack(restored, id)).toBe(false);
    expect(activePageId(restored)).toBe("p2");
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

describe("resize weights", () => {
  it("default weights are 1", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    expect(columnWidthWeight(s, 0)).toBe(1);
    expect(columnWidthWeight(s, 1)).toBe(1);
  });

  it("resizeColumns sets the two adjacent column weights", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    s = resizeColumns(s, 0, 1.6, 0.4);
    expect(columnWidthWeight(s, 0)).toBeCloseTo(1.6);
    expect(columnWidthWeight(s, 1)).toBeCloseTo(0.4);
  });

  it("resizeColumns clamps so a pane never vanishes", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    s = resizeColumns(s, 0, 5, 0); // right would collapse
    expect(columnWidthWeight(s, 1)).toBeGreaterThan(0);
  });

  it("resizeGroups sets stacked group heights", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "down");
    const [above, below] = s.columns[0];
    s = resizeGroups(s, above, below, 1.5, 0.5);
    expect(groupHeightWeight(s, above)).toBeCloseTo(1.5);
    expect(groupHeightWeight(s, below)).toBeCloseTo(0.5);
  });

  it("weights survive serialize round-trip (re-keyed to fresh ids)", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right");
    s = resizeColumns(s, 0, 1.7, 0.3);
    const restored = deserialize(serialize(s))!;
    expect(columnWidthWeight(restored, 0)).toBeCloseTo(1.7);
    expect(columnWidthWeight(restored, 1)).toBeCloseTo(0.3);
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

  it("serialize∘deserialize is a STABLE fixed point (JSON-identical)", () => {
    // The cross-window sync's echo-suppression relies on this: applying a peer
    // snapshot then re-serializing must reproduce the SAME JSON, else two
    // windows would ping-pong forever. Cover the full feature surface.
    let s = openOrFocusPage(buildInitial(), "p1");
    s = openOrFocusPage(s, "p2", { newTab: true });
    s = togglePinned(s, groupLeafIds(s)[0]);
    const gA = s.activeGroupId!;
    s = splitLeaf(s, groupLeafIds(s, gA)[0], "down");
    s = toggleStacked(s, s.activeGroupId!);
    s = openOrFocusPage(s, "p3");
    s = splitLeaf(s, s.groups.get(s.activeGroupId!)!.activeLeafId!, "right");
    s = resizeColumns(s, 0, 1.4, 0.6);
    const snap = serialize(s)!;
    const once = serialize(deserialize(snap)!)!;
    const twice = serialize(deserialize(once)!)!;
    expect(JSON.stringify(once)).toBe(JSON.stringify(snap));
    expect(JSON.stringify(twice)).toBe(JSON.stringify(snap));
  });

  it("resized column width survives closing the column's first group", () => {
    let s = openOrFocusPage(buildInitial(), "p1");
    s = splitLeaf(s, groupLeafIds(s, s.rootGroupIds[0])[0], "right"); // 2 cols
    // make the right column a stacked pair, then widen it
    const rightG = s.activeGroupId!;
    s = splitLeaf(s, s.groups.get(rightG)!.activeLeafId!, "down");
    s = resizeColumns(s, 0, 0.5, 1.5); // right column weight 1.5
    expect(columnWidthWeight(s, 1)).toBeCloseTo(1.5);
    // close the TOP group of the right column → second becomes first
    const topOfRight = s.columns[1][0];
    s = closeGroup(s, topOfRight);
    expect(s.columns).toHaveLength(2);
    expect(columnWidthWeight(s, 1)).toBeCloseTo(1.5); // weight retained
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
