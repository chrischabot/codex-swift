import * as React from "react";
import { cn } from "@/lib/utils";
import { WikiPaneTabStrip, type PaneTabActions } from "./WikiPaneTabStrip";
import { WikiLeafBody, type LeafBodyCallbacks } from "./WikiLeafBody";
import {
  canGoBack,
  canGoForward,
  columnWidthWeight,
  groupHeightWeight,
  leavesOfGroup,
  type Leaf,
  type TabGroupId,
} from "./wikiWorkspace";
import { popOutPage } from "./popout";
import type { UseWikiWorkspace } from "./useWikiWorkspace";

/**
 * A draggable divider between two flex siblings. On drag it reads the two
 * adjacent panes' rects and redistributes their COMBINED weight by the pointer
 * position, leaving the rest of the layout untouched. `orientation` picks the
 * axis; `onResize(leftW, rightW)` receives the new weights.
 */
function ResizeHandle({
  orientation,
  leftWeight,
  rightWeight,
  onResize,
}: {
  orientation: "col" | "row";
  leftWeight: number;
  rightWeight: number;
  onResize: (leftW: number, rightW: number) => void;
}) {
  const ref = React.useRef<HTMLDivElement>(null);
  const horizontal = orientation === "col";
  const onPointerDown = (e: React.PointerEvent<HTMLDivElement>) => {
    e.preventDefault();
    e.stopPropagation();
    const handle = ref.current;
    const prev = handle?.previousElementSibling as HTMLElement | null;
    const next = handle?.nextElementSibling as HTMLElement | null;
    if (!prev || !next) return;
    const pr = prev.getBoundingClientRect();
    const nr = next.getBoundingClientRect();
    const start = horizontal ? pr.left : pr.top;
    const span = (horizontal ? nr.right : nr.bottom) - start;
    if (span <= 0) return;
    const total = leftWeight + rightWeight;
    const move = (ev: PointerEvent) => {
      const pos = horizontal ? ev.clientX : ev.clientY;
      let frac = (pos - start) / span;
      frac = Math.max(0.05, Math.min(0.95, frac));
      onResize(frac * total, (1 - frac) * total);
    };
    const up = () => {
      window.removeEventListener("pointermove", move);
      window.removeEventListener("pointerup", up);
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    };
    document.body.style.cursor = horizontal ? "col-resize" : "row-resize";
    document.body.style.userSelect = "none";
    window.addEventListener("pointermove", move);
    window.addEventListener("pointerup", up);
  };
  return (
    <div
      ref={ref}
      role="separator"
      aria-orientation={horizontal ? "vertical" : "horizontal"}
      onPointerDown={onPointerDown}
      className={
        horizontal
          ? "z-10 -mx-[3px] w-[6px] shrink-0 cursor-col-resize hover:bg-[color:var(--color-accent,theme(colors.blue.500))]/30"
          : "z-10 -my-[3px] h-[6px] shrink-0 cursor-row-resize hover:bg-[color:var(--color-accent,theme(colors.blue.500))]/30"
      }
    />
  );
}

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
      onTogglePinned: ws.togglePinned,
      onPopOut: (leafId) => {
        const leaf = ws.state.leaves.get(leafId);
        if (leaf?.state.type === "page") popOutPage(leaf.state.pageId);
      },
      onMove: ws.moveTab,
      onNewTab: (gid) => {
        ws.focusGroup(gid);
        ws.newTab();
      },
      onToggleStacked: ws.toggleStacked,
      onCloseGroup: ws.closeGroup,
      onBack: ws.goBack,
      onForward: ws.goForward,
    }),
    [ws],
  );

  return (
    <div className="flex min-h-0 flex-1">
      {state.columns.map((column, colIdx) => (
        <React.Fragment key={column.join("|")}>
          {colIdx > 0 && (
            // Divider between the previous column and this one.
            <ResizeHandle
              orientation="col"
              leftWeight={columnWidthWeight(state, colIdx - 1)}
              rightWeight={columnWidthWeight(state, colIdx)}
              onResize={(lw, rw) => ws.resizeColumns(colIdx - 1, lw, rw)}
            />
          )}
          <div
            className="flex min-w-0 flex-col border-r border-[color:var(--border)] last:border-r-0"
            style={{ flex: `${columnWidthWeight(state, colIdx)} 1 0` }}
          >
            {column.map((gid, rowIdx) => {
              const group = state.groups.get(gid);
              if (!group) return null;
              const leaves = leavesOfGroup(state, gid);
              const activeLeaf = group.activeLeafId ? state.leaves.get(group.activeLeafId) ?? null : null;
              const isActiveGroup = state.activeGroupId === gid;
              const prevGid = column[rowIdx - 1];
              return (
                <React.Fragment key={gid}>
                  {rowIdx > 0 && prevGid && (
                    <ResizeHandle
                      orientation="row"
                      leftWeight={groupHeightWeight(state, prevGid)}
                      rightWeight={groupHeightWeight(state, gid)}
                      onResize={(ah, bh) => ws.resizeGroups(prevGid, gid, ah, bh)}
                    />
                  )}
                  <div
                    className={cn(
                      "flex min-h-0 flex-col border-b border-[color:var(--border)] last:border-b-0",
                      isActiveGroup && totalGroups > 1 && "ring-1 ring-inset ring-[color:var(--border)]",
                    )}
                    style={{ flex: `${groupHeightWeight(state, gid)} 1 0` }}
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
                      canBack={!!group.activeLeafId && canGoBack(state, group.activeLeafId)}
                      canForward={!!group.activeLeafId && canGoForward(state, group.activeLeafId)}
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
                </React.Fragment>
              );
            })}
          </div>
        </React.Fragment>
      ))}
    </div>
  );
}
