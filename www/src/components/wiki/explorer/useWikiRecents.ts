import * as React from "react";

// Recently-opened wiki pages, persisted to localStorage and synced across tabs.
//
// granite ref: src/core/workspace/recents — granite keeps a recency-ordered MRU
// of opened files in a workspace store. The state/wiki.ts `useWikiRecents` hook
// is a DIFFERENT thing (it lists the N most-recently-UPDATED pages from the
// store, regardless of whether the user ever opened them). This module is the
// true MRU of pages the user actually opened in THIS browser — the granite
// "Recents" pane semantics — so it lives client-side next to the explorer.
//
// Storage shape (key "wiki:recents"): a JSON array, newest-first, of
// { id, title?, openedMs }, capped to MAX_RECENTS entries.

const STORAGE_KEY = "wiki:recents";
// Same-tab sync channel — the `storage` event only fires in OTHER tabs, so a
// writing tab's other useWikiRecents instances would never update. We dispatch
// this on every write and all instances re-read on it.
const CHANGE_EVENT = "wiki:recents:changed";
const MAX_RECENTS = 30;

export interface RecentPage {
  readonly id: string;
  /** Cached page title at open time; the panel falls back to this when the live
   *  page list isn't available. */
  readonly title?: string;
  /** Epoch ms the page was last opened — drives newest-first ordering. */
  readonly openedMs: number;
}

function read(): RecentPage[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((r): r is RecentPage => {
        return (
          typeof r === "object" &&
          r !== null &&
          typeof (r as { id?: unknown }).id === "string" &&
          (r as { id: string }).id.length > 0
        );
      })
      .map((r) => ({
        id: r.id,
        title: typeof r.title === "string" ? r.title : undefined,
        openedMs: typeof r.openedMs === "number" ? r.openedMs : Date.now(),
      }));
  } catch {
    return [];
  }
}

function write(list: RecentPage[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(list));
  } catch {
    /* quota / private mode — non-fatal, state stays in memory */
  }
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(CHANGE_EVENT));
}

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
  const [list, setList] = React.useState<RecentPage[]>(() =>
    typeof window === "undefined" ? [] : read(),
  );

  React.useEffect(() => {
    const onStorage = (e: StorageEvent) => {
      if (e.key !== null && e.key !== STORAGE_KEY) return;
      setList(read());
    };
    const onLocalChange = () => setList(read());
    window.addEventListener("storage", onStorage); // cross-tab
    window.addEventListener(CHANGE_EVENT, onLocalChange); // same-tab
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(CHANGE_EVENT, onLocalChange);
    };
  }, []);

  const remove = React.useCallback((id: string) => {
    if (!id) return;
    setList((prev) => {
      if (!prev.some((r) => r.id === id)) return prev;
      const next = prev.filter((r) => r.id !== id);
      write(next);
      return next;
    });
  }, []);

  const clear = React.useCallback(() => {
    setList((prev) => {
      if (prev.length === 0) return prev;
      write([]);
      return [];
    });
  }, []);

  return { list, remove, clear };
}
