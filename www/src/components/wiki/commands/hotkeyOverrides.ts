import * as React from "react";

// M29+ user hotkey rebinding. A localStorage-backed map of commandId → custom
// accelerator hint that LAYERS over the registry's built-in `hotkey`. The
// dispatcher (useWikiCommands) reads the effective binding; the shortcuts dialog
// captures + edits them. Cross-tab sync via the storage event + a same-tab
// notifier, mirroring useWikiSettings.

const STORAGE_KEY = "wiki:hotkeys";
type Overrides = Record<string, string>;

let cache: Overrides | null = null;
const listeners = new Set<() => void>();

function read(): Overrides {
  if (cache) return cache;
  if (typeof window === "undefined") {
    cache = {};
    return cache;
  }
  let next: Overrides = {};
  try {
    const raw = window.localStorage.getItem(STORAGE_KEY);
    const parsed = raw ? JSON.parse(raw) : {};
    if (parsed && typeof parsed === "object" && !Array.isArray(parsed)) {
      for (const [k, v] of Object.entries(parsed as Record<string, unknown>)) {
        if (typeof v === "string" && v) next[k] = v;
      }
    }
  } catch {
    next = {};
  }
  cache = next;
  return next;
}

function write(next: Overrides) {
  cache = next;
  try {
    window.localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    /* ignore quota / disabled storage */
  }
  for (const l of listeners) l();
}

/** Get all overrides (referentially stable until a write). */
export function getHotkeyOverrides(): Overrides {
  return read();
}

/** Set (empty value clears) the override for a command, then notify. */
export function setHotkeyOverride(commandId: string, accel: string): void {
  const cur = read();
  const next = { ...cur };
  if (accel.trim()) next[commandId] = accel.trim();
  else delete next[commandId];
  write(next);
}

/** Clear every custom binding. */
export function resetHotkeyOverrides(): void {
  write({});
}

if (typeof window !== "undefined") {
  window.addEventListener("storage", (e) => {
    if (e.key === STORAGE_KEY) {
      cache = null;
      for (const l of listeners) l();
    }
  });
}

/** Subscribe to override changes (for useSyncExternalStore). */
export function useHotkeyOverrides(): Overrides {
  return React.useSyncExternalStore(
    React.useCallback((cb) => {
      listeners.add(cb);
      return () => listeners.delete(cb);
    }, []),
    read,
    read,
  );
}
