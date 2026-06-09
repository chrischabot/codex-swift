import * as React from "react";

// Bookmarked wiki pages, persisted to localStorage and synced across tabs.
//
// A simplified, www-idiomatic port of granite's BookmarksView storage layer:
// granite tracks file/heading/block/search bookmarks across a vault; here a
// "bookmark" is just a wiki page id (the only navigable unit in this UI) plus
// an optional cached title so the panel can render a label without a round-trip
// to the connector while the page is offline/unfetched.
//
// Storage shape (key "wiki:bookmarks"): a JSON array, newest-first, of
// { id, title?, addedMs }. The array is the source of truth for ordering.

const STORAGE_KEY = "wiki:bookmarks";
// Same-tab sync channel: the `storage` event fires ONLY in OTHER tabs, so a
// writing tab's other useBookmarks instances (e.g. a BookmarkButton + the
// panel) would never update. We dispatch this on every write and all instances
// re-read on it.
const CHANGE_EVENT = "wiki:bookmarks:changed";

export interface Bookmark {
  readonly id: string;
  /** Cached page title at bookmark time; the panel falls back to this when the
   *  live page payload isn't loaded. */
  readonly title?: string;
  /** Epoch ms the bookmark was added — drives newest-first ordering. */
  readonly addedMs: number;
}

function read(): Bookmark[] {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((b): b is Bookmark => {
        return (
          typeof b === "object" &&
          b !== null &&
          typeof (b as { id?: unknown }).id === "string" &&
          (b as { id: string }).id.length > 0
        );
      })
      .map((b) => ({
        id: b.id,
        title: typeof b.title === "string" ? b.title : undefined,
        addedMs: typeof b.addedMs === "number" ? b.addedMs : Date.now(),
      }));
  } catch {
    return [];
  }
}

function write(list: Bookmark[]): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(list));
  } catch {
    /* quota / private mode — non-fatal, state stays in memory */
  }
  // Notify same-tab instances (storage event won't reach them).
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(CHANGE_EVENT));
}

export interface UseBookmarks {
  /** Newest-first list of bookmarks. */
  list: Bookmark[];
  isBookmarked: (id: string) => boolean;
  /** Add (or, if already present, refresh the cached title). No-op on empty id. */
  add: (id: string, title?: string) => void;
  remove: (id: string) => void;
  /** Add when absent, remove when present. Returns the resulting state. */
  toggle: (id: string, title?: string) => boolean;
}

export function useBookmarks(): UseBookmarks {
  const [list, setList] = React.useState<Bookmark[]>(() =>
    typeof window === "undefined" ? [] : read(),
  );

  // Keep localStorage and any other open tabs in sync. We deliberately do NOT
  // write here on every render — `add`/`remove`/`toggle` persist explicitly and
  // update state from the same next-list, so the writer tab never re-reads its
  // own event.
  React.useEffect(() => {
    const onStorage = (e: StorageEvent) => {
      if (e.key !== null && e.key !== STORAGE_KEY) return;
      setList(read());
    };
    const onLocalChange = () => setList(read());
    window.addEventListener("storage", onStorage);          // cross-tab
    window.addEventListener(CHANGE_EVENT, onLocalChange);   // same-tab
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(CHANGE_EVENT, onLocalChange);
    };
  }, []);

  const add = React.useCallback(
    (id: string, title?: string) => {
      if (!id) return;
      setList((prev) => {
        const existing = prev.find((b) => b.id === id);
        // Already present: only re-commit if the cached title actually changes.
        if (existing) {
          if (title === undefined || existing.title === title) return prev;
          const next = prev.map((b) => (b.id === id ? { ...b, title } : b));
          write(next);
          return next;
        }
        const next: Bookmark[] = [{ id, title, addedMs: Date.now() }, ...prev];
        write(next);
        return next;
      });
    },
    [],
  );

  const remove = React.useCallback((id: string) => {
    if (!id) return;
    setList((prev) => {
      if (!prev.some((b) => b.id === id)) return prev;
      const next = prev.filter((b) => b.id !== id);
      write(next);
      return next;
    });
  }, []);

  const isBookmarked = React.useCallback(
    (id: string) => list.some((b) => b.id === id),
    [list],
  );

  const toggle = React.useCallback(
    (id: string, title?: string): boolean => {
      if (!id) return false;
      let result = false;
      setList((prev) => {
        if (prev.some((b) => b.id === id)) {
          const next = prev.filter((b) => b.id !== id);
          write(next);
          result = false;
          return next;
        }
        const next: Bookmark[] = [{ id, title, addedMs: Date.now() }, ...prev];
        write(next);
        result = true;
        return next;
      });
      return result;
    },
    [],
  );

  return { list, isBookmarked, add, remove, toggle };
}
