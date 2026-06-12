import type { WikiIndexEntry } from "@/runtime/connector";
import { createCachedIndex } from "./useCachedIndex";

// M26 (vault link + property index). The body-derived companion to
// useWikiMetadataIndex: one shared, module-cached load of `wiki/index` giving
// every page's outgoing `[[wikilinks]]` and parsed frontmatter props. From this
// single shape the client derives:
//   • backlinks      — reverse of `links`, resolved title→id via the metadata index
//   • unlinked-mentions candidates (titles appearing in other bodies; the panel
//     still text-searches to find the actual occurrences, but uses this to know
//     which pages already link)
//   • the property catalog (M30) — aggregate of every page's `props`
//   • rename link-rewrite targets (M28) — pages whose `links` name the old title
//
// Cached at module scope like the metadata index; a `version` bump (the same
// dataVersion the page editor bumps on save/rename/delete) forces a refresh.

interface LinkIndexEntry {
  entries: WikiIndexEntry[];
  byId: Map<string, WikiIndexEntry>;
}

export interface WikiLinkIndex {
  /** Every page that has links and/or props, in backend order. */
  entries: ReadonlyArray<WikiIndexEntry>;
  /** id → entry. */
  byId: ReadonlyMap<string, WikiIndexEntry>;
  loading: boolean;
}

const EMPTY_BY_ID: ReadonlyMap<string, WikiIndexEntry> = new Map();

// One module-scoped cached index over `wiki/index`, behind the shared factory.
const useLinkIndexInternal = createCachedIndex<LinkIndexEntry>({
  fetch: (connector) =>
    connector.getWikiIndex
      ? () =>
          connector.getWikiIndex!().then((entries) => {
            const byId = new Map<string, WikiIndexEntry>();
            for (const e of entries) byId.set(e.id, e);
            return { entries, byId };
          })
      : null,
});

/**
 * Shared, cached link + property index. `version` refreshes the cache when a
 * page is created/renamed/deleted (pass WikiPage's dataVersion). The fetch is
 * deduped across all concurrent consumers.
 */
export function useWikiLinkIndex(version = 0): WikiLinkIndex {
  const { entry, loading } = useLinkIndexInternal(version);
  return {
    entries: entry?.entries ?? [],
    byId: entry?.byId ?? EMPTY_BY_ID,
    loading,
  };
}

/** One backlink: the source page id + title and the alias it used (if any). */
export interface Backlink {
  id: string;
  title: string;
}

/**
 * Compute pages that link TO `targetId`. `resolve(title)→id` comes from the
 * metadata index. A page counts as a backlink when any of its outgoing link
 * targets resolves to `targetId` (self-links excluded). Pure — call inside a
 * useMemo keyed on (entries, targetId).
 */
export function backlinksOf(
  entries: ReadonlyArray<WikiIndexEntry>,
  targetId: string,
  resolve: (title: string) => string | undefined,
): Backlink[] {
  const out: Backlink[] = [];
  for (const e of entries) {
    if (e.id === targetId) continue;
    if (e.links.some((t) => resolve(t) === targetId)) {
      out.push({ id: e.id, title: e.title });
    }
  }
  out.sort((a, b) => a.title.localeCompare(b.title));
  return out;
}

/** Aggregated catalog of one property key across the vault (M30). */
export interface PropertyCatalogKey {
  key: string;
  /** Distinct values → how many pages carry that value. */
  values: Array<{ value: string; count: number }>;
  /** Pages carrying this key at all. */
  pageCount: number;
}

/**
 * Aggregate every page's frontmatter `props` into a per-key catalog: distinct
 * values with page counts, sorted by frequency. Pure — call inside a useMemo
 * keyed on `entries`.
 */
export function propertyCatalog(
  entries: ReadonlyArray<WikiIndexEntry>,
): PropertyCatalogKey[] {
  const keys = new Map<string, { values: Map<string, number>; pages: number }>();
  for (const e of entries) {
    for (const [k, v] of Object.entries(e.props)) {
      let agg = keys.get(k);
      if (!agg) {
        agg = { values: new Map(), pages: 0 };
        keys.set(k, agg);
      }
      agg.pages += 1;
      agg.values.set(v, (agg.values.get(v) ?? 0) + 1);
    }
  }
  return Array.from(keys.entries())
    .map(([key, { values, pages }]) => ({
      key,
      pageCount: pages,
      values: Array.from(values.entries())
        .map(([value, count]) => ({ value, count }))
        .sort((a, b) => b.count - a.count || a.value.localeCompare(b.value)),
    }))
    .sort((a, b) => b.pageCount - a.pageCount || a.key.localeCompare(b.key));
}
