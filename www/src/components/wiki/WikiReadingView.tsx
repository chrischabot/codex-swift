import { Hash } from "lucide-react";
import type { WikiPage } from "@/runtime/connector";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { WikiMarkdown } from "./WikiMarkdown";

interface Props {
  page: WikiPage;
  /** Invoked when an internal wikilink `[[Target]]` / embed is clicked. */
  onWikiLink?: (target: string) => void;
  /** Invoked when a tag chip is clicked. Receives the bare tag (no leading #). */
  onTag?: (tag: string) => void;
}

/**
 * Reading view for a single wiki page: an H1 title, a row of clickable tag
 * chips, and the page body rendered through WikiMarkdown (with the Obsidian
 * markdown extensions). This is the read-only surface; editing/rename and the
 * right-rail panels (backlinks/outline/properties) live elsewhere.
 */
export function WikiReadingView({ page, onWikiLink, onTag }: Props) {
  const tags = page.tags ?? [];
  return (
    <article className="wiki-reading-view mx-auto w-full max-w-3xl px-1">
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

      <WikiMarkdown content={page.content} onWikiLink={onWikiLink} />
    </article>
  );
}
