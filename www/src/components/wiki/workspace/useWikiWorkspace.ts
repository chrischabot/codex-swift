import * as React from "react";
import {
  buildInitial,
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
  type LeafId,
  type TabGroupId,
  type WorkspaceState,
} from "./wikiWorkspace";

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
}

/**
 * Stateful wrapper around the pure workspace reducers (./wikiWorkspace).
 * Owns the live `WorkspaceState`, persists every change to sessionStorage, and
 * exposes the action set. Router sync (URL ⇄ active leaf) is intentionally NOT
 * here — the caller (WikiPage) drives `openPage` from the route and navigates
 * when the active page changes, so the hook stays router-agnostic + testable.
 */
export function useWikiWorkspace(): UseWikiWorkspace {
  const [state, setState] = React.useState<WorkspaceState>(load);

  // Persist on every change. serialize() skips the pristine empty workspace.
  React.useEffect(() => { persist(state); }, [state]);

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
  };
}
