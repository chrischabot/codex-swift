import type { WikiPageSummary, WikiIndexEntry } from "@/runtime/connector";

// M27 live `query` blocks — a tiny, bounded query language over the client
// metadata + link indexes (NOT a full dataview port). One directive per line,
// combined with AND:
//
//   title: <substr>          title contains substr (case-insensitive)
//   source: <name>           page source equals name
//   tag: <t>                 frontmatter tags/tag prop contains t, or source == t
//   links-to: <Page>         page's outgoing links include Page (by title)
//   prop.<key>: <value>      frontmatter prop <key> contains value
//   sort: title | recent     ordering (default: title)
//   limit: <n>               cap results (default 50, max 500)
//
// Unknown lines are ignored (forgiving). Returns matched page summaries.

export interface WikiQuery {
  title?: string;
  source?: string;
  tag?: string;
  linksTo?: string;
  props: Array<{ key: string; value: string }>;
  sort: "title" | "recent";
  limit: number;
}

function norm(s: string): string {
  return s.trim().toLowerCase();
}

export function parseWikiQuery(src: string): WikiQuery {
  const q: WikiQuery = { props: [], sort: "title", limit: 50 };
  for (const raw of src.split(/\r?\n/)) {
    const line = raw.trim();
    if (!line || line.startsWith("#")) continue;
    const colon = line.indexOf(":");
    if (colon === -1) continue;
    const key = line.slice(0, colon).trim().toLowerCase();
    const value = line.slice(colon + 1).trim();
    if (!value && key !== "") continue;
    if (key === "title") q.title = value;
    else if (key === "source") q.source = value;
    else if (key === "tag") q.tag = value;
    else if (key === "links-to" || key === "linksto") q.linksTo = value;
    else if (key === "sort") q.sort = norm(value) === "recent" ? "recent" : "title";
    else if (key === "limit") {
      const n = parseInt(value, 10);
      if (Number.isFinite(n) && n > 0) q.limit = Math.min(n, 500);
    } else if (key.startsWith("prop.")) {
      q.props.push({ key: key.slice("prop.".length), value });
    }
  }
  return q;
}

/** Split a frontmatter list-ish value ("a, b, c") into normalized members. */
function members(v: string | undefined): string[] {
  if (!v) return [];
  return v.split(",").map(norm).filter(Boolean);
}

/**
 * Evaluate a parsed query against the page + link indexes. `byId` maps page id →
 * its link-index entry (links + props); pages absent from the link index simply
 * have no links/props. Pure — drive from useMemo in the component.
 */
export function evalWikiQuery(
  q: WikiQuery,
  pages: ReadonlyArray<WikiPageSummary>,
  byId: ReadonlyMap<string, WikiIndexEntry>,
): WikiPageSummary[] {
  const titleNeedle = q.title ? norm(q.title) : null;
  const sourceWant = q.source ? norm(q.source) : null;
  const tagWant = q.tag ? norm(q.tag) : null;
  const linksToWant = q.linksTo ? norm(q.linksTo) : null;

  const out = pages.filter((p) => {
    if (titleNeedle && !norm(p.title).includes(titleNeedle)) return false;
    if (sourceWant && norm(p.source ?? "") !== sourceWant) return false;
    const entry = byId.get(p.id);
    if (tagWant) {
      const tags = [...members(entry?.props.tags), ...members(entry?.props.tag)];
      const inSource = norm(p.source ?? "") === tagWant;
      if (!tags.includes(tagWant) && !inSource) return false;
    }
    if (linksToWant) {
      const links = (entry?.links ?? []).map(norm);
      if (!links.includes(linksToWant)) return false;
    }
    for (const { key, value } of q.props) {
      const pv = entry?.props[key];
      if (pv == null || !norm(pv).includes(norm(value))) return false;
    }
    return true;
  });

  out.sort((a, b) => {
    if (q.sort === "recent") return (b.updatedAt ?? 0) - (a.updatedAt ?? 0);
    return a.title.localeCompare(b.title);
  });
  return out.slice(0, q.limit);
}
