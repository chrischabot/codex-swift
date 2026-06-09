// Pop-out window helpers (granite parity, M23d). A popped-out wiki page opens
// in its own chrome-less browser window (`?popout=1`): no sidebar, no multi-
// pane workspace, no cross-window sync — just the page. The main window keeps
// its layout untouched.

/** True when the current window is a chrome-less pop-out. */
export function isPopoutWindow(): boolean {
  if (typeof window === "undefined") return false;
  return new URLSearchParams(window.location.search).get("popout") === "1";
}

/** Open `pageId` in a new chrome-less window. */
export function popOutPage(pageId: string): void {
  if (typeof window === "undefined") return;
  const url = `${window.location.origin}/wiki/${encodeURIComponent(pageId)}?popout=1`;
  window.open(url, `wiki-popout-${pageId}`, "width=900,height=720,popup");
}
