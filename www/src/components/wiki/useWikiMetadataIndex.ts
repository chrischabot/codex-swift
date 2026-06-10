import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPageSummary } from "@/runtime/connector";

// M26 (client metadata index — part 1). A single shared, cached index of every
// wiki page (id + title + source), loaded once via listWikiPages instead of
// each consumer building its own idByTitle map and the switcher capping at 500.
//
// This is the foundation granite's metadata cache provides: an instant,
// vault-wide title→id resolver and a full page list for the quick switcher and
// wikilink resolution. (Backlinks / unlinked-mentions / property-catalog need
// page BODIES — a backend link-index RPC — and are intentionally out of scope
// here; this part covers everything derivable from page summaries.)
//
// Cached at module scope so the first mount pays the fetch and every later
// consumer (switcher, hover, reading view, editor nav) reuses it; a `version`
// bump (passed from the page-save/delete dataVersion) forces a refresh.

export interface WikiMetadataIndex {
  /** Every page summary, in listWikiPages order. */
  pages: ReadonlyArray<WikiPageSummary>;
  /** id → summary. */
  byId: ReadonlyMap<string, WikiPageSummary>;
  /** Resolve a wikilink title (case-insensitive, trimmed) → page id. */
  resolve: (title: string) => string | undefined;
  loading: boolean;
}

interface CacheEntry {
  version: number;
  pages: WikiPageSummary[];
  byId: Map<string, WikiPageSummary>;
  byTitle: Map<string, string>;
}

let cache: CacheEntry | null = null;
const subscribers = new Set<() => void>();
let inflight: Promise<void> | null = null;

function buildEntry(version: number, pages: WikiPageSummary[]): CacheEntry {
  const byId = new Map<string, WikiPageSummary>();
  const byTitle = new Map<string, string>();
  for (const p of pages) {
    byId.set(p.id, p);
    // First title wins on a collision (stable, matches the previous per-page
    // resolver which took the first list entry).
    const key = p.title.trim().toLowerCase();
    if (!byTitle.has(key)) byTitle.set(key, p.id);
  }
  return { version, pages, byId, byTitle };
}

function emit() {
  for (const s of subscribers) s();
}

/**
 * Shared, cached page index. `version` (e.g. WikiPage's dataVersion) refreshes
 * the cache when a page is created/renamed/deleted. The fetch is deduped across
 * all concurrent consumers via `inflight`.
 */
export function useWikiMetadataIndex(version = 0): WikiMetadataIndex {
  const { connector, status } = useRuntime();
  const [, forceRender] = React.useReducer((n: number) => n + 1, 0);
  const [loading, setLoading] = React.useState(() => cache?.version !== version);

  React.useEffect(() => {
    const onChange = () => forceRender();
    subscribers.add(onChange);
    return () => {
      subscribers.delete(onChange);
    };
  }, []);

  React.useEffect(() => {
    if (status.kind !== "connected" || !connector.listWikiPages) {
      setLoading(false);
      return;
    }
    if (cache && cache.version === version) {
      setLoading(false);
      return;
    }
    let alive = true;
    setLoading(true);
    // Dedupe concurrent loads for the same version.
    const load = async () => {
      try {
        // No 500 cap — the whole vault feeds the switcher + resolver.
        const pages = (await connector.listWikiPages?.({ limit: 100000 })) ?? [];
        cache = buildEntry(version, pages);
        emit();
      } catch {
        if (!cache) cache = buildEntry(version, []);
      }
    };
    if (!inflight || cache?.version !== version) {
      inflight = load().finally(() => {
        inflight = null;
      });
    }
    inflight.then(() => {
      if (alive) setLoading(false);
    });
    return () => {
      alive = false;
    };
  }, [connector, status.kind, version]);

  const entry = cache && cache.version === version ? cache : cache;
  const resolve = React.useCallback(
    (title: string) => entry?.byTitle.get(title.trim().toLowerCase()),
    [entry],
  );

  return {
    pages: entry?.pages ?? [],
    byId: entry?.byId ?? new Map(),
    resolve,
    loading,
  };
}
