// Pure tab-set operations for the wiki page-tab strip. The route (/wiki/:pageId)
// stays the single source of truth for the ACTIVE page; this just maintains the
// ordered open-set so switching/closing tabs is predictable. Kept pure so the
// open/close/adjacent logic is unit-tested without the router/storage.

export interface WikiTab {
  readonly id: string;
  readonly title: string;
}

/** Append a tab if its id isn't already open (refreshing the cached title);
 *  preserves order (most-recently-opened stays where it first appeared). */
export function addTab(tabs: ReadonlyArray<WikiTab>, tab: WikiTab): WikiTab[] {
  const existing = tabs.find((t) => t.id === tab.id);
  if (existing) {
    return existing.title === tab.title ? [...tabs] : tabs.map((t) => (t.id === tab.id ? tab : t));
  }
  return [...tabs, tab];
}

/** Remove a tab by id. */
export function removeTab(tabs: ReadonlyArray<WikiTab>, id: string): WikiTab[] {
  return tabs.filter((t) => t.id !== id);
}

/**
 * The id to navigate to after closing `closingId` while it's active: the tab to
 * the RIGHT (matching Obsidian), else the one to the LEFT, else null (no tabs
 * left → caller routes to the index). Returns undefined when `closingId` isn't
 * the active tab (closing a background tab shouldn't change navigation).
 */
export function activeAfterClose(
  tabs: ReadonlyArray<WikiTab>,
  closingId: string,
  activeId: string | undefined,
): string | null | undefined {
  if (closingId !== activeId) return undefined;
  const idx = tabs.findIndex((t) => t.id === closingId);
  if (idx === -1) return undefined; // active id isn't a tab → don't bounce nav
  const next = tabs[idx + 1] ?? tabs[idx - 1];
  return next ? next.id : null;
}

/** Rename a tab's cached title in place (e.g. after a rename). */
export function renameTab(tabs: ReadonlyArray<WikiTab>, id: string, title: string): WikiTab[] {
  return tabs.map((t) => (t.id === id ? { ...t, title } : t));
}
