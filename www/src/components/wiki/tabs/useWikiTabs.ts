import * as React from "react";
import { addTab, removeTab, renameTab, type WikiTab } from "./wikiTabs";

const STORAGE_KEY = "wiki:tabs";
const CHANGE_EVENT = "wiki:tabs:changed";

function read(): WikiTab[] {
  try {
    const raw = sessionStorage.getItem(STORAGE_KEY);
    if (!raw) return [];
    const parsed = JSON.parse(raw) as unknown;
    if (!Array.isArray(parsed)) return [];
    return parsed
      .filter((x): x is WikiTab => !!x && typeof (x as WikiTab).id === "string" && (x as WikiTab).id.length > 0)
      .map((x) => ({ id: x.id, title: typeof x.title === "string" ? x.title : x.id }));
  } catch {
    return [];
  }
}

function write(tabs: WikiTab[]): void {
  try {
    sessionStorage.setItem(STORAGE_KEY, JSON.stringify(tabs));
  } catch {
    /* private mode — non-fatal */
  }
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(CHANGE_EVENT));
}

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
  const [tabs, setTabs] = React.useState<WikiTab[]>(() => (typeof window === "undefined" ? [] : read()));

  React.useEffect(() => {
    // sessionStorage is per-tab, so the cross-tab `storage` event never fires for
    // it — same-tab consumers sync via our own CHANGE_EVENT.
    const onChange = () => setTabs(read());
    window.addEventListener(CHANGE_EVENT, onChange);
    return () => window.removeEventListener(CHANGE_EVENT, onChange);
  }, []);

  const open = React.useCallback((tab: WikiTab) => {
    setTabs((prev) => {
      const next = addTab(prev, tab);
      // Only persist when something actually changed (avoid an event storm when
      // re-opening an already-current tab with the same title).
      if (next.length === prev.length && next.every((t, i) => t.id === prev[i].id && t.title === prev[i].title)) {
        return prev;
      }
      write(next);
      return next;
    });
  }, []);

  const close = React.useCallback((id: string) => {
    setTabs((prev) => {
      if (!prev.some((t) => t.id === id)) return prev;
      const next = removeTab(prev, id);
      write(next);
      return next;
    });
  }, []);

  const rename = React.useCallback((id: string, title: string) => {
    setTabs((prev) => {
      if (!prev.some((t) => t.id === id && t.title !== title)) return prev;
      const next = renameTab(prev, id, title);
      write(next);
      return next;
    });
  }, []);

  return { tabs, open, close, rename };
}
