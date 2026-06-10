// Per-setting editor chrome: native spellcheck attributes + a readable
// max-line-width constraint. Both are plain CM6 extensions so they live in the
// host's reconfigurable `extensions` array (the extrasCompartment), and toggle
// in place when the wiki settings change — no view rebuild, caret preserved.

import { EditorView } from "@codemirror/view";
import type { Extension } from "@codemirror/state";

/**
 * Native browser spellcheck on the editor's editable surface. Sets the same
 * attributes a `<textarea spellcheck>` would on `.cm-content` (contentEditable),
 * so the OS underlines misspellings. When `false` we explicitly disable all
 * three so an OS default doesn't sneak autocorrect into a markdown source.
 */
export function spellcheckChrome(enabled: boolean): Extension {
  return EditorView.contentAttributes.of({
    spellcheck: enabled ? "true" : "false",
    autocorrect: enabled ? "on" : "off",
    autocapitalize: enabled ? "sentences" : "off",
  });
}

/**
 * Constrain the editor content to a comfortable max line width, centered in the
 * scroller — the editor counterpart to the reading view's "readable line
 * width". Applied as a CM theme (scoped to this editor instance) rather than a
 * global stylesheet so it toggles cleanly with the setting. The width matches
 * the reading surface's measure (~700px).
 */
export function readableWidthChrome(): Extension {
  return EditorView.theme({
    ".cm-content": {
      maxWidth: "700px",
      marginLeft: "auto",
      marginRight: "auto",
    },
    // Keep the line-number gutter flush-left while the text centers.
    ".cm-line": { paddingLeft: "0" },
  });
}
