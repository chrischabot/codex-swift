import { Star, StarOff, X } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { cn } from "@/lib/utils";
import { useBookmarks } from "./useBookmarks";

interface Props {
  /** Override navigation (e.g. for embedding outside the router). Defaults to
   *  react-router navigation to `/wiki/:id`. */
  onSelect?: (id: string) => void;
}

/**
 * Sidebar panel listing bookmarked wiki pages, newest first. Clicking a row
 * navigates to the page; the trailing button removes the bookmark. Empty state
 * mirrors granite's `bookmarks.empty` notice.
 */
export function WikiBookmarksPanel({ onSelect }: Props) {
  const { list, remove } = useBookmarks();
  const navigate = useNavigate();

  const open = (id: string) => {
    if (onSelect) onSelect(id);
    else navigate(`/wiki/${id}`);
  };

  if (list.length === 0) {
    return (
      <div className="flex flex-col items-center gap-2 px-3 py-8 text-center">
        <StarOff
          size={20}
          className="text-[color:var(--color-text-quaternary)]"
          aria-hidden
        />
        <p className="text-[length:var(--text-sm)] text-[color:var(--color-text-quaternary)]">
          No bookmarks yet. Star a page to keep it here.
        </p>
      </div>
    );
  }

  return (
    <nav className="flex flex-col py-1" aria-label="Bookmarks">
      {list.map((b) => {
        const label = b.title?.trim() || b.id;
        return (
          <div
            key={b.id}
            className={cn(
              "group flex w-full items-center gap-2 px-3 py-1.5",
              "transition-colors hover:bg-[color:var(--color-surface-hover)]",
            )}
          >
            <button
              type="button"
              onClick={() => open(b.id)}
              title={label}
              className="flex min-w-0 flex-1 items-center gap-2 text-left"
            >
              <Star
                size={14}
                className="shrink-0 fill-current text-[color:var(--color-text-link)]"
                aria-hidden
              />
              <span
                className={cn(
                  "min-w-0 truncate text-[length:var(--text-sm)] text-foreground",
                  "group-hover:text-[color:var(--color-text-link)]",
                )}
              >
                {label}
              </span>
            </button>
            <button
              type="button"
              aria-label={`Remove bookmark: ${label}`}
              title="Remove bookmark"
              onClick={() => remove(b.id)}
              className={cn(
                "inline-flex h-6 w-6 shrink-0 items-center justify-center rounded-md",
                "text-[color:var(--color-text-quaternary)] opacity-0",
                "transition-opacity group-hover:opacity-100 focus-visible:opacity-100",
                "hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
                "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--color-text-link)]",
              )}
            >
              <X size={14} aria-hidden />
            </button>
          </div>
        );
      })}
    </nav>
  );
}
