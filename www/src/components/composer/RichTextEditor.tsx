import * as React from "react";
import { cn } from "@/lib/utils";

// ---------------------------------------------------------------------------
// RichTextEditor — a contenteditable-based composer input that renders inline
// mention/skill CHIPS (pill <span>s) for @mentions and /commands as the user
// types, while emitting PLAIN TEXT on submit.
//
// Mirrors the original composer's inline-mention treatment (inline-mention-style.js
// / inline-mentions.js): chips use the brand-aware "inline-mention" link color
// (mapped here to the --text-link token) and are font-medium. The editor stores
// its canonical value as plain text; chips are derived from the text whenever it
// changes and re-serialized to plain text on input/submit so the existing
// onSubmit(text) / value contract is preserved exactly.
//
// NO new npm dependency: this is a hand-rolled contenteditable, not a 3rd-party
// rich-text framework.
// ---------------------------------------------------------------------------

export interface CaretToken {
  /** The trigger character that opened this token ("@" or "/"). */
  trigger: "@" | "/";
  /** Text typed after the trigger, e.g. "src/types" for "@src/types". */
  query: string;
  /** Caret rect in viewport coordinates, for anchoring popovers. */
  rect: DOMRect | null;
}

export interface RichTextEditorHandle {
  focus: () => void;
  clear: () => void;
  /** Current plain-text value. */
  getText: () => string;
  /**
   * Replaces the active caret token (the @… or /… being typed) with a chip
   * label plus a trailing space, and collapses the popover token.
   */
  replaceToken: (label: string, trigger: "@" | "/") => void;
  /** Removes the active caret token entirely (used when a slash command fires). */
  removeToken: () => void;
}

interface Props {
  value: string;
  onChange: (text: string) => void;
  onSubmit?: () => void;
  placeholder?: string;
  className?: string;
  /** Fires whenever the caret sits inside an @… or /… token (or null when not). */
  onToken?: (token: CaretToken | null) => void;
  /** When the token popover owns navigation keys, the editor defers to it. */
  popoverOpen?: boolean;
  "aria-label"?: string;
}

// A mention chip is rendered for an @token; a command chip for a leading /token.
const MENTION_RE = /(^|\s)@([A-Za-z0-9_./-]+)/g;
const COMMAND_RE = /^(\s*)\/([A-Za-z][A-Za-z0-9_-]*)/;

const CHIP_CLASS =
  "inline-mention font-medium text-[color:var(--text-link)] [&]:cursor-pointer";

// Build the chip + plain-text segments for a value. Slash commands only chip the
// first leading token (matching the original which treats / as a leading-only
// command trigger); @mentions chip anywhere preceded by whitespace/start.
type Segment = { text: string; chip: boolean };

function segmentize(value: string): Segment[] {
  const segments: Segment[] = [];
  let rest = value;
  let offset = 0;

  // Leading slash command chip.
  const cmd = COMMAND_RE.exec(value);
  if (cmd) {
    const lead = cmd[1];
    const token = `/${cmd[2]}`;
    if (lead) segments.push({ text: lead, chip: false });
    segments.push({ text: token, chip: true });
    offset = lead.length + token.length;
    rest = value.slice(offset);
  }

  // @mention chips in the remainder.
  let lastIndex = 0;
  MENTION_RE.lastIndex = 0;
  let m: RegExpExecArray | null;
  while ((m = MENTION_RE.exec(rest)) !== null) {
    const pre = m[1];
    const start = m.index + pre.length;
    if (start > lastIndex) segments.push({ text: rest.slice(lastIndex, start), chip: false });
    segments.push({ text: `@${m[2]}`, chip: true });
    lastIndex = MENTION_RE.lastIndex;
  }
  if (lastIndex < rest.length) segments.push({ text: rest.slice(lastIndex), chip: false });

  return segments.length ? segments : [{ text: "", chip: false }];
}

// Serializes the contenteditable DOM back to plain text. Chips serialize to their
// textContent; <br> and block boundaries become "\n".
function domToText(root: HTMLElement): string {
  let text = "";
  const walk = (node: Node) => {
    node.childNodes.forEach((child) => {
      if (child.nodeType === Node.TEXT_NODE) {
        text += child.textContent ?? "";
      } else if (child.nodeName === "BR") {
        text += "\n";
      } else if (child instanceof HTMLElement) {
        if (child.dataset.chip === "1") {
          text += child.textContent ?? "";
        } else {
          // A DIV/P inserted by the browser starts a new line.
          if (text && (child.nodeName === "DIV" || child.nodeName === "P")) text += "\n";
          walk(child);
        }
      }
    });
  };
  walk(root);
  return text;
}

export const RichTextEditor = React.forwardRef<RichTextEditorHandle, Props>(
  function RichTextEditor(
    { value, onChange, onSubmit, placeholder, className, onToken, popoverOpen, ...rest },
    forwardedRef,
  ) {
    const editorRef = React.useRef<HTMLDivElement | null>(null);
    // Tracks the last value we ourselves rendered, so external value resets
    // (e.g. clearing after submit) re-render while local typing does not thrash.
    const renderedRef = React.useRef<string>("");

    const render = React.useCallback((text: string) => {
      const el = editorRef.current;
      if (!el) return;
      el.innerHTML = "";
      const segs = segmentize(text);
      segs.forEach((seg) => {
        if (seg.chip) {
          const span = document.createElement("span");
          span.dataset.chip = "1";
          span.contentEditable = "false";
          span.className = CHIP_CLASS;
          span.textContent = seg.text;
          el.appendChild(span);
        } else {
          el.appendChild(document.createTextNode(seg.text));
        }
      });
      renderedRef.current = text;
    }, []);

    // Place the caret at the end of the editor content.
    const caretToEnd = React.useCallback(() => {
      const el = editorRef.current;
      if (!el) return;
      const range = document.createRange();
      range.selectNodeContents(el);
      range.collapse(false);
      const sel = window.getSelection();
      sel?.removeAllRanges();
      sel?.addRange(range);
    }, []);

    // Compute the caret token (@… or /…) from the plain text + caret offset.
    const computeToken = React.useCallback((): CaretToken | null => {
      const el = editorRef.current;
      const sel = window.getSelection();
      if (!el || !sel || sel.rangeCount === 0) return null;

      const text = domToText(el);
      // Caret offset within plain text: measure text before the caret.
      const range = sel.getRangeAt(0).cloneRange();
      const pre = range.cloneRange();
      pre.selectNodeContents(el);
      pre.setEnd(range.endContainer, range.endOffset);
      const before = preRangeText(el, pre.endContainer, pre.endOffset);

      let rect: DOMRect | null = null;
      const rects = range.getClientRects();
      if (rects.length) rect = rects[0];
      else rect = el.getBoundingClientRect();

      // Slash: only when the whole value (trimStart) is a single leading /token.
      const trimmed = text.trimStart();
      if (trimmed.startsWith("/") && /^\/[A-Za-z]*$/.test(trimmed) && !text.includes("\n")) {
        return { trigger: "/", query: trimmed.slice(1), rect };
      }

      // @mention: find the nearest "@" before the caret with a valid token tail.
      const atIdx = before.lastIndexOf("@");
      if (atIdx >= 0) {
        const since = before.slice(atIdx + 1);
        const valid = /^[A-Za-z0-9_./-]*$/.test(since);
        const boundaryOk = atIdx === 0 || /\s/.test(before[atIdx - 1]);
        if (valid && boundaryOk) return { trigger: "@", query: since, rect };
      }
      return null;
    }, []);

    const emit = React.useCallback(() => {
      const el = editorRef.current;
      if (!el) return;
      const text = domToText(el);
      renderedRef.current = text;
      onChange(text);
      onToken?.(computeToken());
    }, [onChange, onToken, computeToken]);

    // External value sync: re-render chips when the value changes from outside
    // (clear after submit, programmatic set). Skip when it already matches what
    // we rendered to avoid clobbering the caret mid-typing.
    React.useEffect(() => {
      if (value === renderedRef.current) return;
      render(value);
      if (value === "") return;
      caretToEnd();
    }, [value, render, caretToEnd]);

    React.useImperativeHandle(
      forwardedRef,
      (): RichTextEditorHandle => ({
        focus: () => editorRef.current?.focus(),
        clear: () => {
          render("");
          onChange("");
          onToken?.(null);
        },
        getText: () => (editorRef.current ? domToText(editorRef.current) : ""),
        replaceToken: (label, trigger) => {
          const el = editorRef.current;
          if (!el) return;
          const text = domToText(el);
          let next: string;
          if (trigger === "/") {
            // Leading slash token replaced by "/label ".
            next = text.replace(COMMAND_RE, (_full, lead: string) => `${lead}/${label} `);
            if (next === text) next = `/${label} `;
          } else {
            const sel = window.getSelection();
            const before =
              sel && sel.rangeCount
                ? preRangeText(
                    el,
                    sel.getRangeAt(0).endContainer,
                    sel.getRangeAt(0).endOffset,
                  )
                : text;
            const atIdx = before.lastIndexOf("@");
            const head = atIdx >= 0 ? text.slice(0, atIdx) : text;
            const tail = text.slice(before.length);
            next = `${head}@${label} ${tail}`;
          }
          render(next);
          onChange(next);
          caretToEnd();
          onToken?.(null);
        },
        removeToken: () => {
          render("");
          onChange("");
          onToken?.(null);
        },
      }),
      [render, onChange, onToken, caretToEnd],
    );

    return (
      <div className="relative">
        {value.length === 0 && (
          <div
            aria-hidden
            className="pointer-events-none absolute left-4 top-3 text-lg leading-5 text-[color:var(--color-text-quaternary)]"
          >
            {placeholder}
          </div>
        )}
        <div
          ref={editorRef}
          role="textbox"
          aria-multiline="true"
          aria-label={rest["aria-label"]}
          contentEditable
          suppressContentEditableWarning
          spellCheck
          onInput={emit}
          onKeyUp={() => onToken?.(computeToken())}
          onMouseUp={() => onToken?.(computeToken())}
          onKeyDown={(e) => {
            if (popoverOpen) {
              // The anchored popover owns navigation/selection keys.
              if (
                e.key === "Enter" ||
                e.key === "Tab" ||
                e.key === "Escape" ||
                e.key === "ArrowDown" ||
                e.key === "ArrowUp"
              ) {
                return;
              }
            }
            if (e.key === "Enter" && !e.shiftKey) {
              e.preventDefault();
              onSubmit?.();
            }
          }}
          className={cn(
            "block max-h-[200px] w-full overflow-y-auto whitespace-pre-wrap break-words border-0 bg-transparent px-4 pt-3 pb-1 text-lg leading-5 text-foreground outline-none",
            className,
          )}
        />
      </div>
    );
  },
);

// Returns the plain text of `root` up to (container, offset), serializing chips
// to their textContent — i.e. the caret-relative offset in the canonical text.
function preRangeText(root: HTMLElement, container: Node, offset: number): string {
  const range = document.createRange();
  range.selectNodeContents(root);
  try {
    range.setEnd(container, offset);
  } catch {
    return domToText(root);
  }
  const frag = range.cloneContents();
  const holder = document.createElement("div");
  holder.appendChild(frag);
  return domToText(holder);
}
