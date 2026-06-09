// Pure workspace-tree model for the multi-pane wiki (granite parity: M22).
//
// Shape: leaves → groups → columns.
//   - A *leaf* is one open view (an "empty"/index surface, or a wiki page).
//   - A *group* is a tab strip: an ordered set of leaf ids + the active one.
//   - A *column* is a vertical stack of one or more groups; columns sit
//     left-to-right. `columns` is the canonical layout; `rootGroupIds` is the
//     flattened reading order, kept derived so callers never desync the two.
//
// Everything here is a PURE reducer (state in → new state out) so the open /
// close / split / move / focus logic is unit-tested without React or storage.
// The only side effect is `newId`'s monotonic counter (ids just need to be
// unique); call `__resetWorkspaceIds` between tests for stable assertions.

export type LeafId = string;
export type TabGroupId = string;

/**
 * Per-leaf state. Deliberately minimal vs granite's leaf zoo: a wiki view is
 * either the index/"empty" surface or a single page id. Whether that page is a
 * canvas / base / markdown note is derived from the fetched body at render
 * time (unchanged from the single-pane code) — it is NOT encoded here.
 */
export type WikiLeafState =
  | { readonly type: "empty" }
  | {
      readonly type: "page";
      readonly pageId: string;
      /** Pinned tabs are never replaced by navigate-in-place (a new tab opens
       *  instead) and resist close-others; toggled from the tab UI. */
      readonly pinned?: boolean;
    };

export interface Leaf {
  readonly id: LeafId;
  readonly state: WikiLeafState;
}

export interface TabGroup {
  readonly id: TabGroupId;
  readonly leafIds: ReadonlyArray<LeafId>;
  readonly activeLeafId: LeafId | null;
  /** Render tabs as a vertical stacked column instead of a row strip. */
  readonly stacked?: boolean;
}

/** Per-leaf back/forward stack of pageIds (cursor = current position). */
export interface NavHistory {
  readonly entries: ReadonlyArray<string>;
  readonly cursor: number;
}

export interface WorkspaceState {
  readonly leaves: ReadonlyMap<LeafId, Leaf>;
  readonly groups: ReadonlyMap<TabGroupId, TabGroup>;
  /** Columns of groups (each column = vertical stack; columns go left→right). */
  readonly columns: ReadonlyArray<ReadonlyArray<TabGroupId>>;
  /** Derived: `columns.flat()` in reading order. Never set directly. */
  readonly rootGroupIds: ReadonlyArray<TabGroupId>;
  readonly activeGroupId: TabGroupId | null;
  /**
   * Per-leaf navigation history, keyed by leaf id. TRANSIENT — never
   * serialized (granite parity: history clears on reload). A moved tab keeps
   * its history (same leaf id); a split copy starts fresh (new leaf id).
   */
  readonly histories: ReadonlyMap<LeafId, NavHistory>;
  /**
   * Resize weights, keyed by GROUP id (stable). `w` = the width weight of the
   * COLUMN this group leads (a column's width = its first group's `w`); `h` =
   * the height weight of this group within its column. Both default to 1 when
   * absent. Keyed by group id (not column index) to dodge index-aliasing when
   * columns are added/removed; stale entries for deleted groups are harmless.
   * Persisted positionally (re-keyed to fresh ids on deserialize).
   */
  readonly groupSizes: ReadonlyMap<TabGroupId, GroupSize>;
}

export interface GroupSize {
  readonly w: number;
  readonly h: number;
}

const DEFAULT_SIZE: GroupSize = { w: 1, h: 1 };

// ── id generation ───────────────────────────────────────────────────────────

let counter = 0;
const newId = (prefix: string): string => `${prefix}-${(++counter).toString(36)}`;

/** Test-only: reset the id counter so ids are deterministic across cases. */
export function __resetWorkspaceIds(): void {
  counter = 0;
}

// ── derivation helpers ──────────────────────────────────────────────────────

function flatten(columns: ReadonlyArray<ReadonlyArray<TabGroupId>>): TabGroupId[] {
  const out: TabGroupId[] = [];
  for (const col of columns) for (const g of col) out.push(g);
  return out;
}

/** Re-derive `rootGroupIds` from `columns`; the single place that sets it.
 *  `histories` defaults to empty when a caller builds state from scratch
 *  (buildInitial / deserialize); ops that spread `...state` carry it through. */
function withDerived(
  next: Omit<WorkspaceState, "rootGroupIds" | "histories" | "groupSizes"> & {
    histories?: ReadonlyMap<LeafId, NavHistory>;
    groupSizes?: ReadonlyMap<TabGroupId, GroupSize>;
  },
): WorkspaceState {
  return {
    ...next,
    histories: next.histories ?? new Map(),
    groupSizes: next.groupSizes ?? new Map(),
    rootGroupIds: flatten(next.columns),
  };
}

/** Append `pageId` to a leaf's history, truncating any forward entries and
 *  deduping a repeat of the current page. Returns a new histories map. */
function pushNav(
  histories: ReadonlyMap<LeafId, NavHistory>,
  leafId: LeafId,
  pageId: string,
): ReadonlyMap<LeafId, NavHistory> {
  const slot = histories.get(leafId) ?? { entries: [], cursor: -1 };
  if (slot.entries[slot.cursor] === pageId) return histories; // already current
  const trimmed = slot.cursor < slot.entries.length - 1
    ? slot.entries.slice(0, slot.cursor + 1)
    : slot.entries.slice();
  trimmed.push(pageId);
  return new Map(histories).set(leafId, { entries: trimmed, cursor: trimmed.length - 1 });
}

function findColumnIndex(
  columns: ReadonlyArray<ReadonlyArray<TabGroupId>>,
  groupId: TabGroupId,
): number {
  for (let i = 0; i < columns.length; i++) {
    if (columns[i]?.includes(groupId)) return i;
  }
  return -1;
}

function groupOfLeaf(state: WorkspaceState, leafId: LeafId): TabGroupId | null {
  for (const [gid, g] of state.groups) {
    if (g.leafIds.includes(leafId)) return gid;
  }
  return null;
}

// ── public derived accessors ────────────────────────────────────────────────

/** The active group's active leaf, or null. */
export function activeLeaf(state: WorkspaceState): Leaf | null {
  const gid = state.activeGroupId;
  if (!gid) return null;
  const group = state.groups.get(gid);
  if (!group?.activeLeafId) return null;
  return state.leaves.get(group.activeLeafId) ?? null;
}

/** The page id of the active leaf (null when the active leaf is the index). */
export function activePageId(state: WorkspaceState): string | null {
  const leaf = activeLeaf(state);
  return leaf && leaf.state.type === "page" ? leaf.state.pageId : null;
}

/** True for the untouched workspace (one group, one empty leaf) — the signal
 *  to render the route-level index/search surfaces instead of the multi-pane
 *  workspace. Equivalent to `serialize(state) === null`. */
export function isPristine(state: WorkspaceState): boolean {
  if (state.rootGroupIds.length !== 1) return false;
  const group = state.groups.get(state.rootGroupIds[0]);
  if (!group || group.leafIds.length !== 1) return false;
  const leaf = group.activeLeafId ? state.leaves.get(group.activeLeafId) : null;
  return leaf?.state.type === "empty";
}

/** Ordered list of every leaf in a group (skipping any dangling ids). */
export function leavesOfGroup(state: WorkspaceState, groupId: TabGroupId): Leaf[] {
  const group = state.groups.get(groupId);
  if (!group) return [];
  return group.leafIds
    .map((id) => state.leaves.get(id))
    .filter((l): l is Leaf => !!l);
}

// ── construction ────────────────────────────────────────────────────────────

/** A fresh workspace: one column, one group, one empty (index) leaf. */
export function buildInitial(): WorkspaceState {
  const groupId = newId("g");
  const leafId = newId("l");
  const leaf: Leaf = { id: leafId, state: { type: "empty" } };
  const group: TabGroup = { id: groupId, leafIds: [leafId], activeLeafId: leafId };
  return withDerived({
    leaves: new Map([[leafId, leaf]]),
    groups: new Map([[groupId, group]]),
    columns: [[groupId]],
    activeGroupId: groupId,
  });
}

// ── open / focus ────────────────────────────────────────────────────────────

/** Leaf types whose active tab is REPLACED (not appended) on a plain open. */
const REPLACEABLE: ReadonlyArray<WikiLeafState["type"]> = ["empty", "page"];

/**
 * Open a page in the active group: focus an already-open tab for that page if
 * present; else replace the active leaf when it's a replaceable type (the
 * Obsidian "navigate in place" default); else append a new tab. `newTab: true`
 * forces an append. Returns the unchanged state if there is no active group.
 */
export function openOrFocusPage(
  state: WorkspaceState,
  pageId: string,
  opts: { newTab?: boolean } = {},
): WorkspaceState {
  const groupId = state.activeGroupId;
  if (!groupId) return state;
  const group = state.groups.get(groupId);
  if (!group) return state;

  // Focus an existing tab for this page within the active group.
  for (const id of group.leafIds) {
    const leaf = state.leaves.get(id);
    if (leaf && leaf.state.type === "page" && leaf.state.pageId === pageId) {
      if (group.activeLeafId === id) return state; // already active — no-op
      const groups = new Map(state.groups);
      groups.set(groupId, { ...group, activeLeafId: id });
      return withDerived({ ...state, groups });
    }
  }

  const activeLeafObj = group.activeLeafId ? state.leaves.get(group.activeLeafId) : null;
  const canReplace =
    !opts.newTab &&
    activeLeafObj &&
    REPLACEABLE.includes(activeLeafObj.state.type) &&
    // A pinned page tab is never replaced in place — open a new tab instead.
    !(activeLeafObj.state.type === "page" && activeLeafObj.state.pinned);

  if (canReplace && activeLeafObj) {
    // Navigate-in-place: same leaf, new page → push onto its history.
    const updated: Leaf = { id: activeLeafObj.id, state: { type: "page", pageId } };
    return withDerived({
      ...state,
      leaves: new Map(state.leaves).set(updated.id, updated),
      histories: pushNav(state.histories, updated.id, pageId),
    });
  }

  const id = newId("l");
  const leaves = new Map(state.leaves);
  leaves.set(id, { id, state: { type: "page", pageId } });
  const groups = new Map(state.groups);
  groups.set(groupId, { ...group, leafIds: [...group.leafIds, id], activeLeafId: id });
  return withDerived({ ...state, leaves, groups, histories: pushNav(state.histories, id, pageId) });
}

/** Open a fresh empty (index) tab in the active group, always appending. */
export function newTab(state: WorkspaceState): WorkspaceState {
  const groupId = state.activeGroupId;
  if (!groupId) return state;
  const group = state.groups.get(groupId);
  if (!group) return state;
  const id = newId("l");
  const leaves = new Map(state.leaves);
  leaves.set(id, { id, state: { type: "empty" } });
  const groups = new Map(state.groups);
  groups.set(groupId, { ...group, leafIds: [...group.leafIds, id], activeLeafId: id });
  return withDerived({ ...state, leaves, groups });
}

/** Focus a leaf (and its group becomes the active group). */
export function focusLeaf(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  const gid = groupOfLeaf(state, leafId);
  if (!gid) return state;
  const group = state.groups.get(gid);
  if (!group) return state;
  if (state.activeGroupId === gid && group.activeLeafId === leafId) return state;
  const groups = new Map(state.groups);
  groups.set(gid, { ...group, activeLeafId: leafId });
  return withDerived({ ...state, groups, activeGroupId: gid });
}

/** Make a group active (focusing its current active leaf). */
export function focusGroup(state: WorkspaceState, groupId: TabGroupId): WorkspaceState {
  if (!state.groups.has(groupId)) return state;
  if (state.activeGroupId === groupId) return state;
  return withDerived({ ...state, activeGroupId: groupId });
}

// ── close ───────────────────────────────────────────────────────────────────

/**
 * Close a tab. The group keeps the invariant of ≥1 leaf: emptying the LAST
 * remaining group re-seeds it with a fresh empty leaf; emptying any other
 * group removes that group (and its column if it becomes empty). When the
 * closed leaf was active, focus moves to its right neighbour, else its left.
 */
export function closeLeaf(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  const gid = groupOfLeaf(state, leafId);
  if (!gid) return state;
  const group = state.groups.get(gid);
  if (!group) return state;

  const leaves = new Map(state.leaves);
  leaves.delete(leafId);
  const groups = new Map(state.groups);
  let columns = state.columns.map((c) => [...c]);
  let activeGroupId = state.activeGroupId;

  const nextIds = group.leafIds.filter((id) => id !== leafId);
  if (nextIds.length === 0) {
    if (state.rootGroupIds.length <= 1) {
      // Last group standing — re-seed with an empty leaf (never zero groups).
      const emptyId = newId("l");
      leaves.set(emptyId, { id: emptyId, state: { type: "empty" } });
      groups.set(gid, { ...group, leafIds: [emptyId], activeLeafId: emptyId });
    } else {
      // Remove the now-empty group; drop its column if that empties it; move
      // focus to a surviving group if this one was active.
      groups.delete(gid);
      const colIdx = findColumnIndex(state.columns, gid);
      columns = columns.map((c) => c.filter((g) => g !== gid)).filter((c) => c.length > 0);
      if (activeGroupId === gid) {
        // Prefer the previous group in the same column, then the column to the
        // left, then the first survivor — identical fallback to closeGroup.
        const flat = flatten(columns);
        const sourceCol = state.columns[colIdx];
        const sourceIdxInCol = sourceCol ? sourceCol.indexOf(gid) : -1;
        activeGroupId =
          sourceCol?.[sourceIdxInCol - 1] ??
          columns[Math.max(0, colIdx - 1)]?.[0] ??
          flat[0] ??
          null;
      }
    }
  } else {
    let nextActive: LeafId | null = group.activeLeafId;
    if (nextActive === leafId) {
      const wasIndex = group.leafIds.indexOf(leafId);
      nextActive = nextIds[wasIndex] ?? nextIds[wasIndex - 1] ?? null;
    }
    groups.set(gid, { ...group, leafIds: nextIds, activeLeafId: nextActive });
  }

  return withDerived({ ...state, leaves, groups, columns, activeGroupId });
}

/** Close every tab in `leafId`'s group except `leafId` itself and any PINNED
 *  tabs (pinned tabs survive close-others, matching Obsidian). */
export function closeOtherLeaves(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  const gid = groupOfLeaf(state, leafId);
  if (!gid) return state;
  const group = state.groups.get(gid);
  if (!group) return state;
  const isPinned = (id: LeafId) => {
    const l = state.leaves.get(id);
    return l?.state.type === "page" && !!l.state.pinned;
  };
  const kept = group.leafIds.filter((id) => id === leafId || isPinned(id));
  const leaves = new Map(state.leaves);
  for (const id of group.leafIds) if (!kept.includes(id)) leaves.delete(id);
  const groups = new Map(state.groups);
  groups.set(gid, { ...group, leafIds: kept, activeLeafId: leafId });
  return withDerived({ ...state, leaves, groups });
}

/** Close every tab to the RIGHT of `leafId` within its group. */
export function closeLeavesToRight(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  const gid = groupOfLeaf(state, leafId);
  if (!gid) return state;
  const group = state.groups.get(gid);
  if (!group) return state;
  const idx = group.leafIds.indexOf(leafId);
  if (idx === -1 || idx === group.leafIds.length - 1) return state;
  const leaves = new Map(state.leaves);
  for (const id of group.leafIds.slice(idx + 1)) leaves.delete(id);
  const groups = new Map(state.groups);
  const kept = group.leafIds.slice(0, idx + 1);
  const active = group.activeLeafId && kept.includes(group.activeLeafId)
    ? group.activeLeafId
    : leafId;
  groups.set(gid, { ...group, leafIds: kept, activeLeafId: active });
  return withDerived({ ...state, leaves, groups });
}

// ── split / group ops ───────────────────────────────────────────────────────

/**
 * Split a leaf into a new sibling group carrying a COPY of its state.
 *   - "right": a new column immediately right of the leaf's column.
 *   - "down":  a new group below the leaf's group, in the same column.
 * The new group becomes active.
 */
export function splitLeaf(
  state: WorkspaceState,
  leafId: LeafId,
  direction: "right" | "down" = "right",
): WorkspaceState {
  const sourceLeaf = state.leaves.get(leafId);
  if (!sourceLeaf) return state;
  const sourceGroupId = groupOfLeaf(state, leafId);
  if (!sourceGroupId) return state;
  const sourceColIdx = findColumnIndex(state.columns, sourceGroupId);
  if (sourceColIdx === -1) return state;

  const newGroupId = newId("g");
  const newLeafId = newId("l");
  const newLeaf: Leaf = { id: newLeafId, state: sourceLeaf.state };
  const newGroup: TabGroup = { id: newGroupId, leafIds: [newLeafId], activeLeafId: newLeafId };

  const leaves = new Map(state.leaves).set(newLeafId, newLeaf);
  const groups = new Map(state.groups).set(newGroupId, newGroup);
  const columns = state.columns.map((c) => [...c]);
  if (direction === "right") {
    columns.splice(sourceColIdx + 1, 0, [newGroupId]);
  } else {
    const col = columns[sourceColIdx];
    if (!col) return state;
    col.splice(col.indexOf(sourceGroupId) + 1, 0, newGroupId);
  }
  return withDerived({ ...state, leaves, groups, columns, activeGroupId: newGroupId });
}

/**
 * Close an entire group (all its tabs). No-op when only one group remains.
 * Focus, if it was here, moves to the previous group in the same column, then
 * the column to the left, then the first surviving group.
 */
export function closeGroup(state: WorkspaceState, groupId: TabGroupId): WorkspaceState {
  if (state.rootGroupIds.length <= 1) return state;
  const group = state.groups.get(groupId);
  if (!group) return state;
  const colIdx = findColumnIndex(state.columns, groupId);
  if (colIdx === -1) return state;

  const leaves = new Map(state.leaves);
  for (const id of group.leafIds) leaves.delete(id);
  const groups = new Map(state.groups);
  groups.delete(groupId);
  const columns = state.columns
    .map((c) => c.filter((g) => g !== groupId))
    .filter((c) => c.length > 0);

  let activeGroupId = state.activeGroupId;
  if (activeGroupId === groupId) {
    const sourceCol = state.columns[colIdx];
    const sourceIdxInCol = sourceCol ? sourceCol.indexOf(groupId) : -1;
    const flat = flatten(columns);
    activeGroupId =
      sourceCol?.[sourceIdxInCol - 1] ??
      columns[Math.max(0, colIdx - 1)]?.[0] ??
      flat[0] ??
      null;
  }
  return withDerived({ ...state, leaves, groups, columns, activeGroupId });
}

/** Toggle a page leaf's pinned flag (no-op for empty leaves). Canonical: the
 *  key is dropped when turning off (truthy-only, matching serialize). */
export function togglePinned(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  const leaf = state.leaves.get(leafId);
  if (!leaf || leaf.state.type !== "page") return state;
  const { pinned: _was, ...rest } = leaf.state;
  const nextState: WikiLeafState = leaf.state.pinned ? rest : { ...rest, pinned: true };
  return withDerived({
    ...state,
    leaves: new Map(state.leaves).set(leafId, { ...leaf, state: nextState }),
  });
}

// ── per-leaf nav history ────────────────────────────────────────────────────

/** Move a leaf's history cursor by `delta` (±1) and point the leaf at the
 *  pageId there. No-op when out of range or the leaf isn't a page. Crucially
 *  does NOT push history (it moves the cursor), and because the leaf then shows
 *  that page, the route reconciler's openOrFocusPage is a no-op → no loop. */
function stepHistory(state: WorkspaceState, leafId: LeafId, delta: 1 | -1): WorkspaceState {
  const leaf = state.leaves.get(leafId);
  if (!leaf || leaf.state.type !== "page") return state;
  const slot = state.histories.get(leafId);
  if (!slot) return state;
  const nextCursor = slot.cursor + delta;
  if (nextCursor < 0 || nextCursor >= slot.entries.length) return state;
  const pageId = slot.entries[nextCursor];
  const histories = new Map(state.histories).set(leafId, { ...slot, cursor: nextCursor });
  // Preserve the pinned flag across a back/forward move.
  const pinned = leaf.state.pinned;
  const nextLeafState: WikiLeafState = pinned
    ? { type: "page", pageId, pinned }
    : { type: "page", pageId };
  return withDerived({
    ...state,
    leaves: new Map(state.leaves).set(leafId, { ...leaf, state: nextLeafState }),
    histories,
  });
}

/** Navigate a leaf back one entry in its history. */
export function goBack(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  return stepHistory(state, leafId, -1);
}

/** Navigate a leaf forward one entry in its history. */
export function goForward(state: WorkspaceState, leafId: LeafId): WorkspaceState {
  return stepHistory(state, leafId, 1);
}

export function canGoBack(state: WorkspaceState, leafId: LeafId): boolean {
  const slot = state.histories.get(leafId);
  return !!slot && slot.cursor > 0;
}

export function canGoForward(state: WorkspaceState, leafId: LeafId): boolean {
  const slot = state.histories.get(leafId);
  return !!slot && slot.cursor < slot.entries.length - 1;
}

// ── resize weights ──────────────────────────────────────────────────────────

/** Flex-grow weight for the column at `colIdx` (its first group's `w`). */
export function columnWidthWeight(state: WorkspaceState, colIdx: number): number {
  const first = state.columns[colIdx]?.[0];
  if (!first) return DEFAULT_SIZE.w;
  return state.groupSizes.get(first)?.w ?? DEFAULT_SIZE.w;
}

/** Flex-grow weight for a group within its column (its `h`). */
export function groupHeightWeight(state: WorkspaceState, groupId: TabGroupId): number {
  return state.groupSizes.get(groupId)?.h ?? DEFAULT_SIZE.h;
}

function setSize(
  sizes: ReadonlyMap<TabGroupId, GroupSize>,
  groupId: TabGroupId,
  patch: Partial<GroupSize>,
): Map<TabGroupId, GroupSize> {
  const cur = sizes.get(groupId) ?? DEFAULT_SIZE;
  return new Map(sizes).set(groupId, { ...cur, ...patch });
}

const MIN_WEIGHT = 0.15; // keep a pane from collapsing to nothing

/**
 * Set the width weights of two ADJACENT columns (the boundary the user is
 * dragging). Weights are clamped so neither pane vanishes; only these two
 * columns change so the rest of the layout stays put.
 */
export function resizeColumns(
  state: WorkspaceState,
  leftColIdx: number,
  leftW: number,
  rightW: number,
): WorkspaceState {
  const left = state.columns[leftColIdx]?.[0];
  const right = state.columns[leftColIdx + 1]?.[0];
  if (!left || !right) return state;
  const lw = Math.max(MIN_WEIGHT, leftW);
  const rw = Math.max(MIN_WEIGHT, rightW);
  let sizes = setSize(state.groupSizes, left, { w: lw });
  sizes = setSize(sizes, right, { w: rw });
  return withDerived({ ...state, groupSizes: sizes });
}

/**
 * Set the height weights of two ADJACENT groups stacked in the same column
 * (the horizontal boundary being dragged).
 */
export function resizeGroups(
  state: WorkspaceState,
  aboveGroupId: TabGroupId,
  belowGroupId: TabGroupId,
  aboveH: number,
  belowH: number,
): WorkspaceState {
  if (!state.groups.has(aboveGroupId) || !state.groups.has(belowGroupId)) return state;
  let sizes = setSize(state.groupSizes, aboveGroupId, { h: Math.max(MIN_WEIGHT, aboveH) });
  sizes = setSize(sizes, belowGroupId, { h: Math.max(MIN_WEIGHT, belowH) });
  return withDerived({ ...state, groupSizes: sizes });
}

/** Toggle a group's stacked (vertical tab column) rendering. */
export function toggleStacked(state: WorkspaceState, groupId: TabGroupId): WorkspaceState {
  const group = state.groups.get(groupId);
  if (!group) return state;
  const groups = new Map(state.groups);
  // Keep state canonical: drop the key when turning off (truthy-only, matching
  // serialize) so equality checks and round-trips stay stable.
  const { stacked: _was, ...rest } = group;
  groups.set(groupId, group.stacked ? rest : { ...rest, stacked: true });
  return withDerived({ ...state, groups });
}

// ── drag-and-drop move ──────────────────────────────────────────────────────

/**
 * Move `leafId` into `targetGroupId`, inserting before `beforeLeafId` (or at
 * the end when null). Reorders within a group, or transfers between groups;
 * the moved leaf becomes active in the target. If the source group empties:
 * it's removed (with its column) when other groups remain, else re-seeded with
 * an empty leaf so the workspace never has zero groups.
 */
export function moveTab(
  state: WorkspaceState,
  leafId: LeafId,
  targetGroupId: TabGroupId,
  beforeLeafId: LeafId | null,
): WorkspaceState {
  const sourceGroupId = groupOfLeaf(state, leafId);
  if (!sourceGroupId) return state;
  const targetGroup = state.groups.get(targetGroupId);
  if (!targetGroup) return state;

  // No-op guards: dropping a tab onto itself or to its current trailing slot.
  if (sourceGroupId === targetGroupId && beforeLeafId === leafId) return state;
  if (
    sourceGroupId === targetGroupId &&
    beforeLeafId === null &&
    targetGroup.leafIds[targetGroup.leafIds.length - 1] === leafId
  ) {
    return state;
  }

  const leaves = new Map(state.leaves);
  const groups = new Map(state.groups);

  // Remove from source.
  const sourceGroup = groups.get(sourceGroupId);
  if (!sourceGroup) return state;
  const sourceLeafIds = sourceGroup.leafIds.filter((id) => id !== leafId);
  let sourceActive: LeafId | null = sourceGroup.activeLeafId;
  if (sourceActive === leafId) {
    const idx = sourceGroup.leafIds.indexOf(leafId);
    sourceActive = sourceLeafIds[idx] ?? sourceLeafIds[idx - 1] ?? null;
  }
  groups.set(sourceGroupId, { ...sourceGroup, leafIds: sourceLeafIds, activeLeafId: sourceActive });

  // Insert into target (re-read in case source === target).
  const refreshedTarget = sourceGroupId === targetGroupId ? groups.get(targetGroupId) : targetGroup;
  if (!refreshedTarget) return state;
  let insertIdx = refreshedTarget.leafIds.length;
  if (beforeLeafId) {
    const at = refreshedTarget.leafIds.indexOf(beforeLeafId);
    if (at !== -1) insertIdx = at;
  }
  const nextTargetIds = [
    ...refreshedTarget.leafIds.slice(0, insertIdx),
    leafId,
    ...refreshedTarget.leafIds.slice(insertIdx),
  ];
  groups.set(targetGroupId, { ...refreshedTarget, leafIds: nextTargetIds, activeLeafId: leafId });

  // Collapse / re-seed an emptied source group.
  let columns = state.columns.map((c) => [...c]);
  const sourceAfter = groups.get(sourceGroupId);
  if (sourceGroupId !== targetGroupId && sourceAfter && sourceAfter.leafIds.length === 0) {
    if (flatten(columns).length > 1) {
      groups.delete(sourceGroupId);
      columns = columns.map((c) => c.filter((g) => g !== sourceGroupId)).filter((c) => c.length > 0);
    } else {
      const emptyId = newId("l");
      leaves.set(emptyId, { id: emptyId, state: { type: "empty" } });
      groups.set(sourceGroupId, { ...sourceAfter, leafIds: [emptyId], activeLeafId: emptyId });
    }
  }

  return withDerived({ ...state, leaves, groups, columns, activeGroupId: targetGroupId });
}

// ── serialization (sessionStorage) ──────────────────────────────────────────

interface SerializedGroup {
  readonly leaves: ReadonlyArray<WikiLeafState>;
  readonly activeIndex: number;
  readonly stacked?: boolean;
  /** Column-width / group-height weights, persisted positionally and re-keyed
   *  to fresh group ids on load. Omitted when at the default (1). */
  readonly w?: number;
  readonly h?: number;
}
export interface SerializedWorkspace {
  readonly columns: ReadonlyArray<ReadonlyArray<SerializedGroup>>;
  readonly activeGroupIndex: number;
}

/** Flatten the live state into a portable snapshot (ids dropped — re-minted on
 *  load). Returns null for a workspace that's just the initial empty leaf
 *  (nothing worth persisting). */
export function serialize(state: WorkspaceState): SerializedWorkspace | null {
  const columns: SerializedGroup[][] = [];
  let activeGroupIndex = 0;
  let flatIdx = 0; // counts only KEPT groups, so it matches deserialize's reading order
  for (const col of state.columns) {
    const colGroups: SerializedGroup[] = [];
    for (const gid of col) {
      const group = state.groups.get(gid);
      if (!group) continue;
      const leafStates: WikiLeafState[] = [];
      let activeIndex = 0;
      let j = 0;
      for (const lid of group.leafIds) {
        const leaf = state.leaves.get(lid);
        if (!leaf) continue;
        leafStates.push(leaf.state);
        if (lid === group.activeLeafId) activeIndex = j;
        j += 1;
      }
      // Skip a fully-dangling group BEFORE advancing the index, else later
      // groups capture an inflated activeGroupIndex that deserialize misreads.
      if (leafStates.length === 0) continue;
      if (gid === state.activeGroupId) activeGroupIndex = flatIdx;
      flatIdx += 1;
      const size = state.groupSizes.get(gid);
      colGroups.push({
        leaves: leafStates,
        activeIndex,
        ...(group.stacked ? { stacked: true } : {}),
        ...(size && size.w !== DEFAULT_SIZE.w ? { w: size.w } : {}),
        ...(size && size.h !== DEFAULT_SIZE.h ? { h: size.h } : {}),
      });
    }
    if (colGroups.length > 0) columns.push(colGroups);
  }
  if (columns.length === 0) return null;
  const only = columns.length === 1 && columns[0]?.length === 1 ? columns[0][0] : null;
  if (only && only.leaves.length === 1 && only.leaves[0]?.type === "empty") return null;
  return { columns, activeGroupIndex };
}

/** Rebuild live state from a snapshot (minting fresh ids). Returns null when
 *  the snapshot is empty / malformed so callers fall back to buildInitial. */
export function deserialize(snap: SerializedWorkspace | null | undefined): WorkspaceState | null {
  if (!snap || !Array.isArray(snap.columns) || snap.columns.length === 0) return null;
  const leaves = new Map<LeafId, Leaf>();
  const groups = new Map<TabGroupId, TabGroup>();
  const groupSizes = new Map<TabGroupId, GroupSize>();
  const columns: TabGroupId[][] = [];
  for (const col of snap.columns) {
    if (!Array.isArray(col)) continue;
    const colGroups: TabGroupId[] = [];
    for (const g of col) {
      if (!g || !Array.isArray(g.leaves) || g.leaves.length === 0) continue;
      const groupId = newId("g");
      const leafIds: LeafId[] = [];
      for (const ls of g.leaves) {
        if (!isLeafState(ls)) continue;
        const id = newId("l");
        leafIds.push(id);
        leaves.set(id, { id, state: ls });
      }
      if (leafIds.length === 0) continue;
      const activeLeafId = leafIds[clamp(g.activeIndex, 0, leafIds.length - 1)] ?? null;
      groups.set(groupId, { id: groupId, leafIds, activeLeafId, ...(g.stacked ? { stacked: true } : {}) });
      const w = typeof g.w === "number" && Number.isFinite(g.w) ? g.w : DEFAULT_SIZE.w;
      const h = typeof g.h === "number" && Number.isFinite(g.h) ? g.h : DEFAULT_SIZE.h;
      if (w !== DEFAULT_SIZE.w || h !== DEFAULT_SIZE.h) groupSizes.set(groupId, { w, h });
      colGroups.push(groupId);
    }
    if (colGroups.length > 0) columns.push(colGroups);
  }
  if (columns.length === 0) return null;
  const flat = flatten(columns);
  const activeGroupId = flat[clamp(snap.activeGroupIndex, 0, flat.length - 1)] ?? null;
  return withDerived({ leaves, groups, columns, activeGroupId, groupSizes });
}

function clamp(n: unknown, lo: number, hi: number): number {
  const v = typeof n === "number" && Number.isFinite(n) ? Math.floor(n) : 0;
  return Math.max(lo, Math.min(hi, v));
}

function isLeafState(v: unknown): v is WikiLeafState {
  if (!v || typeof v !== "object") return false;
  const t = (v as { type?: unknown }).type;
  if (t === "empty") return true;
  if (t === "page") return typeof (v as { pageId?: unknown }).pageId === "string" && (v as { pageId: string }).pageId.length > 0;
  return false;
}
