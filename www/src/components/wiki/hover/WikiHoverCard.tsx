import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage } from "@/runtime/connector";
import { WikiMarkdown } from "@/components/wiki/WikiMarkdown";
import { cn } from "@/lib/utils";

interface Props {
  /** Resolved page id to preview. When set, fetched on mount. */
  pageId?: string;
  /** Display title shown in the header (falls back to the loaded page title). */
  title?: string;
  /** Open the previewed page (header click) — forwarded from the wrapper. */
  onOpen?: () => void;
  className?: string;
}

const PREVIEW_CHARS = 400;

/**
 * Compact preview card for a wikilink target — the granite HoverPopover ported
 * to www's connector + markdown pipeline. Mounts only when the host HoverCard
 * is open (radix unmounts closed content), so the fetch fires on hover-intent.
 *
 * Loads the page via `connector.getWikiPage(pageId)` and renders the title plus
 * the first ~400 chars of the body. Body is truncated on a paragraph/word
 * boundary then handed to WikiMarkdown so wikilinks/callouts/highlight render
 * the same as the reading view (links inside the preview are inert — no
 * onWikiLink handler is passed).
 */
export function WikiHoverCard({ pageId, title, onOpen, className }: Props) {
  const { connector, status } = useRuntime();
  const [page, setPage] = React.useState<WikiPage | null>(null);
  const [state, setState] = React.useState<"loading" | "ready" | "missing">("loading");

  React.useEffect(() => {
    if (!pageId || !connector.getWikiPage || status.kind !== "connected") {
      setState("missing");
      return;
    }
    let alive = true;
    setState("loading");
    setPage(null);
    connector
      .getWikiPage(pageId)
      .then((p) => {
        if (!alive) return;
        if (p) {
          setPage(p);
          setState("ready");
        } else {
          setState("missing");
        }
      })
      .catch(() => {
        if (alive) setState("missing");
      });
    return () => {
      alive = false;
    };
  }, [connector, status.kind, pageId]);

  const heading = page?.title ?? title ?? "Untitled";
  const excerpt = React.useMemo(() => truncate(page?.content ?? "", PREVIEW_CHARS), [page?.content]);

  return (
    <div className={cn("flex max-h-[280px] flex-col gap-2 p-2", className)}>
      <button
        type="button"
        disabled={!onOpen}
        onClick={onOpen}
        className={cn(
          "truncate text-left text-[13px] font-semibold text-foreground",
          onOpen && "cursor-pointer hover:text-[color:var(--text-link)]",
        )}
      >
        {heading}
      </button>
      <div className="min-h-0 flex-1 overflow-y-auto text-[12.5px] leading-[1.55]">
        {state === "loading" ? (
          <span className="text-[color:var(--color-text-tertiary)] italic">Loading…</span>
        ) : state === "missing" ? (
          <span className="text-[color:var(--color-text-tertiary)] italic">Page not found</span>
        ) : excerpt ? (
          <WikiMarkdown content={excerpt} />
        ) : (
          <span className="text-[color:var(--color-text-tertiary)] italic">Empty page</span>
        )}
      </div>
    </div>
  );
}

/** Truncate markdown at a word boundary near `max`, appending an ellipsis. */
function truncate(text: string, max: number): string {
  if (text.length <= max) return text;
  const slice = text.slice(0, max);
  const lastBreak = Math.max(slice.lastIndexOf("\n\n"), slice.lastIndexOf(" "));
  const cut = lastBreak > max * 0.5 ? slice.slice(0, lastBreak) : slice;
  return `${cut.trimEnd()}…`;
}
