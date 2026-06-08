import { useMemo } from "react";
import { cn } from "@/lib/utils";
import { slugify } from "./markdown/wikiRemarkPlugins";

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
  const lines = content.split(/\r?\n/);
  const out: OutlineHeading[] = [];
  let fence: string | null = null; // active fence marker char run, e.g. "```" or "~~~~"

  for (const line of lines) {
    const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fenceMatch) {
      const marker = fenceMatch[1];
      if (fence === null) {
        // opening fence
        fence = marker[0]; // remember the fence char (` or ~)
      } else if (marker[0] === fence) {
        // closing fence (same fence char)
        fence = null;
      }
      continue;
    }
    if (fence !== null) continue; // inside a code block — skip headings

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

interface Props {
  content: string;
  onJump?: (slug: string) => void;
}

export function WikiOutlinePanel({ content, onJump }: Props) {
  const headings = useMemo(() => parseHeadings(content), [content]);

  // Normalize indentation against the shallowest heading present so a doc that
  // starts at h2 doesn't waste a level of left padding.
  const minLevel = useMemo(
    () => headings.reduce((m, h) => Math.min(m, h.level), 6),
    [headings],
  );

  if (headings.length === 0) {
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
    </nav>
  );
}
