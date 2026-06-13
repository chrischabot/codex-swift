import * as React from "react";
import { createPersistentStore } from "@/lib/persistentStore";
import { addTab, removeTab, renameTab, type WikiTab } from "./wikiTabs";

// Session-scoped (per-tab) — sessionStorage, so the cross-tab `storage` event
// never fires; same-tab consumers sync via the factory's subscriber set.
const store = createPersistentStore<WikiTab[]>({
  key: "wiki:tabs",
  storage: "session",
  defaultValue: [],
  coerce: (raw) =>
    Array.isArray(raw)
      ? raw
          .filter((x): x is WikiTab => !!x && typeof (x as WikiTab).id === "string" && (x as WikiTab).id.length > 0)
          .map((x) => ({ id: x.id, title: typeof x.title === "string" ? x.title : x.id }))
      : [],
});

const read = (): WikiTab[] => store.get();
const write = (tabs: WikiTab[]): void => store.set(tabs);

/** Update an open tab's cached title in storage + broadcast — callable from
 *  outside React (e.g. the explorer's rename success) so the strip stays fresh
 *  after a page is renamed elsewhere. No-op when the page isn't an open tab. */
export function renameTabInStorage(id: string, title: string): void {
  const tabs = read();
  if (!tabs.some((t) => t.id === id && t.title !== title)) return;
  write(renameTab(tabs, id, title));
}

export interface UseWikiTabs {
  tabs: WikiTab[];
  open: (tab: WikiTab) => void;
  close: (id: string) => void;
  rename: (id: string, title: string) => void;
}

/**
 * Session-scoped open-page tabs. The route stays the source of truth for the
 * ACTIVE page; this maintains the ordered open-set, synced across same-tab
 * consumers (the strip + WikiPage) via a change event. Pure list ops live in
 * ./wikiTabs.
 */
export function useWikiTabs(): UseWikiTabs {
  const tabs = store.useStore();

  const open = React.useCallback((tab: WikiTab) => {
    const prev = read();
    const next = addTab(prev, tab);
    // Only persist when something actually changed (avoid a notify storm when
    // re-opening an already-current tab with the same title).
    if (next.length === prev.length && next.every((t, i) => t.id === prev[i].id && t.title === prev[i].title)) {
      return;
    }
    write(next);
  }, []);

  const close = React.useCallback((id: string) => {
    const prev = read();
    if (!prev.some((t) => t.id === id)) return;
    write(removeTab(prev, id));
  }, []);

  const rename = React.useCallback((id: string, title: string) => {
    const prev = read();
    if (!prev.some((t) => t.id === id && t.title !== title)) return;
    write(renameTab(prev, id, title));
  }, []);

  return { tabs, open, close, rename };
}
