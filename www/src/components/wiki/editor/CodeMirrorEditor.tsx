import * as React from "react";
import { EditorState, Compartment } from "@codemirror/state";
import { EditorView, keymap, lineNumbers } from "@codemirror/view";
import { defaultKeymap, history, historyKeymap } from "@codemirror/commands";
import { markdown, markdownLanguage } from "@codemirror/lang-markdown";
import { syntaxHighlighting, defaultHighlightStyle } from "@codemirror/language";
import { oneDark } from "@codemirror/theme-one-dark";
import { cn } from "@/lib/utils";

interface Props {
  value: string;
  onChange: (v: string) => void;
  className?: string;
}

// Bridges www's design tokens into CodeMirror's chrome so the editor reads as
// part of the app (not the stock CM look). The .dark-only token swap is handled
// by the theme Compartment below — this base layer is theme-agnostic.
const baseTheme = EditorView.theme({
  "&": {
    height: "100%",
    fontSize: "13px",
    color: "var(--foreground)",
    backgroundColor: "transparent",
  },
  ".cm-scroller": {
    fontFamily: "var(--font-mono, ui-monospace, SFMono-Regular, Menlo, monospace)",
    lineHeight: "1.6",
    padding: "12px 0",
  },
  ".cm-content": { caretColor: "var(--foreground)" },
  ".cm-gutters": {
    backgroundColor: "transparent",
    color: "var(--color-text-quaternary)",
    border: "none",
  },
  ".cm-activeLine": { backgroundColor: "transparent" },
  ".cm-activeLineGutter": { backgroundColor: "transparent" },
  "&.cm-focused": { outline: "none" },
  "&.cm-focused .cm-selectionBackground, .cm-selectionBackground, ::selection": {
    backgroundColor: "var(--color-surface-hover)",
  },
});

function isDark(): boolean {
  return document.documentElement.classList.contains("dark");
}

// The light/dark editor look. oneDark is applied only under the .dark class; in
// light mode we fall back to CM's default highlight style over the base theme.
function themeExtensions(dark: boolean) {
  return dark
    ? [oneDark]
    : [syntaxHighlighting(defaultHighlightStyle, { fallback: true })];
}

/**
 * Thin, controlled React wrapper around a single CM6 EditorView.
 *
 * - The view is created exactly once (empty deps effect) and destroyed on
 *   unmount; it is NOT re-created on prop changes (that would lose cursor/undo).
 * - External `value` changes are reconciled by diffing against the live doc and
 *   dispatching a minimal full-doc replace only when they actually differ, so
 *   round-tripping our own onChange never clobbers the caret.
 * - Theme lives in a Compartment reconfigured by a MutationObserver on
 *   documentElement's class — so toggling the app's .dark class re-themes the
 *   editor in place without rebuilding it.
 */
export function CodeMirrorEditor({ value, onChange, className }: Props) {
  const hostRef = React.useRef<HTMLDivElement>(null);
  const viewRef = React.useRef<EditorView | null>(null);
  const themeCompartment = React.useRef(new Compartment());
  // Keep the latest onChange reachable from the (stable) updateListener without
  // re-creating the view when the callback identity changes.
  const onChangeRef = React.useRef(onChange);
  onChangeRef.current = onChange;

  React.useEffect(() => {
    const host = hostRef.current;
    if (!host) return;

    const view = new EditorView({
      parent: host,
      state: EditorState.create({
        doc: value,
        extensions: [
          history(),
          lineNumbers(),
          keymap.of([...defaultKeymap, ...historyKeymap]),
          markdown({ base: markdownLanguage }),
          EditorView.lineWrapping,
          baseTheme,
          themeCompartment.current.of(themeExtensions(isDark())),
          EditorView.updateListener.of((u) => {
            if (u.docChanged) onChangeRef.current(u.state.doc.toString());
          }),
        ],
      }),
    });
    viewRef.current = view;

    // Re-theme in place when the app flips its .dark class.
    const observer = new MutationObserver(() => {
      view.dispatch({
        effects: themeCompartment.current.reconfigure(themeExtensions(isDark())),
      });
    });
    observer.observe(document.documentElement, {
      attributes: true,
      attributeFilter: ["class"],
    });

    return () => {
      observer.disconnect();
      view.destroy();
      viewRef.current = null;
    };
    // Created once; value/onChange are reconciled imperatively below.
    // eslint-disable-next-line react-hooks/exhaustive-deps
  }, []);

  // Reconcile external value -> editor doc without disturbing the cursor when
  // the change originated from our own onChange (doc already matches).
  React.useEffect(() => {
    const view = viewRef.current;
    if (!view) return;
    const current = view.state.doc.toString();
    if (value === current) return;
    // A whole-doc replace would collapse the caret to EOF; preserve the current
    // selection, clamped into the new document length, so an external value set
    // (async load, programmatic reset) doesn't jump the cursor.
    const sel = view.state.selection.main;
    const len = value.length;
    view.dispatch({
      changes: { from: 0, to: current.length, insert: value },
      selection: { anchor: Math.min(sel.anchor, len), head: Math.min(sel.head, len) },
    });
  }, [value]);

  return (
    <div
      ref={hostRef}
      className={cn("h-full w-full overflow-auto text-[13px]", className)}
    />
  );
}
