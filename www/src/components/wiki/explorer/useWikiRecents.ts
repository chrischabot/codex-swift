import * as React from "react";
import { createPersistentStore } from "@/lib/persistentStore";

// Recently-opened wiki pages, persisted to localStorage and synced across tabs.
//
// granite ref: src/core/workspace/recents — a recency-ordered MRU of opened
// files. The state/wiki.ts `useWikiRecents` hook is a DIFFERENT thing (most
// recently UPDATED pages); this module is the true MRU of pages the user
// actually opened in THIS browser — the granite "Recents" pane semantics.
//
// Storage shape (key "wiki:recents"): a JSON array, newest-first, of
// { id, title?, openedMs }, capped to MAX_RECENTS entries. Backed by the shared
// persistentStore (cross-tab + same-tab sync).

const MAX_RECENTS = 30;

export interface RecentPage {
  readonly id: string;
  /** Cached page title at open time; the panel falls back to this when the live
   *  page list isn't available. */
  readonly title?: string;
  /** Epoch ms the page was last opened — drives newest-first ordering. */
  readonly openedMs: number;
}

const store = createPersistentStore<RecentPage[]>({
  key: "wiki:recents",
  defaultValue: [],
  coerce: (raw) => {
    if (!Array.isArray(raw)) return [];
    return raw
      .filter(
        (r): r is RecentPage =>
          typeof r === "object" &&
          r !== null &&
          typeof (r as { id?: unknown }).id === "string" &&
          (r as { id: string }).id.length > 0,
      )
      .map((r) => ({
        id: r.id,
        title: typeof r.title === "string" ? r.title : undefined,
        openedMs: typeof r.openedMs === "number" ? r.openedMs : Date.now(),
      }));
  },
});

const read = (): RecentPage[] => store.get();
const write = (list: RecentPage[]): void => store.set(list);

/** Compute the next MRU after opening `id`: dedupe to a single newest entry,
 *  refresh the cached title, and cap the list. Exported for unit testing. */
export function pushRecent(
  list: readonly RecentPage[],
  id: string,
  title: string | undefined,
  now: number,
): RecentPage[] {
  if (!id) return [...list];
  const rest = list.filter((r) => r.id !== id);
  const entry: RecentPage = { id, title: title?.trim() || undefined, openedMs: now };
  return [entry, ...rest].slice(0, MAX_RECENTS);
}

/** Record that a page was opened. Safe to call from anywhere (no hook needed) —
 *  the explorer calls this on row open and any open hook instance re-reads via
 *  the change event. */
export function recordWikiRecent(id: string, title?: string): void {
  if (!id || typeof window === "undefined") return;
  write(pushRecent(read(), id, title, Date.now()));
}

export interface UseWikiRecents {
  /** Newest-first list of opened pages. */
  list: RecentPage[];
  remove: (id: string) => void;
  clear: () => void;
}

/** Subscribe to the recently-opened MRU. */
export function useWikiRecents(): UseWikiRecents {
  const list = store.useStore();

  const remove = React.useCallback((id: string) => {
    if (!id) return;
    const cur = read();
    if (!cur.some((r) => r.id === id)) return;
    write(cur.filter((r) => r.id !== id));
  }, []);

  const clear = React.useCallback(() => {
    if (read().length === 0) return;
    write([]);
  }, []);

  return { list, remove, clear };
}
