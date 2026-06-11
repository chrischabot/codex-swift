import * as React from "react";
import { Hash } from "lucide-react";
import type { WikiPage } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { WikiMarkdown } from "./WikiMarkdown";
import type { EmbedLoader } from "./markdown/WikiLiveContext";
import { useWikiSettings } from "./settings/useWikiSettings";
import { stripComments } from "./markdown/wikiRemarkPlugins";
import { scrollToFragment } from "./markdown/fragmentScroll";

interface Props {
  page: WikiPage;
  /** Invoked when an internal wikilink `[[Target]]` / embed is clicked. */
  onWikiLink?: (target: string) => void;
  /** Invoked when a tag chip / inline `#tag` is clicked. Receives the bare tag
   *  (no leading #). */
  onTag?: (tag: string) => void;
  /** Maps a wikilink title to a page id; threaded to WikiMarkdown to enable
   *  hover previews on resolvable `[[wikilinks]]`. */
  resolveWikiLink?: (title: string) => string | undefined;
  /** Optional `#heading` / `#^block` fragment to scroll to + flash after the
   *  body renders (the suffix from a `[[Page#frag]]` open). The leading `#` is
   *  optional; both `Heading` and `#Heading` are accepted. */
  fragment?: string | null;
  /** Notified after an in-place task-checkbox toggle persists, so the host can
   *  refetch the page list / right rail (the body changed). Receives the id. */
  onPageSaved?: (id: string) => void;
  /** Open a page by id — wires the M27 live ```backlinks``` / ```query``` block
   *  rows. When omitted those rows fall back to title-based navigation. */
  onOpenPage?: (id: string) => void;
}

/**
 * Reading view for a single wiki page: an H1 title, a row of clickable tag
 * chips, and the page body rendered through WikiMarkdown (with the Obsidian
 * markdown extensions). This is the read-only surface; editing/rename and the
 * right-rail panels (backlinks/outline/properties) live elsewhere.
 *
 * Two reading-mode interactions live here (M24/M25):
 *   - Task-list checkboxes are clickable: a toggle rewrites the matching source
 *     line and persists via the connector's `saveWikiPage`, with an optimistic
 *     local body so the box flips immediately.
 *   - A `fragment` prop scrolls to + briefly flashes the matching heading /
 *     `block-<id>` anchor once the body has rendered.
 */
export function WikiReadingView({
  page,
  onWikiLink,
  onTag,
  resolveWikiLink,
  fragment,
  onPageSaved,
  onOpenPage,
}: Props) {
  const { connector } = useRuntime();
  const { settings } = useWikiSettings();
  const tags = page.tags ?? [];

  // M27 transclusion loader: resolve `![[Title]]` → page id (via the host's
  // title resolver) → fetch its body. Undefined when the connector can't read
  // pages, which keeps embeds as placeholder cards.
  const loadEmbed = React.useMemo<EmbedLoader | undefined>(() => {
    if (!connector.getWikiPage) return undefined;
    return async (title: string) => {
      const id = resolveWikiLink?.(title);
      if (!id) return null;
      const p = await connector.getWikiPage!(id);
      return p ? { id: p.id, title: p.title, content: p.content } : null;
    };
  }, [connector, resolveWikiLink]);

  // Optimistic local copy of the body so a checkbox flips immediately while the
  // save is in flight. Reset whenever the upstream page (id OR content) changes.
  const [body, setBody] = React.useState(page.content);
  React.useEffect(() => {
    setBody(page.content);
  }, [page.id, page.content]);

  // Serialize saves: a single in-flight guard prevents a fast double-click from
  // racing two rewrites off a stale body (the second would clobber the first).
  const savingRef = React.useRef(false);
  const containerRef = React.useRef<HTMLDivElement | null>(null);

  const canSave = typeof connector.saveWikiPage === "function";

  const handleToggleTask = React.useCallback(
    (line: number, checked: boolean) => {
      if (!canSave || savingRef.current) return;
      // Rewrite against the SAME string WikiMarkdown rendered (comments stripped)
      // so the remark node line index lines up with the array index here.
      const rendered = stripComments(body);
      const lines = rendered.split("\n");
      const cur = lines[line];
      if (cur === undefined) return;
      const next = checked
        ? cur.replace(/^(\s*[-*+]\s+)\[ \]/, "$1[x]")
        : cur.replace(/^(\s*[-*+]\s+)\[[xX]\]/, "$1[ ]");
      if (next === cur) return; // line wasn't a task marker we recognize — bail.
      lines[line] = next;
      const updated = lines.join("\n");

      savingRef.current = true;
      setBody(updated); // optimistic
      void (async () => {
        try {
          const res = await connector.saveWikiPage!({ id: page.id, body: updated });
          if (res && onPageSaved) onPageSaved(res.id);
        } catch {
          // Save failed — roll back to the last known-good body so the UI does
          // not lie about persisted state.
          setBody(page.content);
        } finally {
          savingRef.current = false;
        }
      })();
    },
    [body, canSave, connector, page.id, page.content, onPageSaved],
  );

  // After the body renders (or the fragment changes), scroll to + flash it.
  React.useEffect(() => {
    if (!fragment) return;
    const root = containerRef.current;
    if (!root) return;
    const id = window.setTimeout(() => scrollToFragment(root, fragment), 50);
    return () => window.clearTimeout(id);
  }, [fragment, body]);

  return (
    <article
      ref={containerRef}
      className={cn(
        "wiki-reading-view mx-auto w-full px-1",
        settings.readableLineWidth ? "max-w-[42rem]" : "max-w-3xl",
      )}
    >
      <h1 className="mb-2 text-[28px] font-bold leading-tight tracking-[-0.015em] text-foreground">
        {page.title}
      </h1>

      {tags.length > 0 && (
        <div className="mb-5 flex flex-wrap items-center gap-1.5">
          {tags.map((tag) => {
            const bare = tag.replace(/^#/, "");
            const clickable = typeof onTag === "function";
            return (
              <Badge
                key={tag}
                variant="outline"
                className={cn(
                  "gap-0.5 text-[color:var(--text-link)]",
                  clickable &&
                    "cursor-pointer hover:bg-[color:var(--color-surface-hover)]",
                )}
                role={clickable ? "button" : undefined}
                tabIndex={clickable ? 0 : undefined}
                onClick={clickable ? () => onTag!(bare) : undefined}
                onKeyDown={
                  clickable
                    ? (e) => {
                        if (e.key === "Enter" || e.key === " ") {
                          e.preventDefault();
                          onTag!(bare);
                        }
                      }
                    : undefined
                }
              >
                <Hash className="size-3 shrink-0" aria-hidden />
                {bare}
              </Badge>
            );
          })}
        </div>
      )}

      <WikiMarkdown
        content={body}
        onWikiLink={onWikiLink}
        onTag={onTag}
        resolveWikiLink={resolveWikiLink}
        onToggleTask={canSave ? handleToggleTask : undefined}
        readableLineWidth={settings.readableLineWidth}
        loadEmbed={loadEmbed}
        liveContext={{ pageId: page.id, pageTitle: page.title }}
        onOpenPageId={onOpenPage}
      />
    </article>
  );
}
