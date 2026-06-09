// Markdown formatting transforms for the wiki editor. The pure functions
// (wrapToggle, toggleLinePrefix, wrapWikilink) operate on a plain string + a
// selection range and return the new string + the new selection — so they're
// unit-testable without a CodeMirror view. The CM6 Commands at the bottom adapt
// them to the live editor (used by both the keymap and the toolbar buttons).

import { EditorView, keymap } from "@codemirror/view";
import type { Command, KeyBinding } from "@codemirror/view";
import { EditorSelection } from "@codemirror/state";
import type { ChangeSpec, EditorState, SelectionRange } from "@codemirror/state";

export interface EditResult {
  text: string;
  /** New selection anchor + head (offsets into the new text). */
  from: number;
  to: number;
}

/**
 * Toggle an inline wrapper (`**`, `*`, `` ` ``, `==`) around [from,to).
 *  - Already wrapped (markers just inside or outside the selection) → unwrap.
 *  - A collapsed selection → insert `open+close` and place the caret between.
 *  - Otherwise → wrap the selection and keep it selected (inside the markers).
 */
type WrapOp = "unwrap-inside" | "unwrap-outside" | "insert-empty" | "wrap";

/**
 * Decide how to toggle a wrapper around a selection, given the selection text
 * and the characters immediately OUTSIDE it. `outerBefore`/`outerAfter` are the
 * up-to-`marker.length`+1 chars on each side, used both to detect "markers just
 * outside" and to avoid mis-unwrapping when the markers extend into a longer run
 * (e.g. italic `*` inside bold `**` must NOT strip a `*` off the `**`).
 */
function planWrap(sel: string, outerBefore: string, outerAfter: string, open: string, close: string): WrapOp {
  const collapsed = sel.length === 0;
  if (!collapsed && sel.length >= open.length + close.length && sel.startsWith(open) && sel.endsWith(close)) {
    return "unwrap-inside";
  }
  // "markers just outside" — but only when they aren't part of a longer same-char
  // run (which would mean a DIFFERENT marker, e.g. `**` vs `*`).
  const beforeEndsWithOpen = outerBefore.endsWith(open);
  const afterStartsWithClose = outerAfter.startsWith(close);
  const runBefore = outerBefore.length > open.length && outerBefore[outerBefore.length - open.length - 1] === open[0];
  const runAfter = outerAfter.length > close.length && outerAfter[close.length] === close[close.length - 1];
  if (!collapsed && beforeEndsWithOpen && afterStartsWithClose && !runBefore && !runAfter) {
    return "unwrap-outside";
  }
  if (collapsed) return "insert-empty";
  return "wrap";
}

export function wrapToggle(text: string, from: number, to: number, open: string, close = open): EditResult {
  const sel = text.slice(from, to);
  const outerBefore = text.slice(Math.max(0, from - open.length - 1), from);
  const outerAfter = text.slice(to, to + close.length + 1);
  switch (planWrap(sel, outerBefore, outerAfter, open, close)) {
    case "unwrap-inside": {
      const inner = sel.slice(open.length, sel.length - close.length);
      return { text: text.slice(0, from) + inner + text.slice(to), from, to: from + inner.length };
    }
    case "unwrap-outside": {
      const next = text.slice(0, from - open.length) + sel + text.slice(to + close.length);
      return { text: next, from: from - open.length, to: to - open.length };
    }
    case "insert-empty": {
      const next = text.slice(0, from) + open + close + text.slice(to);
      return { text: next, from: from + open.length, to: from + open.length };
    }
    default: {
      const next = text.slice(0, from) + open + sel + close + text.slice(to);
      return { text: next, from: from + open.length, to: to + open.length };
    }
  }
}

/** Per-range wrap toggle as a CM change spec — used by the multi-cursor-aware
 *  command path so EACH selection is wrapped (and only the affected spans
 *  change, preserving undo granularity). Exported for tests. */
export function wrapRange(state: EditorState, range: SelectionRange, open: string, close: string): { changes: ChangeSpec; range: SelectionRange } {
  const { from, to } = range;
  const sel = state.sliceDoc(from, to);
  const outerBefore = state.sliceDoc(Math.max(0, from - open.length - 1), from);
  const outerAfter = state.sliceDoc(to, Math.min(state.doc.length, to + close.length + 1));
  switch (planWrap(sel, outerBefore, outerAfter, open, close)) {
    case "unwrap-inside":
      return {
        changes: [{ from, to: from + open.length }, { from: to - close.length, to }],
        range: EditorSelection.range(from, to - open.length - close.length),
      };
    case "unwrap-outside":
      return {
        changes: [{ from: from - open.length, to: from }, { from: to, to: to + close.length }],
        range: EditorSelection.range(from - open.length, to - open.length),
      };
    case "insert-empty":
      return { changes: { from, insert: open + close }, range: EditorSelection.cursor(from + open.length) };
    default:
      return {
        changes: [{ from, insert: open }, { from: to, insert: close }],
        range: EditorSelection.range(from + open.length, to + open.length),
      };
  }
}

/** Wrap the selection as a `[[wikilink]]`; collapsed → `[[]]` with caret inside. */
export function wrapWikilink(text: string, from: number, to: number): EditResult {
  return wrapToggle(text, from, to, "[[", "]]");
}

/**
 * Toggle a line prefix (`# `, `## `, `> `, `- `) on every line the selection
 * touches. If ALL touched lines already have the prefix, remove it; otherwise
 * add it (replacing any existing heading prefix of a different level).
 */
export function toggleLinePrefix(text: string, from: number, to: number, prefix: string): EditResult {
  const lineStart = text.lastIndexOf("\n", from - 1) + 1;
  let lineEnd = text.indexOf("\n", to);
  if (lineEnd === -1) lineEnd = text.length;
  const block = text.slice(lineStart, lineEnd);
  const lines = block.split("\n");
  const isHeading = /^#{1,6} $/.test(prefix);
  const headingRe = /^#{1,6} /;
  // Toggle OFF only when EVERY line is ALREADY at this exact prefix/level.
  const allHave = lines.every((l) => l.startsWith(prefix));
  const nextLines = lines.map((l) => {
    if (allHave) return l.slice(prefix.length);
    // Toggle ON: headings replace any existing (wrong-level) heading marker;
    // other prefixes aren't double-added to a line that already has them.
    if (isHeading) return prefix + l.replace(headingRe, "");
    return l.startsWith(prefix) ? l : prefix + l;
  });
  const nextBlock = nextLines.join("\n");
  const next = text.slice(0, lineStart) + nextBlock + text.slice(lineEnd);
  const delta = nextBlock.length - block.length;
  return { text: next, from: lineStart, to: lineEnd + delta };
}

// ── CodeMirror command adapters ──────────────────────────────────────────────

/** Inline wrap (bold/italic/…) — applied to EVERY selection range via
 *  changeByRange, so multi-cursor works and only the wrapped spans change. */
function wrapAll(view: EditorView, open: string, close: string): boolean {
  const { state } = view;
  view.dispatch(
    state.changeByRange((range) => wrapRange(state, range, open, close)),
    { scrollIntoView: true },
  );
  view.focus();
  return true;
}

/** Single-range whole-doc transform (line prefixes operate on the main range's
 *  touched lines). */
function applyEdit(view: EditorView, fn: (text: string, from: number, to: number) => EditResult): boolean {
  const { state } = view;
  const range = state.selection.main;
  const result = fn(state.doc.toString(), range.from, range.to);
  view.dispatch({
    changes: { from: 0, to: state.doc.length, insert: result.text },
    selection: { anchor: result.from, head: result.to },
    scrollIntoView: true,
  });
  view.focus();
  return true;
}

export const boldCommand: Command = (view) => wrapAll(view, "**", "**");
export const italicCommand: Command = (view) => wrapAll(view, "*", "*");
export const codeCommand: Command = (view) => wrapAll(view, "`", "`");
export const strikethroughCommand: Command = (view) => wrapAll(view, "~~", "~~");
export const highlightCommand: Command = (view) => wrapAll(view, "==", "==");
export const wikilinkCommand: Command = (view) => wrapAll(view, "[[", "]]");
export const headingCommand = (level: number): Command => (view) =>
  applyEdit(view, (t, f, to) => toggleLinePrefix(t, f, to, "#".repeat(level) + " "));
export const quoteCommand: Command = (view) => applyEdit(view, (t, f, to) => toggleLinePrefix(t, f, to, "> "));
export const bulletCommand: Command = (view) => applyEdit(view, (t, f, to) => toggleLinePrefix(t, f, to, "- "));

/** Keymap for the editor: Cmd/Ctrl-B/I/`/K (+ Mod-Shift variants). */
export const formattingKeymap = keymap.of([
  { key: "Mod-b", run: boldCommand, preventDefault: true },
  { key: "Mod-i", run: italicCommand, preventDefault: true },
  { key: "Mod-`", run: codeCommand, preventDefault: true },
  { key: "Mod-k", run: wikilinkCommand, preventDefault: true },
  { key: "Mod-Shift-h", run: highlightCommand, preventDefault: true },
] as KeyBinding[]);
