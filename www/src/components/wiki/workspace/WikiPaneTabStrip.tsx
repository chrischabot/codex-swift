import * as React from "react";
import { X, Plus, Rows, Columns, SplitSquareHorizontal, SplitSquareVertical, Pin, PinOff, ChevronLeft, ChevronRight, ExternalLink } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import type { Leaf, TabGroupId } from "./wikiWorkspace";

/** DnD payload: the leaf id being dragged. */
export const TAB_DND_MIME = "application/wiki-leaf";

export interface PaneTabActions {
  onSelect: (leafId: string) => void;
  onClose: (leafId: string) => void;
  onCloseOthers: (leafId: string) => void;
  onCloseRight: (leafId: string) => void;
  onSplit: (leafId: string, direction: "right" | "down") => void;
  onTogglePinned: (leafId: string) => void;
  onPopOut: (leafId: string) => void;
  onMove: (leafId: string, targetGroupId: TabGroupId, beforeLeafId: string | null) => void;
  onNewTab: (groupId: TabGroupId) => void;
  onToggleStacked: (groupId: TabGroupId) => void;
  onCloseGroup: (groupId: TabGroupId) => void;
  /** Back/forward within the group's active leaf history. */
  onBack: (leafId: string) => void;
  onForward: (leafId: string) => void;
}

interface Props {
  groupId: TabGroupId;
  leaves: ReadonlyArray<Leaf>;
  activeLeafId: string | null;
  stacked: boolean;
  /** False hides the close-group control (last group standing). */
  canCloseGroup: boolean;
  /** Page id → display title (live page list). Falls back to "Untitled". */
  titleById: ReadonlyMap<string, string>;
  /** History availability for the group's active leaf. */
  canBack: boolean;
  canForward: boolean;
  actions: PaneTabActions;
}

function leafTitle(leaf: Leaf, titleById: ReadonlyMap<string, string>): string {
  switch (leaf.state.type) {
    case "empty":
      return "New tab";
    case "graph":
      return "Graph";
    case "search":
      return leaf.state.query ? `Search: ${leaf.state.query}` : "Search";
    case "page":
      return titleById.get(leaf.state.pageId) || "Untitled";
  }
}

/**
 * Per-group tab strip for a workspace pane. Tabs are draggable (reorder within a
 * group, or transfer to another group); the strip's trailing controls add a new
 * tab, toggle stacked rendering, and close the whole group. Right-click a tab
 * for close / split actions. Mirrors granite's TabStrip + Tab, on the pure
 * workspace model.
 */
export function WikiPaneTabStrip({
  groupId,
  leaves,
  activeLeafId,
  stacked,
  canCloseGroup,
  titleById,
  canBack,
  canForward,
  actions,
}: Props) {
  const innerRef = React.useRef<HTMLDivElement>(null);
  const [insertBefore, setInsertBefore] = React.useState<string | null | undefined>(undefined);

  const onDragOver = (e: React.DragEvent<HTMLDivElement>) => {
    if (!Array.from(e.dataTransfer.types).includes(TAB_DND_MIME)) return;
    e.preventDefault();
    e.dataTransfer.dropEffect = "move";
    const inner = innerRef.current;
    if (!inner) return;
    const tabs = inner.querySelectorAll<HTMLElement>("[data-leaf-id]");
    let target: string | null = null;
    for (const tab of tabs) {
      const rect = tab.getBoundingClientRect();
      const past = stacked
        ? e.clientY < rect.top + rect.height / 2
        : e.clientX < rect.left + rect.width / 2;
      if (past) {
        target = tab.getAttribute("data-leaf-id");
        break;
      }
    }
    setInsertBefore(target);
  };

  const onDrop = (e: React.DragEvent<HTMLDivElement>) => {
    const id = e.dataTransfer.getData(TAB_DND_MIME);
    if (!id) {
      setInsertBefore(undefined);
      return;
    }
    e.preventDefault();
    actions.onMove(id, groupId, insertBefore ?? null);
    setInsertBefore(undefined);
  };

  return (
    <div
      className={cn(
        "flex shrink-0 border-b border-[color:var(--border)]",
        stacked ? "flex-col" : "items-stretch",
      )}
      onDragOver={onDragOver}
      onDragLeave={() => setInsertBefore(undefined)}
      onDrop={onDrop}
    >
      {!stacked && (
        <div className="flex shrink-0 items-center gap-0.5 pl-1.5 py-1">
          <StripButton
            ariaLabel="Back"
            disabled={!canBack || !activeLeafId}
            onClick={() => activeLeafId && actions.onBack(activeLeafId)}
          >
            <ChevronLeft className="size-3.5" />
          </StripButton>
          <StripButton
            ariaLabel="Forward"
            disabled={!canForward || !activeLeafId}
            onClick={() => activeLeafId && actions.onForward(activeLeafId)}
          >
            <ChevronRight className="size-3.5" />
          </StripButton>
        </div>
      )}
      <div
        ref={innerRef}
        role="tablist"
        aria-label="Pane tabs"
        className={cn(
          "flex min-w-0 flex-1 gap-0.5 px-1.5 py-1",
          stacked ? "flex-col" : "items-stretch overflow-x-auto",
        )}
      >
        {leaves.map((leaf) => {
          const active = leaf.id === activeLeafId;
          const title = leafTitle(leaf, titleById);
          const pinned = leaf.state.type === "page" && !!leaf.state.pinned;
          return (
            <ContextMenu key={leaf.id}>
              <ContextMenuTrigger asChild>
                <div
                  data-leaf-id={leaf.id}
                  role="tab"
                  aria-selected={active}
                  tabIndex={0}
                  draggable
                  onDragStart={(e) => {
                    e.dataTransfer.effectAllowed = "move";
                    e.dataTransfer.setData(TAB_DND_MIME, leaf.id);
                    e.dataTransfer.setData("text/plain", title);
                  }}
                  onClick={() => actions.onSelect(leaf.id)}
                  onAuxClick={(e) => {
                    if (e.button === 1) {
                      e.preventDefault();
                      e.stopPropagation();
                      actions.onClose(leaf.id);
                    }
                  }}
                  onKeyDown={(e) => {
                    if (e.key === "Enter" || e.key === " ") {
                      e.preventDefault();
                      actions.onSelect(leaf.id);
                    }
                  }}
                  className={cn(
                    "group flex shrink-0 cursor-pointer items-center gap-1 rounded-md py-1 pl-2.5 pr-1 text-[12px] transition-colors",
                    stacked ? "w-full" : "max-w-[200px]",
                    active
                      ? "bg-[color:var(--color-surface-hover)] font-medium text-foreground"
                      : "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
                    insertBefore === leaf.id &&
                      (stacked
                        ? "border-t-2 border-t-[color:var(--color-accent,theme(colors.blue.500))]"
                        : "border-l-2 border-l-[color:var(--color-accent,theme(colors.blue.500))]"),
                  )}
                >
                  <span className="truncate">{title}</span>
                  {pinned ? (
                    // A pinned tab shows a persistent pin (click to unpin) in
                    // place of the hover-close X — matching Obsidian.
                    <button
                      type="button"
                      aria-label={`Unpin ${title}`}
                      onClick={(e) => {
                        e.stopPropagation();
                        actions.onTogglePinned(leaf.id);
                      }}
                      className="inline-flex size-4 shrink-0 items-center justify-center rounded text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--border)]"
                    >
                      <Pin className="size-3" />
                    </button>
                  ) : (
                    <button
                      type="button"
                      aria-label={`Close ${title}`}
                      onClick={(e) => {
                        e.stopPropagation();
                        actions.onClose(leaf.id);
                      }}
                      className="inline-flex size-4 shrink-0 items-center justify-center rounded opacity-0 transition-opacity hover:bg-[color:var(--border)] group-hover:opacity-100"
                    >
                      <X className="size-3" />
                    </button>
                  )}
                </div>
              </ContextMenuTrigger>
              <ContextMenuContent className="w-48">
                <ContextMenuItem onSelect={() => actions.onClose(leaf.id)}>Close</ContextMenuItem>
                <ContextMenuItem
                  onSelect={() => actions.onCloseOthers(leaf.id)}
                  disabled={leaves.length <= 1}
                >
                  Close others
                </ContextMenuItem>
                <ContextMenuItem
                  onSelect={() => actions.onCloseRight(leaf.id)}
                  disabled={leaves[leaves.length - 1]?.id === leaf.id}
                >
                  Close to the right
                </ContextMenuItem>
                <ContextMenuSeparator />
                <ContextMenuItem onSelect={() => actions.onSplit(leaf.id, "right")}>
                  <SplitSquareHorizontal className="mr-2 size-3.5" /> Split right
                </ContextMenuItem>
                <ContextMenuItem onSelect={() => actions.onSplit(leaf.id, "down")}>
                  <SplitSquareVertical className="mr-2 size-3.5" /> Split down
                </ContextMenuItem>
                {leaf.state.type === "page" && (
                  <>
                    <ContextMenuSeparator />
                    <ContextMenuItem onSelect={() => actions.onTogglePinned(leaf.id)}>
                      {pinned ? (
                        <>
                          <PinOff className="mr-2 size-3.5" /> Unpin
                        </>
                      ) : (
                        <>
                          <Pin className="mr-2 size-3.5" /> Pin
                        </>
                      )}
                    </ContextMenuItem>
                    <ContextMenuItem onSelect={() => actions.onPopOut(leaf.id)}>
                      <ExternalLink className="mr-2 size-3.5" /> Open in new window
                    </ContextMenuItem>
                  </>
                )}
              </ContextMenuContent>
            </ContextMenu>
          );
        })}
        <div
          className={cn(
            "flex-1",
            insertBefore === null &&
              (stacked
                ? "border-t-2 border-t-[color:var(--color-accent,theme(colors.blue.500))]"
                : "border-l-2 border-l-[color:var(--color-accent,theme(colors.blue.500))]"),
          )}
        />
      </div>
      <div className="flex shrink-0 items-center gap-0.5 px-1.5 py-1">
        <StripButton ariaLabel="New tab" onClick={() => actions.onNewTab(groupId)}>
          <Plus className="size-3.5" />
        </StripButton>
        <StripButton
          ariaLabel={stacked ? "Unstack tabs" : "Stack tabs"}
          onClick={() => actions.onToggleStacked(groupId)}
        >
          {stacked ? <Columns className="size-3.5" /> : <Rows className="size-3.5" />}
        </StripButton>
        {canCloseGroup && (
          <StripButton ariaLabel="Close pane" onClick={() => actions.onCloseGroup(groupId)}>
            <X className="size-3.5" />
          </StripButton>
        )}
      </div>
    </div>
  );
}

function StripButton({
  ariaLabel,
  onClick,
  disabled,
  children,
}: {
  ariaLabel: string;
  onClick: () => void;
  disabled?: boolean;
  children: React.ReactNode;
}) {
  return (
    <button
      type="button"
      aria-label={ariaLabel}
      onClick={onClick}
      disabled={disabled}
      className="inline-flex size-6 items-center justify-center rounded-md text-[color:var(--color-text-tertiary)] enabled:hover:bg-[color:var(--color-surface-hover)] enabled:hover:text-foreground disabled:cursor-default disabled:opacity-30"
    >
      {children}
    </button>
  );
}
