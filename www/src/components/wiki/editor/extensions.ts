import { closeBrackets } from "@codemirror/autocomplete";
import { codeFolding, foldGutter, foldKeymap, indentOnInput } from "@codemirror/language";
import { search, searchKeymap } from "@codemirror/search";
import { Compartment, EditorState, type Extension } from "@codemirror/state";
import {
  EditorView,
  crosshairCursor,
  drawSelection,
  keymap,
  rectangularSelection,
} from "@codemirror/view";
import { vim } from "@replit/codemirror-vim";
import { sourceLinkNav, type SourceLinkNavOptions } from "./sourceLinkNav";

/**
 * Curated CodeMirror 6 productivity bundle for the wiki editor, ported from
 * granite's MarkdownView. Each capability is composable so the host can opt
 * in/out per editor instance, and the two run-time-toggleable ones (vim, fold)
 * live behind Compartments so they can be reconfigured without rebuilding the
 * view.
 */

/** Reconfigurable slot for vim mode (empty when off). */
export const vimCompartment = new Compartment();
/** Reconfigurable slot for code folding (folding logic + gutter, empty when off). */
export const foldCompartment = new Compartment();

/** Folding contents: the fold logic plus the click-to-fold gutter. */
function foldExtensions(): Extension {
  return [codeFolding(), foldGutter()];
}

/** Vim mode contents (empty when disabled). */
function vimExtensions(enabled: boolean): Extension {
  return enabled ? vim() : [];
}

/**
 * Multi-cursor / rectangular selection support. `allowMultipleSelections` is
 * required for the rectangular + crosshair drag and Alt/Cmd-click add-range
 * behaviour to actually take effect.
 */
function multiSelectionExtensions(): Extension {
  return [
    EditorState.allowMultipleSelections.of(true),
    rectangularSelection(),
    crosshairCursor(),
  ];
}

export interface EditorExtensionsOptions {
  /** Enable vim keybindings. */
  vim?: boolean;
  /** Enable code folding + the fold gutter. */
  fold?: boolean;
  /** Auto-close brackets/quotes as you type (CM6 closeBrackets). */
  autoPairBrackets?: boolean;
  /** Re-indent the current line on input (CM6 indentOnInput). */
  indentOnInput?: boolean;
  /** Cmd/Ctrl-click navigation for `[[wikilinks]]` / `[md](url)` in source. */
  linkNav?: SourceLinkNavOptions;
}

/**
 * Assemble the productivity bundle. Returns an array of extensions to splice
 * into an EditorState alongside the base editor config.
 *
 * - vim + fold are wrapped in their Compartments so the host can later call
 *   `vimCompartment.reconfigure(...)` / `foldCompartment.reconfigure(...)`.
 * - search is installed with `top: true` to match the app's panel placement.
 * - The keymap is appended last so fold/search bindings win where they should;
 *   the host's base keymap (default + history) should be ordered before this
 *   bundle so defaults remain the fallback.
 * - `autoPairBrackets` / `indentOnInput` are included only when enabled (they're
 *   gated on the wiki settings); when off they contribute nothing.
 * - `drawSelection({ drawRangeCursor: true })` replaces the native selection so
 *   multi-cursor carets are drawn clearly at every range.
 */
export function editorExtensions({
  vim: vimOn = false,
  fold = true,
  autoPairBrackets = false,
  indentOnInput: indentOnInputOn = false,
  linkNav,
}: EditorExtensionsOptions = {}): Extension {
  return [
    multiSelectionExtensions(),
    drawSelection({ drawRangeCursor: true }),
    EditorView.clickAddsSelectionRange.of(editorClickAddsSelectionRange),
    autoPairBrackets ? closeBrackets() : [],
    indentOnInputOn ? indentOnInput() : [],
    linkNav ? sourceLinkNav(linkNav) : [],
    foldCompartment.of(fold ? foldExtensions() : []),
    vimCompartment.of(vimExtensions(vimOn)),
    search({ top: true }),
    keymap.of([...searchKeymap, ...foldKeymap]),
  ];
}

/** Re-export the fold extension factory for hosts that want it standalone. */
export { foldExtensions };

/**
 * Alt-click (or Cmd-click on macOS) adds a selection range — the multi-cursor
 * gesture. Mirrors granite's platform check.
 */
export function editorClickAddsSelectionRange(event: MouseEvent): boolean {
  if (event.altKey && !event.shiftKey) return true;
  const platform = globalThis.navigator?.platform ?? "";
  const isMac = /Mac|iPhone|iPad|iPod/.test(platform);
  return isMac ? event.metaKey : event.ctrlKey;
}
