import { Star } from "lucide-react";
import { cn } from "@/lib/utils";
import { useBookmarks } from "./useBookmarks";

interface Props {
  pageId: string;
  /** Cached title stored alongside the id so the panel can label it offline. */
  title?: string;
  className?: string;
}

/**
 * Star toggle for bookmarking the current wiki page. A filled star = bookmarked.
 * Mirrors granite's per-item bookmark affordance, scaled down to a single
 * page-level control.
 */
export function BookmarkButton({ pageId, title, className }: Props) {
  const { isBookmarked, toggle } = useBookmarks();
  const active = isBookmarked(pageId);

  return (
    <button
      type="button"
      aria-pressed={active}
      aria-label={active ? "Remove bookmark" : "Add bookmark"}
      title={active ? "Remove bookmark" : "Add bookmark"}
      disabled={!pageId}
      onClick={() => toggle(pageId, title)}
      className={cn(
        "inline-flex h-7 w-7 shrink-0 items-center justify-center rounded-md",
        "text-[color:var(--color-text-tertiary)]",
        "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--color-text-link)]",
        "disabled:pointer-events-none disabled:opacity-50",
        active && "text-[color:var(--color-text-link)] hover:text-[color:var(--color-text-link)]",
        className,
      )}
    >
      <Star size={16} className={cn(active && "fill-current")} aria-hidden />
    </button>
  );
}
