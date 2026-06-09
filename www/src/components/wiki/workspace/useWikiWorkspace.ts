import * as React from "react";
import {
  buildInitial,
  goBack as goBackOp,
  goForward as goForwardOp,
  resizeColumns as resizeColumnsOp,
  resizeGroups as resizeGroupsOp,
  closeGroup as closeGroupOp,
  closeLeavesToRight as closeRightOp,
  closeLeaf as closeLeafOp,
  closeOtherLeaves as closeOthersOp,
  deserialize,
  focusGroup as focusGroupOp,
  focusLeaf as focusLeafOp,
  moveTab as moveTabOp,
  newTab as newTabOp,
  openOrFocusPage,
  serialize,
  splitLeaf as splitLeafOp,
  toggleStacked as toggleStackedOp,
  togglePinned as togglePinnedOp,
  type LeafId,
  type TabGroupId,
  type WorkspaceState,
} from "./wikiWorkspace";
import { createWorkspaceSync, type WorkspaceSync } from "./wikiWorkspaceSync";

const STORAGE_KEY = "wiki:workspace";

function load(): WorkspaceState {
  if (typeof window === "undefined") return buildInitial();
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return buildInitial();
    return deserialize(JSON.parse(raw)) ?? buildInitial();
  } catch {
    return buildInitial();
  }
}

function persist(state: WorkspaceState): void {
  if (typeof window === "undefined") return;
  try {
    const snap = serialize(state);
    if (snap === null) sessionStorage.removeItem(STORAGE_KEY);
    else sessionStorage.setItem(STORAGE_KEY, JSON.stringify(snap));
  } catch {
    /* private mode — non-fatal */
  }
}

export interface UseWikiWorkspace {
  state: WorkspaceState;
  /** Open/focus a page in the active group (replace-in-place by default). */
  openPage: (pageId: string, opts?: { newTab?: boolean }) => void;
  newTab: () => void;
  focusLeaf: (id: LeafId) => void;
  focusGroup: (id: TabGroupId) => void;
  closeLeaf: (id: LeafId) => void;
  closeOthers: (id: LeafId) => void;
  closeRight: (id: LeafId) => void;
  split: (id: LeafId, direction: "right" | "down") => void;
  closeGroup: (id: TabGroupId) => void;
  moveTab: (id: LeafId, targetGroupId: TabGroupId, beforeLeafId: LeafId | null) => void;
  toggleStacked: (id: TabGroupId) => void;
  togglePinned: (id: LeafId) => void;
  goBack: (id: LeafId) => void;
  goForward: (id: LeafId) => void;
  resizeColumns: (leftColIdx: number, leftW: number, rightW: number) => void;
  resizeGroups: (aboveId: TabGroupId, belowId: TabGroupId, aboveH: number, belowH: number) => void;
}

/**
 * Stateful wrapper around the pure workspace reducers (./wikiWorkspace).
 * Owns the live `WorkspaceState`, persists every change to sessionStorage, and
 * exposes the action set. Router sync (URL ⇄ active leaf) is intentionally NOT
 * here — the caller (WikiPage) drives `openPage` from the route and navigates
 * when the active page changes, so the hook stays router-agnostic + testable.
 */
export function useWikiWorkspace(opts: { sync?: boolean } = {}): UseWikiWorkspace {
  const syncEnabled = opts.sync ?? true;
  const [state, setState] = React.useState<WorkspaceState>(load);

  // ── cross-window sync (granite parity) ────────────────────────────────────
  // Other wiki windows mirror this workspace via BroadcastChannel. Guards
  // against the cross-tab loop class: a monotonic timestamp (newer wins), an
  // echo-suppression flag so applying a peer snapshot never re-broadcasts, and
  // skipping the initial broadcast so a freshly-opened window can't clobber a
  // peer with its restored-from-storage state. Pop-out windows pass sync:false.
  const syncRef = React.useRef<WorkspaceSync | null>(null);
  const lastMsRef = React.useRef(0);
  const suppressRef = React.useRef(false);
  const mountedRef = React.useRef(false);

  React.useEffect(() => {
    if (!syncEnabled || typeof window === "undefined") return;
    const sync = createWorkspaceSync();
    syncRef.current = sync;
    const unsub = sync.subscribe((msg) => {
      if (msg.updatedMs <= lastMsRef.current) return; // stale / out-of-order
      const restored = deserialize(msg.snapshot);
      if (!restored) return;
      lastMsRef.current = msg.updatedMs;
      suppressRef.current = true; // the resulting setState must NOT re-broadcast
      setState(restored);
    });
    return () => {
      unsub();
      sync.close();
      syncRef.current = null;
    };
  }, [syncEnabled]);

  // Persist on every change (serialize() skips the pristine empty workspace),
  // then broadcast to peers — unless this change came FROM a peer.
  React.useEffect(() => {
    persist(state);
    if (!syncEnabled) return;
    if (!mountedRef.current) {
      mountedRef.current = true; // skip the initial broadcast (no clobber)
      return;
    }
    if (suppressRef.current) {
      suppressRef.current = false; // peer apply — don't echo it back
      return;
    }
    const sync = syncRef.current;
    if (!sync) return;
    const ms = Math.max(Date.now(), lastMsRef.current + 1); // strictly monotonic
    lastMsRef.current = ms;
    sync.postWorkspaceUpdated(serialize(state), ms);
  }, [state, syncEnabled]);

  // Each action applies its pure reducer; setState bails the render when the
  // reducer returns the same reference (the reducers are no-op-stable).
  const openPage = React.useCallback(
    (pageId: string, opts?: { newTab?: boolean }) =>
      setState((s) => openOrFocusPage(s, pageId, opts)),
    [],
  );
  const newTab = React.useCallback(() => setState(newTabOp), []);
  const focusLeaf = React.useCallback((id: LeafId) => setState((s) => focusLeafOp(s, id)), []);
  const focusGroup = React.useCallback((id: TabGroupId) => setState((s) => focusGroupOp(s, id)), []);
  const closeLeaf = React.useCallback((id: LeafId) => setState((s) => closeLeafOp(s, id)), []);
  const closeOthers = React.useCallback((id: LeafId) => setState((s) => closeOthersOp(s, id)), []);
  const closeRight = React.useCallback((id: LeafId) => setState((s) => closeRightOp(s, id)), []);
  const split = React.useCallback(
    (id: LeafId, direction: "right" | "down") => setState((s) => splitLeafOp(s, id, direction)),
    [],
  );
  const closeGroup = React.useCallback((id: TabGroupId) => setState((s) => closeGroupOp(s, id)), []);
  const moveTab = React.useCallback(
    (id: LeafId, targetGroupId: TabGroupId, beforeLeafId: LeafId | null) =>
      setState((s) => moveTabOp(s, id, targetGroupId, beforeLeafId)),
    [],
  );
  const toggleStacked = React.useCallback(
    (id: TabGroupId) => setState((s) => toggleStackedOp(s, id)),
    [],
  );
  const togglePinned = React.useCallback((id: LeafId) => setState((s) => togglePinnedOp(s, id)), []);
  const goBack = React.useCallback((id: LeafId) => setState((s) => goBackOp(s, id)), []);
  const goForward = React.useCallback((id: LeafId) => setState((s) => goForwardOp(s, id)), []);
  const resizeColumns = React.useCallback(
    (leftColIdx: number, leftW: number, rightW: number) =>
      setState((s) => resizeColumnsOp(s, leftColIdx, leftW, rightW)),
    [],
  );
  const resizeGroups = React.useCallback(
    (aboveId: TabGroupId, belowId: TabGroupId, aboveH: number, belowH: number) =>
      setState((s) => resizeGroupsOp(s, aboveId, belowId, aboveH, belowH)),
    [],
  );

  return {
    state,
    openPage,
    newTab,
    focusLeaf,
    focusGroup,
    closeLeaf,
    closeOthers,
    closeRight,
    split,
    closeGroup,
    moveTab,
    toggleStacked,
    togglePinned,
    goBack,
    goForward,
    resizeColumns,
    resizeGroups,
  };
}
