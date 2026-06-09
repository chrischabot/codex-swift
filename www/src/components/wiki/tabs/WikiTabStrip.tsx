import { X } from "lucide-react";
import { cn } from "@/lib/utils";
import type { WikiTab } from "./wikiTabs";

interface Props {
  tabs: ReadonlyArray<WikiTab>;
  /** The id of the currently-open page (route-driven). */
  activeId?: string;
  onSelect: (id: string) => void;
  onClose: (id: string) => void;
}

/**
 * Horizontal strip of open wiki pages (the additive core of Obsidian's tab
 * workspace). The route owns the active page; this just lets you switch/close
 * the open set. Hidden when ≤1 tab is open (no value in a single-tab strip).
 */
export function WikiTabStrip({ tabs, activeId, onSelect, onClose }: Props) {
  if (tabs.length <= 1) return null;
  return (
    <div
      role="tablist"
      aria-label="Open wiki pages"
      className="flex shrink-0 items-stretch gap-0.5 overflow-x-auto border-b border-[color:var(--border)] px-2 py-1"
    >
      {tabs.map((tab) => {
        const active = tab.id === activeId;
        return (
          <div
            key={tab.id}
            role="tab"
            aria-selected={active}
            className={cn(
              "group flex max-w-[200px] shrink-0 items-center gap-1 rounded-md py-1 pl-2.5 pr-1 text-[12px]",
              "cursor-pointer transition-colors",
              active
                ? "bg-[color:var(--color-surface-hover)] font-medium text-foreground"
                : "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
            )}
            onClick={() => onSelect(tab.id)}
            onAuxClick={(e) => {
              // Middle-click closes (Obsidian parity).
              if (e.button === 1) {
                e.preventDefault();
                e.stopPropagation();
                onClose(tab.id);
              }
            }}
          >
            <span className="truncate">{tab.title || "Untitled"}</span>
            <button
              type="button"
              aria-label={`Close ${tab.title || "tab"}`}
              onClick={(e) => {
                e.stopPropagation();
                onClose(tab.id);
              }}
              className="inline-flex size-4 shrink-0 items-center justify-center rounded opacity-0 transition-opacity hover:bg-[color:var(--border)] group-hover:opacity-100"
            >
              <X className="size-3" />
            </button>
          </div>
        );
      })}
    </div>
  );
}
