// ─────────────────────────────────────────────────────────────────────────────
// Frontmatter (YAML-subset) model with TRUE verbatim round-trip.
//
// Pure parse/serialize core extracted from WikiPropertiesEditor so it is
// testable in isolation and free of any React/DOM dependency. No JSX, no hooks,
// no lucide — just the segment model and the YAML-subset reader/writer.
//
// js-yaml is NOT a dependency, so we cannot fully model YAML. Instead of
// dropping anything we can't model (the old behaviour — silent data loss), we
// split the frontmatter into an ordered list of SEGMENTS:
//
//   • A "row" segment is a simple, editable shape whose EXACT source lines we
//     captured. We know how to re-emit it from its edited value:
//       key: scalar           (text / number / bool / null / date)
//       key: [a, b, c]         (inline flow list)
//       key:                   (block list)
//         - item
//   • A "raw" segment is ANY span we do not (or cannot safely) model — nested
//     maps, block/multiline scalars (|, >), comments, blank lines, anchors,
//     merge keys, unrecognised shapes. Its original text is stored verbatim.
//
// On serialize we walk the segments in their ORIGINAL order. Row segments are
// re-emitted from the (possibly edited) value; raw segments are emitted byte-
// for-byte. Newly-added rows are appended. Removed rows are skipped. Nothing
// from the source is ever silently dropped.
//
// Guard: if a captured row would not round-trip safely (e.g. its scalar carries
// a trailing comment or quoting we can't reproduce), it is marked read-only and
// preserved verbatim rather than risk corrupting it.
// ─────────────────────────────────────────────────────────────────────────────

export type PropType = "text" | "number" | "checkbox" | "list" | "date" | "datetime";

/**
 * Editable property row. We keep both the typed editor state AND the original
 * source so that an untouched row round-trips byte-for-byte and an unsafe row
 * can fall back to its verbatim text.
 */
export interface PropertyRowState {
  kind: "row";
  /** Stable id so React keys survive key renames. */
  id: string;
  key: string;
  type: PropType;
  /** Scalar draft (text/number/date/datetime). For numbers this holds the
   *  raw token verbatim so leading-zero / hex / id strings survive unedited. */
  raw: string;
  /** Checkbox value. */
  bool: boolean;
  /** List items (edited individually — never comma-split). */
  list: string[];
  /**
   * Exact original source lines this row owns (no trailing newline on the last
   * line). Used to detect "untouched" rows and to re-emit verbatim.
   */
  originalLines: string[];
  /**
   * If true the row's source could not be safely modelled for editing; it is
   * shown read-only and always re-emitted verbatim.
   */
  readOnly: boolean;
}

/** A verbatim span we do not model. Re-emitted exactly as captured. */
export interface RawSegment {
  kind: "raw";
  id: string;
  /** Original source lines (no trailing newline added). */
  lines: string[];
}

export type Segment = PropertyRowState | RawSegment;

export interface ParsedFrontmatter {
  segments: Segment[];
  /** The verbatim original frontmatter text, used as the ultimate fallback. */
  originalYaml: string | null;
}

export const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
export const ISO_DATETIME_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?$/;

export const TYPE_ORDER: PropType[] = ["text", "number", "checkbox", "list", "date", "datetime"];

let _rid = 0;
export function rid(): string {
  _rid += 1;
  return `p${_rid}`;
}

// ── Split: leading `---\n … \n---\n` block off the front of the body ──────────

export interface Split {
  yamlText: string | null;
  body: string;
  newline: "\n" | "\r\n";
  /** The closing fence the source used — `---` or the YAML document-end `...`.
   *  Preserved on re-serialize so a `...`-terminated doc round-trips exactly. */
  endFence: "---" | "...";
}

export function splitFrontmatter(text: string): Split {
  // Newline style is taken from the OPENING fence ONLY. Detecting it from the
  // whole document is wrong: a single `\r\n` anywhere (a Windows-pasted body
  // line, a CRLF code block) would force a `\r\n` end-marker that never matches
  // an LF fence, demoting the entire frontmatter into the body on save.
  const open = /^---(\r?\n)/.exec(text);
  const newline: "\n" | "\r\n" = open
    ? open[1] === "\r\n" ? "\r\n" : "\n"
    : text.includes("\r\n") ? "\r\n" : "\n";
  if (!open) return { yamlText: null, body: text, newline, endFence: "---" };
  const startLen = open[0].length; // 3 + newline length
  // Closing fence: the first `---` OR `...` (YAML document-end) on its own line.
  // Search from just before the first content line so an empty frontmatter
  // (`---\n---\n`) is still recognized.
  const from = Math.max(0, startLen - newline.length);
  let bestNl = -1; // index of the newline that precedes the closing marker
  let bodyStart = -1;
  let endFence: "---" | "..." = "---";
  for (const mark of ["---", "..."] as const) {
    const endMarker = `${newline}${mark}${newline}`;
    const i = text.indexOf(endMarker, from);
    if (i !== -1 && (bestNl === -1 || i < bestNl)) {
      bestNl = i;
      bodyStart = i + endMarker.length;
      endFence = mark;
    }
  }
  if (bestNl !== -1) {
    return { yamlText: text.slice(startLen, bestNl), body: text.slice(bodyStart), newline, endFence };
  }
  // Closing fence at EOF (no trailing newline).
  for (const mark of ["---", "..."] as const) {
    const tail = `${newline}${mark}`;
    if (text.endsWith(tail)) {
      return { yamlText: text.slice(startLen, text.length - tail.length), body: "", newline, endFence: mark };
    }
  }
  return { yamlText: null, body: text, newline, endFence: "---" };
}

// ── Scalar helpers ────────────────────────────────────────────────────────────

/** A quoted scalar we can faithfully reproduce → its unquoted content. */
interface UnquoteResult {
  value: string;
  /** The original quoting style so we don't change it on a no-op round-trip. */
  quote: '"' | "'" | "";
  /** True when the token is a plain (unquoted) scalar with no surprises. */
  plain: boolean;
}

/**
 * A YAML block / folded scalar header: `|` or `>` optionally followed by an
 * indentation indicator (1–9) and/or a chomping indicator (`+`/`-`) in either
 * order, then optional trailing whitespace + comment. We decline these so the
 * indented body that follows is preserved verbatim.
 */
function isBlockScalarHeader(afterTrim: string): boolean {
  return /^[|>](?:[1-9][+-]?|[+-][1-9]?|[+-]?)(?:\s+#.*)?$/.test(afterTrim);
}

function classifyScalar(rawToken: string): UnquoteResult | null {
  const t = rawToken.trim();
  if (t.length >= 2 && t[0] === '"' && t.endsWith('"')) {
    // Double-quoted. Only model simple escapes (\" and \\). Anything fancier
    // (\n, \uXXXX, …) we decline so it stays read-only/verbatim.
    const inner = t.slice(1, -1);
    if (/\\(?!["\\])/.test(inner)) return null;
    const value = inner.replace(/\\"/g, '"').replace(/\\\\/g, "\\");
    return { value, quote: '"', plain: false };
  }
  if (t.length >= 2 && t[0] === "'" && t.endsWith("'")) {
    const inner = t.slice(1, -1);
    // Single-quote YAML escapes '' → '. Decline if a lone ' appears.
    if (/(?<!')'(?!')/.test(inner)) return null;
    return { value: inner.replace(/''/g, "'"), quote: "'", plain: true };
  }
  // Plain scalar — must not contain structural characters that would change
  // meaning, and must not carry a trailing `#` comment we can't reproduce.
  if (t.includes(" #") || t.startsWith("#")) return null;
  // Inline flow mapping (`{a: 1, b: 2}`) and flow-anchor/alias/tag tokens are
  // not editable as a plain text value — editing then re-serializing would
  // mangle the structure. Decline so they stay verbatim raw.
  if (t.startsWith("{") || t.startsWith("&") || t.startsWith("*") || t.startsWith("!")) return null;
  return { value: t, quote: "", plain: true };
}

/** Parse an inline flow list `[a, b, c]` → string[] | null (null = decline). */
function parseFlowList(s: string): string[] | null {
  const t = s.trim();
  if (!(t.startsWith("[") && t.endsWith("]"))) return null;
  const inner = t.slice(1, -1).trim();
  if (inner.length === 0) return [];
  // Split on top-level commas, honouring quotes so "a, b" stays one item.
  const items: string[] = [];
  let buf = "";
  let quote: '"' | "'" | "" = "";
  for (let i = 0; i < inner.length; i++) {
    const ch = inner[i];
    if (quote) {
      if (ch === quote) quote = "";
      buf += ch;
    } else if (ch === '"' || ch === "'") {
      quote = ch;
      buf += ch;
    } else if (ch === ",") {
      items.push(buf);
      buf = "";
    } else if (ch === "[" || ch === "]" || ch === "{" || ch === "}") {
      // Nested flow collection — we can't model it; decline.
      return null;
    } else {
      buf += ch;
    }
  }
  items.push(buf);
  const out: string[] = [];
  for (const part of items) {
    const c = classifyScalar(part);
    if (c === null) return null; // an item we can't reproduce → decline
    out.push(c.value);
  }
  return out;
}

function inferScalarType(value: string, plain: boolean): PropType {
  const t = value.trim();
  if (plain && (t === "true" || t === "false")) return "checkbox";
  // Only infer "number" for tokens we can losslessly re-emit. A leading zero,
  // hex, exponent, leading +, or very long digit run (zip / phone / id) must
  // stay text so we never rewrite e.g. "01234" → 1234 or "1e3" → 1000.
  if (plain && isSafeNumber(t)) return "number";
  if (plain && ISO_DATETIME_RE.test(t)) return "datetime";
  if (plain && ISO_DATE_RE.test(t)) return "date";
  return "text";
}

/**
 * True only for tokens that survive `String(Number(t))` round-trip AND have no
 * formatting we'd silently destroy. Conservative on purpose.
 */
function isSafeNumber(t: string): boolean {
  if (!/^-?\d+(?:\.\d+)?$/.test(t)) return false; // no hex / exp / + sign
  if (/^-?0\d/.test(t)) return false; // leading zero (zip / id / "007")
  const n = Number(t);
  if (!Number.isFinite(n)) return false;
  // Must reproduce the exact digits (guards huge ints losing precision, and
  // trailing/leading formatting like "1.50" or "-0").
  return String(n) === t;
}

// ── Parse the frontmatter into ordered segments ───────────────────────────────

export function parseSegments(yamlText: string | null): ParsedFrontmatter {
  if (yamlText === null) return { segments: [], originalYaml: null };
  const lines = yamlText.split(/\r?\n/);
  const segments: Segment[] = [];
  let rawBuf: string[] = [];

  const flushRaw = () => {
    if (rawBuf.length > 0) {
      segments.push({ kind: "raw", id: rid(), lines: rawBuf });
      rawBuf = [];
    }
  };

  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];

    // Blank lines and comments are not editable → verbatim raw.
    if (line.trim() === "" || line.trimStart().startsWith("#")) {
      rawBuf.push(line);
      continue;
    }

    // Top-level `key:` lines only (no leading indent) are candidate rows.
    const m = /^([^\s:][^:]*?):(.*)$/.exec(line);
    if (!m) {
      // Indented or otherwise non-`key:` line → verbatim raw.
      rawBuf.push(line);
      continue;
    }

    const key = m[1].trim();
    const after = m[2];
    const afterTrim = after.trim();

    // ── Inline flow list ──────────────────────────────────────────────────
    if (afterTrim.startsWith("[")) {
      const flow = parseFlowList(after);
      if (flow !== null) {
        flushRaw();
        segments.push({
          kind: "row",
          id: rid(),
          key,
          type: "list",
          raw: "",
          bool: false,
          list: flow,
          originalLines: [line],
          readOnly: false,
        });
      } else {
        rawBuf.push(line); // can't model this flow list → verbatim
      }
      continue;
    }

    // ── Block / folded scalar (`key: |`, `key: >`, `key: |-`, `key: >+`,
    //    `key: |2`, `key: |2-`, …) ──────────────────────────────────────────
    //  We do NOT model these as editable rows — the value lives on the indented
    //  lines that follow, which an editable text row would drop. Decline the
    //  whole construct: emit the `key:` line plus its entire indented body as
    //  verbatim raw so it round-trips byte-for-byte.
    if (isBlockScalarHeader(afterTrim)) {
      rawBuf.push(line);
      // Accrete the block body: blank lines and any indented (leading-ws) line
      // belong to the block until a non-blank line dedents to column 0.
      let j = i + 1;
      for (; j < lines.length; j++) {
        const b = lines[j];
        if (b.trim() === "" || /^\s/.test(b)) {
          rawBuf.push(b);
        } else {
          break;
        }
      }
      i = j - 1;
      continue;
    }

    // ── Empty value: maybe a block list, maybe a nested map ───────────────
    if (afterTrim === "") {
      const block = scanBlockList(lines, i);
      if (block) {
        flushRaw();
        segments.push({
          kind: "row",
          id: rid(),
          key,
          type: "list",
          raw: "",
          bool: false,
          list: block.items,
          originalLines: lines.slice(i, block.end + 1),
          readOnly: false,
        });
        i = block.end;
        continue;
      }
      // `key:` with no value and no block list. If the NEXT non-blank line is
      // indented, it's a nested map / block scalar we don't model → raw the
      // `key:` line and let the indented lines accrete as raw too.
      rawBuf.push(line);
      continue;
    }

    // ── Scalar value ──────────────────────────────────────────────────────
    const c = classifyScalar(after);
    if (c === null) {
      rawBuf.push(line); // unreproducible scalar (comment / complex escape) → raw
      continue;
    }
    flushRaw();
    const type = inferScalarType(c.value, c.plain);
    if (type === "checkbox") {
      segments.push({
        kind: "row",
        id: rid(),
        key,
        type,
        raw: "",
        bool: c.value.trim() === "true",
        list: [],
        originalLines: [line],
        readOnly: false,
      });
    } else {
      segments.push({
        kind: "row",
        id: rid(),
        key,
        type,
        raw: c.value,
        bool: false,
        list: [],
        originalLines: [line],
        readOnly: false,
      });
    }
  }

  flushRaw();
  return { segments, originalYaml: yamlText };
}

/**
 * Scan a block list starting at the `key:` line at index `start`. Returns the
 * items and the index of the LAST line that belongs to the list, or null if
 * this isn't a block list.
 *
 * Over-capture fixes vs. the old scanner:
 *   • Stop at a blank line (blank ends the block — it's not part of it).
 *   • Stop at a dedent (a line indented at or below the parent `key:`).
 *   • Determine the list indent from the FIRST `- ` item, then require every
 *     subsequent item to match that exact indent; a deeper indent means a
 *     nested structure we don't model → decline the whole block (stays raw).
 */
function scanBlockList(
  lines: string[],
  start: number,
): { items: string[]; end: number } | null {
  const items: string[] = [];
  let listIndent: number | null = null;
  let end = start;
  for (let j = start + 1; j < lines.length; j++) {
    const next = lines[j];
    if (next.trim() === "") break; // blank ends the block
    const indentMatch = /^(\s*)/.exec(next);
    const indent = indentMatch ? indentMatch[1].length : 0;
    if (indent === 0) break; // dedent to top level → block ended
    const lm = /^(\s+)-\s+(.*)$/.exec(next);
    if (!lm) {
      // Indented but not a `- item` line → nested map under key, not a simple
      // list. Decline so the whole thing is preserved verbatim as raw.
      return null;
    }
    const itemIndent = lm[1].length;
    if (listIndent === null) {
      listIndent = itemIndent;
    } else if (itemIndent !== listIndent) {
      // Differing item indent → nested / continuation we can't model. Decline.
      return null;
    }
    const c = classifyScalar(lm[2]);
    if (c === null) return null; // item carries a comment / escape we can't reproduce
    items.push(c.value);
    end = j;
  }
  if (items.length === 0) return null;
  return { items, end };
}

// ── Serialize: segments → YAML-subset text ────────────────────────────────────

function needsQuote(s: string): boolean {
  if (s === "") return true;
  // Quote when the value could be mis-parsed as something else.
  return (
    /^\s|\s$/.test(s) ||
    /[:#[\]{}",]/.test(s) ||
    /^[-?&*!|>%@`]/.test(s) ||
    s === "true" ||
    s === "false" ||
    s === "null" ||
    s === "~" ||
    (Number.isFinite(Number(s)) && /^[+-]?[\d.]/.test(s))
  );
}

function quoteScalar(s: string): string {
  if (!needsQuote(s)) return s;
  return `"${s.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"`;
}

function quoteKey(key: string): string {
  return needsQuote(key) ? `"${key.replace(/\\/g, "\\\\").replace(/"/g, '\\"')}"` : key;
}

/**
 * Emit a row as YAML lines. Returns null if the row should be dropped (empty
 * key on a brand-new row). For an UNTOUCHED row we re-emit the exact original
 * lines so nothing changes; for a read-only row we ALWAYS re-emit verbatim.
 */
function serializeRow(row: PropertyRowState): string[] | null {
  if (row.readOnly) return row.originalLines;

  const key = row.key.trim();
  if (key === "") return row.originalLines.length > 0 ? row.originalLines : null;

  // Untouched? Re-emit verbatim to preserve original formatting/quoting.
  if (!rowEdited(row)) return row.originalLines;

  const qk = quoteKey(key);
  switch (row.type) {
    case "checkbox":
      return [`${qk}: ${row.bool ? "true" : "false"}`];
    case "number": {
      const n = row.raw.trim();
      // Empty or unsafe → emit as quoted text rather than corrupt it.
      if (n === "" || !isSafeNumber(n)) return [`${qk}: ${quoteScalar(n)}`];
      return [`${qk}: ${n}`]; // emit the verbatim token, not Number(n)
    }
    case "list": {
      const items = row.list;
      if (items.length === 0) return [`${qk}: []`];
      const lines = [`${qk}:`];
      for (const item of items) lines.push(`  - ${quoteScalar(item)}`);
      return lines;
    }
    case "date":
    case "datetime":
    case "text":
    default:
      return [`${qk}: ${quoteScalar(row.raw)}`];
  }
}

/** Has the user actually changed this row away from its captured source? */
function rowEdited(row: PropertyRowState): boolean {
  // A row created in-session has no original lines → always "edited".
  if (row.originalLines.length === 0) return true;
  const reparsed = parseSegments(row.originalLines.join("\n"));
  const orig = reparsed.segments.find((s): s is PropertyRowState => s.kind === "row");
  if (!orig) return true;
  if (orig.key !== row.key || orig.type !== row.type) return true;
  if (row.type === "checkbox") return orig.bool !== row.bool;
  if (row.type === "list") {
    return orig.list.length !== row.list.length || orig.list.some((v, k) => v !== row.list[k]);
  }
  return orig.raw !== row.raw;
}

export function serialize(
  segments: Segment[],
  body: string,
  newline: "\n" | "\r\n",
  endFence: "---" | "..." = "---",
): string {
  const out: string[] = [];
  for (const seg of segments) {
    if (seg.kind === "raw") {
      for (const l of seg.lines) out.push(l);
    } else {
      const emitted = serializeRow(seg);
      if (emitted) for (const l of emitted) out.push(l);
    }
  }
  // The markdown body is emitted VERBATIM — `splitFrontmatter` already returns
  // exactly the text after the closing fence's trailing newline, so re-prefixing
  // `---\n…\n---\n` reproduces the original byte-for-byte. (An earlier
  // `body.replace(/^\s+/, "")` here silently deleted leading blank lines and the
  // indentation of an indented first line — e.g. a leading indented code block —
  // on every save.)
  if (out.length === 0) return body;
  const block = out.join(newline);
  return `---${newline}${block}${newline}${endFence}${newline}${body}`;
}

// ── System metadata (read-only) ───────────────────────────────────────────────

/** Format an updatedAt timestamp (number ms / ISO string) → a locale string. */
export function formatTimestamp(value: unknown): string | null {
  let ts: number | null = null;
  if (typeof value === "number" && Number.isFinite(value)) ts = value;
  else if (typeof value === "string" && value.trim()) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) ts = parsed;
  }
  if (ts === null) return null;
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

// ── Inputs for the date/datetime <input> elements ─────────────────────────────
export function toDateInput(raw: string): string {
  return ISO_DATE_RE.test(raw.trim()) ? raw.trim() : "";
}
export function toDatetimeInput(raw: string): string {
  const m = raw.trim().match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})/);
  return m?.[1] ?? "";
}
