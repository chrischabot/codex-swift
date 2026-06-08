import type { ReactNode } from "react";

/** Cap the haystack we scan so a pathological excerpt can't lock the main
 *  thread. Wiki excerpts are short (one or two lines), so this is generous. */
const MAX_EXCERPT_LEN = 2000;

/** Escape regex metacharacters so user-typed terms match literally. */
function escapeRegex(term: string): string {
  return term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/**
 * Wrap each occurrence of any `terms` token inside `text` in a `<mark>`.
 * Matching is case-insensitive. Returns a ReactNode[] suitable for inlining
 * (each segment keyed). Non-matching segments are returned as plain strings.
 *
 * - Regex metachars in terms are escaped (literal match).
 * - Empty / whitespace-only terms are dropped.
 * - Work is capped at MAX_EXCERPT_LEN characters; the tail (if any) is appended
 *   verbatim so very long excerpts never block the render.
 */
export function highlightMatch(text: string, terms: string[]): ReactNode[] {
  if (!text) return [];
  const tokens = Array.from(
    new Set(terms.map((t) => t.trim()).filter((t) => t.length > 0)),
  );
  if (tokens.length === 0) return [text];

  // Scan a bounded prefix; preserve the remainder unhighlighted.
  const head = text.length > MAX_EXCERPT_LEN ? text.slice(0, MAX_EXCERPT_LEN) : text;
  const tail = text.length > MAX_EXCERPT_LEN ? text.slice(MAX_EXCERPT_LEN) : "";

  // Longest tokens first so "title" wins over "tit" at the same offset.
  const pattern = tokens
    .sort((a, b) => b.length - a.length)
    .map(escapeRegex)
    .join("|");
  const re = new RegExp(`(${pattern})`, "gi");

  const out: ReactNode[] = [];
  let last = 0;
  let m: RegExpExecArray | null;
  let key = 0;
  // biome-ignore lint/suspicious/noAssignInExpressions: standard regex exec loop.
  while ((m = re.exec(head)) !== null) {
    const start = m.index;
    const end = start + m[0].length;
    if (start > last) out.push(head.slice(last, start));
    out.push(<mark key={`hl-${key++}`} className="rounded-sm bg-[color:var(--text-highlight-bg,#fde68a)] px-0.5 text-inherit">{m[0]}</mark>);
    last = end;
    // Zero-width safety (shouldn't happen since empty tokens are dropped).
    if (m.index === re.lastIndex) re.lastIndex++;
  }
  if (last < head.length) out.push(head.slice(last));
  if (tail) out.push(tail);
  return out;
}
