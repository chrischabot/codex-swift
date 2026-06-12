import * as React from "react";

// One reactive browser-storage-backed store, replacing the per-feature
// hand-rolled copies (hotkey overrides, recents, settings, tabs each had their
// own read/write/JSON/cross-tab/same-tab-event boilerplate). Cross-tab sync uses
// the native `storage` event (local storage only — session storage is per-tab by
// design); same-tab sync uses a module subscriber set (no window CustomEvent).

export interface PersistentStore<T> {
  /** Current value (lazily read + cached). */
  get(): T;
  /** Write through to storage + notify subscribers. */
  set(next: T): void;
  /** Subscribe to changes (same-tab writes + cross-tab storage events). */
  subscribe(cb: () => void): () => void;
  /** React hook returning the live value (via useSyncExternalStore). */
  useStore(): T;
}

export interface PersistentStoreOptions<T> {
  key: string;
  defaultValue: T;
  /** Storage backend. `session` is per-tab (no cross-tab sync). Default `local`. */
  storage?: "local" | "session";
  /** Validate/normalize parsed JSON into T (defaults to identity-cast). */
  coerce?: (raw: unknown) => T;
  /** Serialize T → string (default JSON.stringify). */
  serialize?: (v: T) => string;
}

export function createPersistentStore<T>(opts: PersistentStoreOptions<T>): PersistentStore<T> {
  const { key, defaultValue, storage = "local", coerce, serialize = JSON.stringify } = opts;
  const backend = (): Storage | null => {
    if (typeof window === "undefined") return null;
    return storage === "session" ? window.sessionStorage : window.localStorage;
  };

  let cache: T | undefined;
  const subscribers = new Set<() => void>();

  const read = (): T => {
    if (cache !== undefined) return cache;
    const store = backend();
    if (!store) return (cache = defaultValue);
    try {
      const raw = store.getItem(key);
      if (raw == null) return (cache = defaultValue);
      const parsed = JSON.parse(raw) as unknown;
      cache = coerce ? coerce(parsed) : (parsed as T);
    } catch {
      cache = defaultValue;
    }
    return cache;
  };

  const emit = () => {
    for (const cb of subscribers) cb();
  };

  const set = (next: T): void => {
    cache = next;
    const store = backend();
    try {
      store?.setItem(key, serialize(next));
    } catch {
      /* quota / private mode — value stays in memory */
    }
    emit();
  };

  // Cross-tab: the storage event fires only in OTHER tabs (local storage only).
  if (typeof window !== "undefined" && storage === "local") {
    window.addEventListener("storage", (e) => {
      if (e.key !== null && e.key !== key) return;
      cache = undefined; // force re-read on next get
      emit();
    });
  }

  const useStore = (): T =>
    React.useSyncExternalStore(
      React.useCallback((cb) => {
        subscribers.add(cb);
        return () => subscribers.delete(cb);
      }, []),
      read,
      read,
    );

  return { get: read, set, subscribe: (cb) => { subscribers.add(cb); return () => subscribers.delete(cb); }, useStore };
}
