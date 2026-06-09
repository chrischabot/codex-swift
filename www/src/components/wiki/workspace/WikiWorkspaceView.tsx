import * as React from "react";
import { cn } from "@/lib/utils";
import { WikiPaneTabStrip, type PaneTabActions } from "./WikiPaneTabStrip";
import { WikiLeafBody, type LeafBodyCallbacks } from "./WikiLeafBody";
import { leavesOfGroup, type Leaf, type TabGroupId } from "./wikiWorkspace";
import type { UseWikiWorkspace } from "./useWikiWorkspace";

interface Props {
  ws: UseWikiWorkspace;
  /** Page id → live title for the tab strips. */
  titleById: ReadonlyMap<string, string>;
  /** Per-pane body callbacks (navigation focuses the pane first). */
  buildCallbacks: (leaf: Leaf, groupId: TabGroupId) => LeafBodyCallbacks;
}

/**
 * Multi-pane wiki workspace: renders the columns → groups → panes tree from the
 * pure model. Columns sit left-to-right; each column stacks its groups
 * top-to-bottom; each group is a pane (tab strip + the active leaf's body).
 * Clicking anywhere in a pane focuses its group so navigation + the global
 * right rail follow it. Drag a tab to reorder or move it between panes; split /
 * close from the tab context menu and the strip controls.
 */
export function WikiWorkspace({ ws, titleById, buildCallbacks }: Props) {
  const { state } = ws;
  const totalGroups = state.rootGroupIds.length;

  const tabActions: PaneTabActions = React.useMemo(
    () => ({
      onSelect: ws.focusLeaf,
      onClose: ws.closeLeaf,
      onCloseOthers: ws.closeOthers,
      onCloseRight: ws.closeRight,
      onSplit: ws.split,
      onMove: ws.moveTab,
      onNewTab: (gid) => {
        ws.focusGroup(gid);
        ws.newTab();
      },
      onToggleStacked: ws.toggleStacked,
      onCloseGroup: ws.closeGroup,
    }),
    [ws],
  );

  return (
    <div className="flex min-h-0 flex-1">
      {state.columns.map((column) => (
        <div
          key={column.join("|")}
          className="flex min-w-0 flex-1 flex-col border-r border-[color:var(--border)] last:border-r-0"
        >
          {column.map((gid) => {
            const group = state.groups.get(gid);
            if (!group) return null;
            const leaves = leavesOfGroup(state, gid);
            const activeLeaf = group.activeLeafId ? state.leaves.get(group.activeLeafId) ?? null : null;
            const isActiveGroup = state.activeGroupId === gid;
            return (
              <div
                key={gid}
                className={cn(
                  "flex min-h-0 flex-1 flex-col border-b border-[color:var(--border)] last:border-b-0",
                  isActiveGroup && totalGroups > 1 && "ring-1 ring-inset ring-[color:var(--border)]",
                )}
                onMouseDown={() => {
                  if (!isActiveGroup) ws.focusGroup(gid);
                }}
              >
                <WikiPaneTabStrip
                  groupId={gid}
                  leaves={leaves}
                  activeLeafId={group.activeLeafId}
                  stacked={!!group.stacked}
                  canCloseGroup={totalGroups > 1}
                  titleById={titleById}
                  actions={tabActions}
                />
                <div className="flex min-h-0 flex-1 flex-col">
                  {activeLeaf && (
                    <WikiLeafBody
                      // Re-mount on page change so per-pane edit state resets.
                      key={
                        activeLeaf.state.type === "page"
                          ? `p:${activeLeaf.id}:${activeLeaf.state.pageId}`
                          : `e:${activeLeaf.id}`
                      }
                      leaf={activeLeaf}
                      isActive={isActiveGroup}
                      callbacks={buildCallbacks(activeLeaf, gid)}
                    />
                  )}
                </div>
              </div>
            );
          })}
        </div>
      ))}
    </div>
  );
}
