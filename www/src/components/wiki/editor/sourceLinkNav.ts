// Cmd/Ctrl-click navigation for links in the SOURCE editor.
//
// The reading view routes wikilink anchors through `onWikiLink` +
// `resolveWikilinkNav`; the source editor has no rendered anchors, so this
// extension detects a modifier-click landing inside a `[[wikilink]]` or a
// `[markdown](url)` token at the click offset and dispatches the SAME
// navigation the reading view would. We reuse `resolveWikilinkNav` verbatim so
// resolution (page id, #heading / #^block fragment, dangling → search) stays
// identical across surfaces.
//
// Modifier semantics mirror the rest of the app: plain Cmd/Ctrl-click follows
// the link in place; adding Shift opens it in a new tab. Alt is deliberately
// NOT consumed here — it's the multi-cursor add-range gesture (see extensions
// .ts `editorClickAddsSelectionRange`), so an Alt-click must fall through.

import { EditorView } from "@codemirror/view";
import type { Extension } from "@codemirror/state";
import { resolveWikilinkNav } from "@/components/wiki/markdown/wikiRemarkPlugins";

/** A link found at a document offset: its target + the kind of token. */
interface LinkHit {
  /** Full wikilink target (incl. `#heading` / `#^block`) or the markdown URL. */
  readonly target: string;
  /** wiki = `[[…]]`, markdown = `[text](url)`. */
  readonly kind: "wiki" | "markdown";
}

const WIKILINK_RE = /(!?)\[\[([^\]\n]+)\]\]/g;
// `[label](url)` — url stops at the first space or close paren (no nested
// parens / title support; matches the reading-view link surface closely enough
// for click-through).
const MD_LINK_RE = /\[[^\]\n]*\]\(([^)\s]+)\)/g;

/**
 * Find a `[[wikilink]]` or `[md](url)` token whose span contains `pos`. A
 * wikilink wins over a markdown link when both somehow overlap (the wiki regex
 * is checked first). Pure + exported for unit tests.
 */
export function linkAtPosition(line: string, offsetInLine: number): LinkHit | null {
  WIKILINK_RE.lastIndex = 0;
  for (let m = WIKILINK_RE.exec(line); m; m = WIKILINK_RE.exec(line)) {
    const start = m.index;
    const end = start + m[0].length;
    if (offsetInLine >= start && offsetInLine <= end) {
      // Strip a leading `|display`? No — resolveWikilinkNav parses the pipe.
      return { target: m[2] ?? "", kind: "wiki" };
    }
  }
  MD_LINK_RE.lastIndex = 0;
  for (let m = MD_LINK_RE.exec(line); m; m = MD_LINK_RE.exec(line)) {
    const start = m.index;
    const end = start + m[0].length;
    if (offsetInLine >= start && offsetInLine <= end) {
      return { target: m[1] ?? "", kind: "markdown" };
    }
  }
  return null;
}

/** Does the click want link navigation (Cmd on macOS / Ctrl elsewhere), and
 *  NOT the Alt multi-cursor gesture? Shift may accompany it (= new tab). */
function isNavClick(event: MouseEvent): boolean {
  if (event.altKey) return false;
  const platform = globalThis.navigator?.platform ?? "";
  const isMac = /Mac|iPhone|iPad|iPod/.test(platform);
  return isMac ? event.metaKey : event.ctrlKey;
}

export interface SourceLinkNavOptions {
  /** Maps a (suffix-stripped) wikilink title to a page id (for `[[…]]`). */
  resolveWikiLink?: (title: string) => string | undefined;
  /** Navigate to an in-app path (reuses the host's router push). */
  onNavigate?: (path: string, opts: { newTab: boolean }) => void;
}

/**
 * Build the Cmd/Ctrl-click link-navigation extension. No-op (returns []) when
 * the host wires no `onNavigate` — there's nowhere to route, so we leave the
 * click to the editor's normal selection handling.
 */
export function sourceLinkNav(opts: SourceLinkNavOptions): Extension {
  const { resolveWikiLink, onNavigate } = opts;
  if (!onNavigate) return [];
  return EditorView.domEventHandlers({
    mousedown(event, view) {
      if (!isNavClick(event)) return false;
      const pos = view.posAtCoords({ x: event.clientX, y: event.clientY });
      if (pos == null) return false;
      const line = view.state.doc.lineAt(pos);
      const hit = linkAtPosition(line.text, pos - line.from);
      if (!hit) return false;
      const newTab = event.shiftKey;
      if (hit.kind === "wiki") {
        const path = resolveWikilinkNav(hit.target, resolveWikiLink ?? (() => undefined));
        onNavigate(path, { newTab });
      } else {
        // A bare markdown URL: in-app paths (/, #) route through onNavigate;
        // external URLs open in a new tab so we never blow away the editor.
        const isExternal = /^[a-z][\w+.-]*:/i.test(hit.target) && !hit.target.startsWith("wiki:");
        if (isExternal) {
          window.open(hit.target, "_blank", "noopener,noreferrer");
        } else {
          onNavigate(hit.target, { newTab });
        }
      }
      // Swallow the click so it doesn't also place / add a cursor.
      event.preventDefault();
      return true;
    },
  });
}
