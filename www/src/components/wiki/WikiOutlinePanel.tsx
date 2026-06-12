import { useMemo } from "react";
import { cn } from "@/lib/utils";
import { slugify } from "./markdown/wikiRemarkPlugins";
import { maskFencedCode } from "./markdown/codeFences";

/**
 * Heading slug — delegates to the SAME `slugify` the reading view's
 * rehypeHeadingIds uses, so onJump(slug) → document.getElementById(slug)
 * resolves. (Kept as an export for back-compat.)
 */
export function slug(text: string): string {
  return slugify(text);
}

/**
 * Approximate the RENDERED text of a heading (what rehypeHeadingIds slugs) by
 * stripping inline markdown from the raw heading source: wikilinks → display,
 * `[txt](url)` → txt, inline code/emphasis/highlight markers removed. Without
 * this the outline would slug `## [API](u)` as the raw string and never match
 * the rendered id (which comes from the text "API").
 */
function renderedText(md: string): string {
  return md
    .replace(/!?\[\[([^\]|]+)(?:\|([^\]]+))?\]\]/g, (_m, target, alias) => alias ?? target)
    .replace(/!?\[([^\]]*)\]\([^)]*\)/g, "$1")
    .replace(/`([^`]+)`/g, "$1")
    .replace(/([*_~]{1,3})(.+?)\1/g, "$2")
    .replace(/==(.+?)==/g, "$1")
    .trim();
}

interface OutlineHeading {
  level: number; // 1..6
  text: string;
  slug: string;
}

/**
 * Parse ATX headings (`# ` .. `###### `) out of markdown, ignoring any heading
 * lines that fall inside a fenced code block (``` or ~~~). Trailing closing
 * hashes (`## Foo ##`) are stripped, matching CommonMark.
 */
function parseHeadings(content: string): OutlineHeading[] {
  // Fenced-code lines are blanked (shared masker); inline code is preserved so
  // heading text stays intact for slug computation.
  const lines = maskFencedCode(content, { inlineCode: false });
  const out: OutlineHeading[] = [];
  for (const line of lines) {
    const headingMatch = line.match(/^\s{0,3}(#{1,6})\s+(.*?)\s*$/);
    if (!headingMatch) continue;
    const level = headingMatch[1].length;
    const raw = headingMatch[2].replace(/\s+#+\s*$/, "").trim();
    const text = renderedText(raw);
    if (!text) continue;
    out.push({ level, text, slug: slugify(text) });
  }
  return out;
}

interface Footnote {
  /** The footnote label, e.g. "1" or "note". */
  id: string;
  /** First-line definition text, inline-markdown stripped. */
  text: string;
  /** The rendered anchor id of the definition (remark-gfm clobber scheme). */
  anchorId: string;
}

/**
 * Parse footnote DEFINITIONS (`[^id]: text`) out of markdown, skipping fenced
 * code. The rendered definition lands in `<section class="footnotes">` with
 * `id="user-content-fn-<label>"` (remark-gfm's default clobber prefix), so the
 * panel can scroll to it via the same getElementById onJump the outline uses.
 */
export function parseFootnotes(content: string): Footnote[] {
  // Fenced-code lines blanked (shared masker) so a `[^x]:` inside a code block
  // isn't read as a definition; inline code preserved for the definition text.
  const lines = maskFencedCode(content, { inlineCode: false });
  const out: Footnote[] = [];
  const seen = new Set<string>();
  for (const line of lines) {
    const m = line.match(/^\s{0,3}\[\^([^\]]+)\]:\s*(.*)$/);
    if (!m) continue;
    const id = m[1].trim();
    if (!id || seen.has(id)) continue;
    seen.add(id);
    out.push({ id, text: renderedText(m[2].trim()) || `Footnote ${id}`, anchorId: `user-content-fn-${id}` });
  }
  return out;
}

interface Props {
  content: string;
  onJump?: (slug: string) => void;
}

export function WikiOutlinePanel({ content, onJump }: Props) {
  const headings = useMemo(() => parseHeadings(content), [content]);
  const footnotes = useMemo(() => parseFootnotes(content), [content]);

  // Normalize indentation against the shallowest heading present so a doc that
  // starts at h2 doesn't waste a level of left padding.
  const minLevel = useMemo(
    () => headings.reduce((m, h) => Math.min(m, h.level), 6),
    [headings],
  );

  if (headings.length === 0 && footnotes.length === 0) {
    return (
      <div className="px-3 py-4 text-[length:var(--text-sm)] text-[color:var(--color-text-quaternary)]">
        No headings
      </div>
    );
  }

  return (
    <nav className="flex flex-col py-1" aria-label="Outline">
      {headings.map((h, i) => {
        const depth = Math.max(0, h.level - minLevel);
        return (
          <button
            key={`${i}:${h.slug}`}
            type="button"
            title={h.text}
            onClick={() => onJump?.(h.slug)}
            style={{ paddingInlineStart: 8 + depth * 14 }}
            className={cn(
              "flex w-full items-center truncate rounded-sm py-1 pr-2 text-left",
              "text-[length:var(--text-sm)] leading-tight",
              "text-[color:var(--color-text-secondary)]",
              "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
              h.level === 1 && "font-medium text-foreground",
            )}
          >
            <span className="truncate">{h.text}</span>
          </button>
        );
      })}

      {footnotes.length > 0 && (
        <>
          <div
            className={cn(
              "mt-2 px-2 pb-1 pt-2 text-[11px] font-semibold uppercase tracking-[0.05em]",
              "text-[color:var(--color-text-quaternary)]",
              headings.length > 0 && "border-t border-[color:var(--border)]",
            )}
          >
            Footnotes
          </div>
          {footnotes.map((f) => (
            <button
              key={f.id}
              type="button"
              title={f.text}
              onClick={() => onJump?.(f.anchorId)}
              style={{ paddingInlineStart: 8 }}
              className={cn(
                "flex w-full items-center gap-1.5 truncate rounded-sm py-1 pr-2 text-left",
                "text-[length:var(--text-sm)] leading-tight text-[color:var(--color-text-secondary)]",
                "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
              )}
            >
              <span className="shrink-0 font-mono text-[11px] text-[color:var(--text-link)]">[{f.id}]</span>
              <span className="truncate">{f.text}</span>
            </button>
          ))}
        </>
      )}
    </nav>
  );
}
