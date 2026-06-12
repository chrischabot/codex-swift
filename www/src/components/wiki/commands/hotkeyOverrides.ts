import { createPersistentStore } from "@/lib/persistentStore";

// M29+ user hotkey rebinding. A localStorage-backed map of commandId → custom
// accelerator hint that LAYERS over the registry's built-in `hotkey`. Backed by
// the shared persistentStore (key "wiki:hotkeys"); cross-tab synced.

type Overrides = Record<string, string>;

const store = createPersistentStore<Overrides>({
  key: "wiki:hotkeys",
  defaultValue: {},
  coerce: (raw) => {
    if (!raw || typeof raw !== "object" || Array.isArray(raw)) return {};
    const out: Overrides = {};
    for (const [k, v] of Object.entries(raw as Record<string, unknown>)) {
      if (typeof v === "string" && v) out[k] = v;
    }
    return out;
  },
});

/** Get all overrides (referentially stable until a write). */
export function getHotkeyOverrides(): Overrides {
  return store.get();
}

/** Set (empty value clears) the override for a command, then notify. */
export function setHotkeyOverride(commandId: string, accel: string): void {
  const next = { ...store.get() };
  if (accel.trim()) next[commandId] = accel.trim();
  else delete next[commandId];
  store.set(next);
}

/** Clear every custom binding. */
export function resetHotkeyOverrides(): void {
  store.set({});
}

/** Subscribe to override changes (for useSyncExternalStore consumers). */
export function useHotkeyOverrides(): Overrides {
  return store.useStore();
}
