import type { Connector, WikiIndexEntry } from "@/runtime/connector";

// M28 (rename-safety / link-rewrite). When a page is renamed, every `[[Old
// Title]]` across the vault would silently break — granite rewrites them. We
// reuse the wiki/index link graph to find the affected pages, then rewrite each
// body's wikilink TARGETS (preserving alias / heading / block-ref / embed) and
// save it back. Pure `rewriteWikilinks` is unit-tested; the orchestrator just
// fans it over the affected pages.

function norm(s: string): string {
  return s.trim().toLowerCase();
}

/**
 * Rewrite every `[[oldTitle…]]` wikilink target in `body` to `newTitle`,
 * preserving a leading `!` embed and any `|alias`, `#heading`, or `^block`
 * suffix. Matching on the TARGET only (case-insensitive, trimmed); the alias is
 * left untouched. Fenced ``` / ~~~ code blocks are skipped so code samples are
 * not mangled. Returns the body unchanged when nothing matches.
 */
export function rewriteWikilinks(body: string, oldTitle: string, newTitle: string): string {
  const old = norm(oldTitle);
  if (!old || norm(newTitle) === old) return body;

  // Split on fenced code blocks so we never rewrite inside one. The capturing
  // group keeps the fences in the array at odd indices (code), evens are prose.
  const parts = body.split(/(```[\s\S]*?```|~~~[\s\S]*?~~~)/g);
  const re = /(!?)\[\[([^\]\n]+?)\]\]/g;
  for (let i = 0; i < parts.length; i += 2) {
    parts[i] = parts[i].replace(re, (whole, bang: string, inner: string) => {
      // Inner = Target(#heading|^block)?(|alias)?. Find where the target ends.
      const cut = inner.search(/[|#^]/);
      const target = (cut === -1 ? inner : inner.slice(0, cut)).trim();
      if (norm(target) !== old) return whole;
      const suffix = cut === -1 ? "" : inner.slice(cut);
      // Preserve any leading whitespace the original target had after `[[`.
      const lead = inner.match(/^\s*/)?.[0] ?? "";
      return `${bang}[[${lead}${newTitle}${suffix}]]`;
    });
  }
  return parts.join("");
}

export interface RewriteResult {
  /** Pages whose bodies were rewritten and saved. */
  rewritten: number;
  /** Pages that matched but failed to load or save. */
  failed: number;
}

/**
 * Rewrite `[[oldTitle]]` → `[[newTitle]]` across every page that links to the
 * renamed page, using the link index to find candidates (so we only touch
 * affected bodies). `excludeId` is the renamed page itself. Best-effort: a page
 * that fails to load/save is counted in `failed` and skipped, never throws.
 */
export async function rewriteBacklinksOnRename(
  connector: Connector,
  entries: ReadonlyArray<WikiIndexEntry>,
  oldTitle: string,
  newTitle: string,
  excludeId: string,
): Promise<RewriteResult> {
  if (!connector.getWikiPage || !connector.saveWikiPage) return { rewritten: 0, failed: 0 };
  const old = norm(oldTitle);
  if (!old || norm(newTitle) === old) return { rewritten: 0, failed: 0 };

  const affected = entries.filter(
    (e) => e.id !== excludeId && e.links.some((t) => norm(t) === old),
  );
  let rewritten = 0;
  let failed = 0;
  for (const e of affected) {
    try {
      const page = await connector.getWikiPage(e.id);
      if (!page) { failed += 1; continue; }
      const next = rewriteWikilinks(page.content, oldTitle, newTitle);
      if (next === page.content) continue; // nothing actually changed
      const res = await connector.saveWikiPage({ id: e.id, title: page.title, body: next });
      if (res) rewritten += 1;
      else failed += 1;
    } catch {
      failed += 1;
    }
  }
  return { rewritten, failed };
}
