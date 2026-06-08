import { type EditorState, type Extension, RangeSetBuilder } from "@codemirror/state";
import {
  Decoration,
  type DecorationSet,
  type EditorView,
  ViewPlugin,
  type ViewUpdate,
} from "@codemirror/view";
import { syntaxTree } from "@codemirror/language";

/**
 * Live Preview — Obsidian-style "render as you type" for CodeMirror 6.
 *
 * Ported and re-shaped from granite's `cm-livepreview-decorations.ts` +
 * `cm-livepreview-classes.ts`. Granite split the behaviour across two plugins
 * (one that hides marks, one that tags classes); here they are fused into a
 * single ViewPlugin so we build the decoration set in one tree walk and emit
 * `Decoration.replace` (hide a mark), `Decoration.mark` (style a span), and
 * `Decoration.line` (style a whole line) in lockstep.
 *
 * Strategy
 * --------
 * The Lezer markdown syntax tree (via `@codemirror/language` `syntaxTree`, which
 * is the same grammar `markdownLanguage` installs) is the authority for block
 * and inline structure: headings, emphasis runs, inline code, fenced code,
 * links, images, blockquotes, lists, HR, tables. Walking the tree means we
 * never misfire inside a code fence or an escape.
 *
 * A small regex pass handles the two Obsidian-only constructs the stock GFM
 * grammar has no concept of: wikilinks `[[Page]]` / embeds `![[Page]]` and
 * `==highlights==`.
 *
 * Active-line reveal
 * ------------------
 * Any construct that intersects the line(s) currently holding the cursor or a
 * selection is left fully raw — the syntactic marks are NOT hidden — so the
 * text under the caret stays editable and the user can see what they're typing.
 * Everything else renders. Re-decoration runs on every doc change, selection
 * change, and viewport change.
 *
 * Robustness
 * ----------
 * Builders only ever receive ascending, non-empty ranges; bounds are clamped to
 * the document; partial / unbalanced markdown simply yields fewer decorations
 * rather than throwing. Code-fence interiors are skipped entirely.
 */

export interface LivePreviewOptions {
  /**
   * Optional resolver for wikilink / internal-link targets. Return `false` to
   * style the link as unresolved (dashed underline, muted). When omitted, all
   * links are treated as resolved. The check is best-effort and synchronous —
   * feed it a `Set`/`Map` snapshot of known page titles+ids.
   */
  readonly isLinkResolved?: (target: string) => boolean;
}

// --- Decoration singletons -------------------------------------------------

const hideMark = Decoration.replace({});

const headingLine = [
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-1" }),
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-2" }),
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-3" }),
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-4" }),
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-5" }),
  Decoration.line({ class: "cm-lp-heading cm-lp-heading-6" }),
] as const;

const codeblockLine = Decoration.line({ class: "cm-lp-codeblock" });
const codeblockBeginLine = Decoration.line({ class: "cm-lp-codeblock cm-lp-codeblock-begin" });
const codeblockEndLine = Decoration.line({ class: "cm-lp-codeblock cm-lp-codeblock-end" });
const quoteLine = Decoration.line({ class: "cm-lp-quote-line" });
const calloutLine = Decoration.line({ class: "cm-lp-callout-line" });
const listLine = Decoration.line({ class: "cm-lp-list-line" });

const strongMark = Decoration.mark({ class: "cm-lp-strong" });
const emphasisMark = Decoration.mark({ class: "cm-lp-em" });
const strikethroughMark = Decoration.mark({ class: "cm-lp-strike" });
const highlightMark = Decoration.mark({ class: "cm-lp-highlight" });
const inlineCodeMark = Decoration.mark({ class: "cm-lp-inline-code" });
const linkMark = Decoration.mark({ class: "cm-lp-link" });
const linkUnresolvedMark = Decoration.mark({ class: "cm-lp-link cm-lp-link-unresolved" });
const bulletMark = Decoration.mark({ class: "cm-lp-bullet" });
const hrLine = Decoration.line({ class: "cm-lp-hr-line" });

// --- Regex (Obsidian-only constructs) --------------------------------------

const WIKILINK_RE = /(!?)\[\[([^\]\n]+)\]\]/g;
const HIGHLIGHT_RE = /==([^=\n]+)==/g;
const CALLOUT_RE = /^(\s*>+\s*)\[!([^\]\n]+)\]([+-])?/;

// --- Internal entry model --------------------------------------------------

interface Entry {
  readonly from: number;
  readonly to: number;
  readonly deco: Decoration;
  /** Line decorations must sort before mark/replace at the same offset. */
  readonly rank: number;
}

// Equal-`from` emit order MUST match CM6's ascending startSide invariant in
// RangeSetBuilder: LineDecoration (side -2e8) < Decoration.replace (~4.99e8) <
// Decoration.mark (5e8). Emitting a mark before a replace at the same offset
// throws "Ranges must be added sorted by from position and startSide" —
// reachable on plain `**bold**` / `` `code` ``. So replace must outrank mark.
const RANK_LINE = 0;
const RANK_REPLACE = 1;
const RANK_MARK = 2;

function isEscaped(text: string, index: number): boolean {
  let slashes = 0;
  for (let i = index - 1; i >= 0 && text[i] === "\\"; i--) slashes += 1;
  return slashes % 2 === 1;
}

function parseWikilinkTarget(inner: string): { target: string; display: string | null } {
  const pipeIdx = inner.indexOf("|");
  let target = pipeIdx === -1 ? inner : inner.slice(0, pipeIdx);
  const display = pipeIdx === -1 ? null : inner.slice(pipeIdx + 1);
  // Strip a `#heading` / `#^block` suffix from the resolvable target.
  const hashIdx = target.indexOf("#");
  if (hashIdx !== -1) target = target.slice(0, hashIdx);
  return { target: target.trim(), display };
}

// --- Decoration builder ----------------------------------------------------

function buildDecorations(state: EditorState, opts: LivePreviewOptions): DecorationSet {
  const text = state.doc.toString();
  const docLength = state.doc.length;
  const entries: Entry[] = [];

  // Lines (1-based) touched by any cursor/selection range. A construct
  // overlapping any of these lines is revealed (marks left raw).
  const activeLines = new Set<number>();
  for (const range of state.selection.ranges) {
    const fromLine = state.doc.lineAt(range.from).number;
    const toLine = state.doc.lineAt(range.to).number;
    for (let n = fromLine; n <= toLine; n++) activeLines.add(n);
  }

  const lineNumberOf = (pos: number): number =>
    state.doc.lineAt(Math.max(0, Math.min(pos, docLength))).number;

  // True when [from,to) intersects any active (cursor) line.
  const isActive = (from: number, to: number): boolean => {
    const start = lineNumberOf(from);
    const end = lineNumberOf(Math.max(from, to - 1));
    for (let n = start; n <= end; n++) if (activeLines.has(n)) return true;
    return false;
  };

  const pushHide = (from: number, to: number): void => {
    if (from < 0 || to > docLength || from >= to) return;
    entries.push({ from, to, deco: hideMark, rank: RANK_REPLACE });
  };
  const pushMark = (from: number, to: number, deco: Decoration): void => {
    if (from < 0 || to > docLength || from >= to) return;
    entries.push({ from, to, deco, rank: RANK_MARK });
  };
  const pushLine = (linePos: number, deco: Decoration): void => {
    if (linePos < 0 || linePos > docLength) return;
    entries.push({ from: linePos, to: linePos, deco, rank: RANK_LINE });
  };

  // Track the document ranges occupied by wikilinks so the AST Link/Image
  // handler doesn't double-decorate `[[…]]` (Lezer parses the inner `[…]` as a
  // partial Link). Filled by the regex pass below, consumed by the tree walk.
  const wikilinkRanges: { from: number; to: number }[] = [];

  // ----- Regex pass: wikilinks / embeds + highlights -----------------------

  WIKILINK_RE.lastIndex = 0;
  for (let m = WIKILINK_RE.exec(text); m; m = WIKILINK_RE.exec(text)) {
    const isEmbed = m[1] === "!";
    const inner = m[2];
    if (!inner) continue;
    const fullStart = m.index;
    const fullEnd = fullStart + m[0].length;
    wikilinkRanges.push({ from: fullStart, to: fullEnd });
    if (isActive(fullStart, fullEnd)) continue;

    const { target, display } = parseWikilinkTarget(inner);
    if (!target) continue;
    const openLen = isEmbed ? 3 : 2; // `[[` or `![[`
    // Hide the opening brackets.
    pushHide(fullStart, fullStart + openLen);
    // Hide closing `]]`.
    pushHide(fullEnd - 2, fullEnd);
    // When a `display` alias exists, hide `target|` so only the display shows.
    const innerStart = fullStart + openLen;
    let labelFrom = innerStart;
    if (display != null) {
      const pipeIdx = inner.indexOf("|");
      if (pipeIdx !== -1) {
        pushHide(innerStart, innerStart + pipeIdx + 1);
        labelFrom = innerStart + pipeIdx + 1;
      }
    }
    const resolved = opts.isLinkResolved ? opts.isLinkResolved(target) : true;
    pushMark(labelFrom, fullEnd - 2, resolved ? linkMark : linkUnresolvedMark);
  }

  HIGHLIGHT_RE.lastIndex = 0;
  for (let m = HIGHLIGHT_RE.exec(text); m; m = HIGHLIGHT_RE.exec(text)) {
    const idx = m.index;
    const len = m[0].length;
    if (isEscaped(text, idx) || isEscaped(text, idx + len - 2)) continue;
    if (isActive(idx, idx + len)) continue;
    pushHide(idx, idx + 2);
    pushHide(idx + len - 2, idx + len);
    pushMark(idx + 2, idx + len - 2, highlightMark);
  }

  const overlapsWikilink = (from: number, to: number): boolean => {
    for (const r of wikilinkRanges) {
      if (from < r.to && to > r.from) return true;
    }
    return false;
  };

  // ----- AST pass ----------------------------------------------------------

  const tree = syntaxTree(state);
  tree.iterate({
    enter(node): boolean | undefined {
      const name = node.type.name;
      const { from, to } = node;

      switch (name) {
        case "ATXHeading1":
        case "ATXHeading2":
        case "ATXHeading3":
        case "ATXHeading4":
        case "ATXHeading5":
        case "ATXHeading6": {
          const level = Number(name.slice(-1));
          const lineDeco = headingLine[level - 1] ?? headingLine[0];
          const startLine = state.doc.lineAt(from);
          pushLine(startLine.from, lineDeco);
          if (!isActive(from, to)) {
            // Hide the leading `#`s plus the single space after them.
            const child = node.node.firstChild;
            if (child && child.type.name === "HeaderMark") {
              let end = child.to;
              while (end < docLength && (text[end] === " " || text[end] === "\t")) end += 1;
              pushHide(child.from, end);
            }
          }
          // Descend so inline emphasis inside the title still decorates.
          return;
        }
        case "SetextHeading1":
        case "SetextHeading2": {
          const level = name === "SetextHeading1" ? 1 : 2;
          const lineDeco = headingLine[level - 1] ?? headingLine[0];
          const startLine = state.doc.lineAt(from);
          pushLine(startLine.from, lineDeco);
          if (!isActive(from, to)) {
            // Hide the underline (`===` / `---`) — the trailing HeaderMark.
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.type.name === "HeaderMark") pushHide(c.from, c.to);
            }
          }
          return;
        }
        case "FencedCode":
        case "CodeBlock": {
          const startLine = state.doc.lineAt(from);
          const endLine = state.doc.lineAt(Math.max(from, Math.min(to, docLength) - 1));
          for (let n = startLine.number; n <= endLine.number; n++) {
            const ln = state.doc.line(n);
            const deco =
              n === startLine.number
                ? codeblockBeginLine
                : n === endLine.number
                  ? codeblockEndLine
                  : codeblockLine;
            pushLine(ln.from, deco);
          }
          // Never descend into code — its interior must stay raw.
          return false;
        }
        case "InlineCode": {
          // Style the whole span; hide the surrounding backticks (CodeMark
          // children) on non-active lines.
          if (!isActive(from, to)) {
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              if (c.type.name === "CodeMark") pushHide(c.from, c.to);
            }
          }
          pushMark(from, to, inlineCodeMark);
          return false;
        }
        case "Emphasis":
        case "StrongEmphasis":
        case "Strikethrough": {
          const styleMark =
            name === "StrongEmphasis"
              ? strongMark
              : name === "Strikethrough"
                ? strikethroughMark
                : emphasisMark;
          pushMark(from, to, styleMark);
          if (!isActive(from, to)) {
            // Hide the delimiter run children (EmphasisMark / StrikethroughMark).
            for (let c = node.node.firstChild; c; c = c.nextSibling) {
              const cn = c.type.name;
              if (cn === "EmphasisMark" || cn === "StrikethroughMark") {
                if (!isEscaped(text, c.from)) pushHide(c.from, c.to);
              }
            }
          }
          // Descend for nested emphasis (e.g. ***bold italic***).
          return;
        }
        case "Blockquote": {
          const startLine = state.doc.lineAt(from);
          const endLine = state.doc.lineAt(Math.max(from, to - 1));
          let callout = false;
          for (let n = startLine.number; n <= endLine.number; n++) {
            const ln = state.doc.line(n);
            if (!callout && CALLOUT_RE.test(ln.text)) callout = true;
            pushLine(ln.from, callout ? calloutLine : quoteLine);
            if (activeLines.has(n)) continue;
            // Hide the leading `>` markers (and trailing space) per line.
            const mq = /^\s*(?:>\s?)+/.exec(ln.text);
            if (mq && mq[0].length > 0) pushHide(ln.from, ln.from + mq[0].length);
          }
          // Descend so inline marks inside the quote still render.
          return;
        }
        case "BulletList":
        case "OrderedList": {
          const startLine = state.doc.lineAt(from);
          const endLine = state.doc.lineAt(Math.max(from, to - 1));
          for (let n = startLine.number; n <= endLine.number; n++) {
            pushLine(state.doc.line(n).from, listLine);
          }
          return;
        }
        case "ListMark": {
          // Render bullet markers as a styled bullet on non-active lines.
          // (Ordered-list numerals are kept as-is; only unordered bullets get
          // the dot treatment via the mark class.)
          if (!isActive(from, to)) {
            const ch = text[from];
            if (ch === "-" || ch === "*" || ch === "+") {
              pushMark(from, to, bulletMark);
            }
          }
          return false;
        }
        case "HorizontalRule": {
          const ln = state.doc.lineAt(from);
          pushLine(ln.from, hrLine);
          if (!isActive(from, to)) pushHide(from, to);
          return false;
        }
        case "Link":
        case "Image": {
          if (overlapsWikilink(from, to)) return false;
          // Collect LinkMark children: [ text ] ( url ).
          const marks: { from: number; to: number }[] = [];
          for (let c = node.node.firstChild; c; c = c.nextSibling) {
            if (c.type.name === "LinkMark") marks.push({ from: c.from, to: c.to });
          }
          if (marks.length >= 4) {
            const open = marks[0];
            const labelClose = marks[1];
            const urlClose = marks[marks.length - 1];
            if (open && labelClose && urlClose) {
              const labelFrom = open.to;
              const labelTo = labelClose.from;
              pushMark(labelFrom, labelTo, linkMark);
              if (!isActive(from, to)) {
                // Hide `[` (or `![`) and the `](url)` tail.
                pushHide(open.from, open.to);
                pushHide(labelClose.from, urlClose.to);
              }
            }
          }
          return false;
        }
        default:
          return;
      }
    },
  });

  // ----- Sort + build ------------------------------------------------------

  entries.sort((a, b) => {
    if (a.from !== b.from) return a.from - b.from;
    if (a.rank !== b.rank) return a.rank - b.rank;
    return a.to - b.to;
  });

  const builder = new RangeSetBuilder<Decoration>();
  for (const e of entries) builder.add(e.from, e.to, e.deco);
  return builder.finish();
}

// --- View plugin + extension factory ---------------------------------------

/**
 * Build the Live Preview extension. Add it to the CodeMirror extension list
 * (after `markdown({ base: markdownLanguage })`, which installs the syntax tree
 * this plugin reads). Remove it (or swap in an empty Compartment) for raw
 * "Source" mode.
 */
export function livePreview(opts: LivePreviewOptions = {}): Extension {
  return ViewPlugin.fromClass(
    class {
      decorations: DecorationSet;
      constructor(view: EditorView) {
        this.decorations = buildDecorations(view.state, opts);
      }
      update(update: ViewUpdate) {
        if (update.docChanged || update.selectionSet || update.viewportChanged) {
          this.decorations = buildDecorations(update.state, opts);
        }
      }
    },
    {
      decorations: (v) => v.decorations,
    },
  );
}
