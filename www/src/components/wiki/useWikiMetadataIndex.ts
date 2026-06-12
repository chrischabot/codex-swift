import * as React from "react";
import type { WikiPageSummary } from "@/runtime/connector";
import { createCachedIndex } from "./useCachedIndex";

// M26 (client metadata index). A single shared, cached index of every wiki page
// (id + title + source), loaded once via listWikiPages — an instant, vault-wide
// title→id resolver + full page list for the quick switcher and wikilink
// resolution. Cached at module scope (behind the shared createCachedIndex
// factory); a `version` bump (the page-save/delete dataVersion) forces a refresh.

export interface WikiMetadataIndex {
  /** Every page summary, in listWikiPages order. */
  pages: ReadonlyArray<WikiPageSummary>;
  /** id → summary. */
  byId: ReadonlyMap<string, WikiPageSummary>;
  /** Resolve a wikilink title (case-insensitive, trimmed) → page id. */
  resolve: (title: string) => string | undefined;
  loading: boolean;
}

interface MetaEntry {
  pages: WikiPageSummary[];
  byId: Map<string, WikiPageSummary>;
  byTitle: Map<string, string>;
}

const EMPTY_BY_ID: ReadonlyMap<string, WikiPageSummary> = new Map();

function buildMetaEntry(pages: WikiPageSummary[]): MetaEntry {
  const byId = new Map<string, WikiPageSummary>();
  const byTitle = new Map<string, string>();
  for (const p of pages) {
    byId.set(p.id, p);
    // First title wins on a collision (stable, matches the previous resolver).
    const key = p.title.trim().toLowerCase();
    if (!byTitle.has(key)) byTitle.set(key, p.id);
  }
  return { pages, byId, byTitle };
}

// One module-scoped cached index over `listWikiPages` (no 500 cap — the whole
// vault feeds the switcher + resolver).
const useMetaIndexInternal = createCachedIndex<MetaEntry>({
  fetch: (connector) =>
    connector.listWikiPages
      ? () => connector.listWikiPages!({ limit: 100000 }).then(buildMetaEntry)
      : null,
});

/**
 * Shared, cached page index. `version` (e.g. WikiPage's dataVersion) refreshes
 * the cache when a page is created/renamed/deleted. The fetch is deduped across
 * all concurrent consumers.
 */
export function useWikiMetadataIndex(version = 0): WikiMetadataIndex {
  const { entry, loading } = useMetaIndexInternal(version);
  const resolve = React.useCallback(
    (title: string) => entry?.byTitle.get(title.trim().toLowerCase()),
    [entry],
  );
  return {
    pages: entry?.pages ?? [],
    byId: entry?.byId ?? EMPTY_BY_ID,
    resolve,
    loading,
  };
}
