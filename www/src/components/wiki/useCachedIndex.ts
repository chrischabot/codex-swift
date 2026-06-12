import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { Connector } from "@/runtime/connector";

// Shared machinery for the vault-wide, module-cached client indexes
// (useWikiLinkIndex, useWikiMetadataIndex). Both previously duplicated the same
// cache / inflight-dedup / subscriber / version-keyed-effect pattern (~120 lines
// each), including an identical no-op `cond ? cache : cache` ternary. This
// factory is the single, intentional place that policy lives.

export interface CachedIndexResult<TEntry> {
  /** The cached entry, or null before the first load completes. */
  entry: TEntry | null;
  loading: boolean;
  /** Drop the cache and notify subscribers (forces a refetch on next mount). */
  refresh: () => void;
}

/**
 * Build a module-cached index hook. `fetch(connector)` returns a THUNK that
 * loads the entry — or null when the connector lacks the capability (→ empty,
 * not loading). It must NOT start the request itself: the thunk is invoked only
 * when an actual load is needed, so a cache hit / disconnected state never fires
 * an RPC. Each `createCachedIndex` call owns its OWN module-scoped cache.
 * `version` (e.g. dataVersion) invalidates the cache on a bump.
 */
export function createCachedIndex<TEntry>(opts: {
  fetch: (connector: Connector) => (() => Promise<TEntry>) | null;
}): (version?: number) => CachedIndexResult<TEntry> {
  let cache: { version: number; entry: TEntry } | null = null;
  const subscribers = new Set<() => void>();
  let inflight: Promise<void> | null = null;
  const emit = () => {
    for (const s of subscribers) s();
  };

  return function useCachedIndex(version = 0): CachedIndexResult<TEntry> {
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
      const fetcher = opts.fetch(connector); // capability check only — no RPC fired
      if (status.kind !== "connected" || !fetcher) {
        setLoading(false);
        return;
      }
      if (cache && cache.version === version) {
        setLoading(false);
        return;
      }
      let alive = true;
      setLoading(true);
      const load = async () => {
        try {
          const entry = await fetcher(); // the thunk fires the request here
          cache = { version, entry };
          emit();
        } catch {
          /* keep any stale cache; surface as not-loading below */
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
      // `opts.fetch` is a stable module-level closure; intentionally excluded.
      // eslint-disable-next-line react-hooks/exhaustive-deps
    }, [connector, status.kind, version]);

    // Single, explicit cross-version policy (replaces the old no-op ternary):
    // return whatever cache exists even if its version differs — the effect is
    // already refetching to `version`, and returning stale-during-reload avoids
    // a flash of empty plus refetch thrash between consumers on different versions.
    return { entry: cache?.entry ?? null, loading, refresh: () => { cache = null; emit(); } };
  };
}
