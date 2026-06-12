import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import {
  AlignLeft,
  Calendar,
  CalendarClock,
  CheckSquare,
  Hash,
  Lock,
  List as ListIcon,
  Plus,
  Trash2,
  X,
} from "lucide-react";
import type { WikiPage } from "@/runtime/connector";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";

interface Props {
  page: WikiPage;
  onSave: (newBody: string) => Promise<void>;
}

// ─────────────────────────────────────────────────────────────────────────────
// Frontmatter (YAML-subset) editor with TRUE verbatim round-trip.
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

type PropType = "text" | "number" | "checkbox" | "list" | "date" | "datetime";

/**
 * Editable property row. We keep both the typed editor state AND the original
 * source so that an untouched row round-trips byte-for-byte and an unsafe row
 * can fall back to its verbatim text.
 */
interface PropertyRowState {
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
interface RawSegment {
  kind: "raw";
  id: string;
  /** Original source lines (no trailing newline added). */
  lines: string[];
}

type Segment = PropertyRowState | RawSegment;

interface ParsedFrontmatter {
  segments: Segment[];
  /** The verbatim original frontmatter text, used as the ultimate fallback. */
  originalYaml: string | null;
}

const ISO_DATE_RE = /^\d{4}-\d{2}-\d{2}$/;
const ISO_DATETIME_RE =
  /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}(?::\d{2})?(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?$/;

const TYPE_ICON: Record<PropType, typeof AlignLeft> = {
  text: AlignLeft,
  number: Hash,
  checkbox: CheckSquare,
  list: ListIcon,
  date: Calendar,
  datetime: CalendarClock,
};

const TYPE_LABEL: Record<PropType, string> = {
  text: "Text",
  number: "Number",
  checkbox: "Checkbox",
  list: "List",
  date: "Date",
  datetime: "Date & time",
};

const TYPE_ORDER: PropType[] = ["text", "number", "checkbox", "list", "date", "datetime"];

let _rid = 0;
function rid(): string {
  _rid += 1;
  return `p${_rid}`;
}

// ── Split: leading `---\n … \n---\n` block off the front of the body ──────────

interface Split {
  yamlText: string | null;
  body: string;
  newline: "\n" | "\r\n";
  /** The closing fence the source used — `---` or the YAML document-end `...`.
   *  Preserved on re-serialize so a `...`-terminated doc round-trips exactly. */
  endFence: "---" | "...";
}

// Exported for unit tests (pure; no behaviour change).
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
function formatTimestamp(value: unknown): string | null {
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

const HTTP_RE = /^https?:\/\//i;

interface SystemRow {
  label: string;
  node: React.ReactNode;
}

function buildSystemRows(page: WikiPage): SystemRow[] {
  const rows: SystemRow[] = [];
  const record = page as unknown as Record<string, unknown>;
  const source = page.source ?? (record.source as string | undefined);
  if (typeof source === "string" && source.trim()) {
    rows.push({ label: "Source", node: source.trim() });
  }
  const sourceURI = record.sourceURI ?? record.sourceUri ?? record.source_uri;
  if (typeof sourceURI === "string" && sourceURI.trim()) {
    const uri = sourceURI.trim();
    rows.push({
      label: "Source URI",
      node: HTTP_RE.test(uri) ? (
        <a
          href={uri}
          target="_blank"
          rel="noreferrer"
          className="break-all text-[color:var(--text-link)] hover:underline"
        >
          {uri}
        </a>
      ) : (
        <span className="break-all font-mono text-sm">{uri}</span>
      ),
    });
  }
  const updated = formatTimestamp(page.updatedAt);
  if (updated) rows.push({ label: "Updated", node: updated });
  return rows;
}

// ── Inputs for the date/datetime <input> elements ─────────────────────────────
function toDateInput(raw: string): string {
  return ISO_DATE_RE.test(raw.trim()) ? raw.trim() : "";
}
function toDatetimeInput(raw: string): string {
  const m = raw.trim().match(/^(\d{4}-\d{2}-\d{2}T\d{2}:\d{2})/);
  return m?.[1] ?? "";
}

export function WikiPropertiesEditor({ page, onSave }: Props) {
  const split = useMemo(() => splitFrontmatter(page.content), [page.content]);
  const parsed = useMemo(() => parseSegments(split.yamlText), [split.yamlText]);

  const [segments, setSegments] = useState<Segment[]>(parsed.segments);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Sequence guard: each commit gets a monotonically increasing ticket. Only
  // the most recently issued commit may apply its result; an out-of-order
  // onSave resolving late can NEVER persist a stale body / clear a fresh error.
  const commitSeq = useRef(0);
  const lastApplied = useRef(0);

  // Re-seed editor state when the underlying page changes (navigation, or a
  // save round-trips through the host into a fresh `page`).
  useEffect(() => {
    setSegments(parsed.segments);
    setError(null);
    // Treat the re-seed as the newest known state so any in-flight stale
    // commit is ignored once it resolves.
    commitSeq.current += 1;
    lastApplied.current = commitSeq.current;
  }, [parsed.segments]);

  const systemRows = useMemo(() => buildSystemRows(page), [page]);

  const commit = useCallback(
    async (nextSegments: Segment[]) => {
      const ticket = (commitSeq.current += 1);
      setSaving(true);
      setError(null);
      try {
        const nextBody = serialize(nextSegments, split.body, split.newline, split.endFence);
        await onSave(nextBody);
        // Only the latest commit may be considered authoritative.
        if (ticket >= lastApplied.current) lastApplied.current = ticket;
      } catch (err) {
        // A stale (superseded) commit must not surface its error over newer state.
        if (ticket >= lastApplied.current) {
          setError(err instanceof Error ? err.message : "Failed to save properties");
        }
      } finally {
        // Clear the saving flag only when the LATEST commit settles.
        if (ticket >= commitSeq.current) setSaving(false);
      }
    },
    [onSave, split.body, split.newline, split.endFence],
  );

  const patchRow = useCallback((id: string, patch: Partial<PropertyRowState>) => {
    setSegments((prev) =>
      prev.map((s) => (s.kind === "row" && s.id === id ? { ...s, ...patch } : s)),
    );
  }, []);

  const removeRow = useCallback(
    (id: string) => {
      setSegments((prev) => {
        const next = prev.filter((s) => !(s.kind === "row" && s.id === id));
        void commit(next);
        return next;
      });
    },
    [commit],
  );

  const addRow = useCallback(() => {
    setSegments((prev) => [
      ...prev,
      {
        kind: "row",
        id: rid(),
        key: "",
        type: "text",
        raw: "",
        bool: false,
        list: [],
        originalLines: [],
        readOnly: false,
      },
    ]);
  }, []);

  // Commit-on-blur helper: pull current segments from state and persist.
  const commitCurrent = useCallback(() => {
    setSegments((prev) => {
      void commit(prev);
      return prev;
    });
  }, [commit]);

  const rows = segments.filter((s): s is PropertyRowState => s.kind === "row");

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col">
        {rows.length === 0 ? (
          <div className="px-3 py-3 text-sm text-[color:var(--color-text-quaternary)]">
            No properties. Add one below.
          </div>
        ) : (
          rows.map((row) => (
            <PropertyRow
              key={row.id}
              row={row}
              disabled={saving}
              onPatch={(patch) => patchRow(row.id, patch)}
              onCommit={commitCurrent}
              onRemove={() => removeRow(row.id)}
            />
          ))
        )}
      </div>

      <div className="px-3">
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={saving}
          onClick={addRow}
          className="h-7 gap-1.5 px-2 text-[color:var(--color-text-tertiary)]"
        >
          <Plus className="size-3.5" />
          Add property
        </Button>
      </div>

      {error && (
        <div className="px-3 text-xs text-[color:var(--color-danger,#e5484d)]">{error}</div>
      )}

      {systemRows.length > 0 && (
        <div className="border-t border-[color:var(--border)] pt-2">
          <div className="px-3 pb-1 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-quaternary)]">
            Metadata
          </div>
          {systemRows.map((r) => (
            <div
              key={r.label}
              className="grid grid-cols-[minmax(5rem,38%)_1fr] items-baseline gap-x-3 px-3 py-1"
            >
              <span className="truncate text-sm text-[color:var(--color-text-tertiary)]">
                {r.label}
              </span>
              <span className="min-w-0 break-words text-sm text-foreground">{r.node}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}

interface RowProps {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
  onRemove: () => void;
}

function PropertyRow({ row, disabled, onPatch, onCommit, onRemove }: RowProps) {
  const Icon = row.readOnly ? Lock : TYPE_ICON[row.type];
  const [typeOpen, setTypeOpen] = useState(false);

  // Read-only row: show the verbatim source, never editable, never dropped.
  if (row.readOnly) {
    return (
      <div className="group grid grid-cols-[minmax(6rem,38%)_1fr_auto] items-center gap-x-2 px-3 py-1">
        <div className="flex min-w-0 items-center gap-1.5">
          <div className="flex size-5 shrink-0 items-center justify-center text-[color:var(--color-text-quaternary)]">
            <Lock className="size-3.5" />
          </div>
          <span
            className="truncate px-1 text-sm text-[color:var(--color-text-secondary)]"
            title={`${row.key} (read-only: preserved verbatim)`}
          >
            {row.key}
          </span>
        </div>
        <div className="min-w-0">
          <span className="block truncate px-1 text-sm text-[color:var(--color-text-quaternary)]">
            preserved verbatim
          </span>
        </div>
        <span aria-hidden className="size-6" />
      </div>
    );
  }

  return (
    <div className="group grid grid-cols-[minmax(6rem,38%)_1fr_auto] items-center gap-x-2 px-3 py-1">
      {/* Key cell: type icon (click to cycle type) + key input */}
      <div className="flex min-w-0 items-center gap-1.5">
        <div className="relative">
          <button
            type="button"
            disabled={disabled}
            aria-label={`Type: ${TYPE_LABEL[row.type]}`}
            title={`Type: ${TYPE_LABEL[row.type]}`}
            onClick={() => setTypeOpen((v) => !v)}
            className="flex size-5 shrink-0 items-center justify-center rounded text-[color:var(--color-text-quaternary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-text-secondary)]"
          >
            <Icon className="size-3.5" />
          </button>
          {typeOpen && (
            <div
              className="absolute left-0 top-6 z-10 flex flex-col rounded-md border border-[color:var(--border)] bg-[color:var(--popover,var(--background))] py-1 shadow-md"
              role="menu"
            >
              {TYPE_ORDER.map((t) => {
                const TIcon = TYPE_ICON[t];
                return (
                  <button
                    key={t}
                    type="button"
                    role="menuitem"
                    onClick={() => {
                      setTypeOpen(false);
                      if (t !== row.type) {
                        onPatch(coerceType(row, t));
                        onCommit();
                      }
                    }}
                    className={cn(
                      "flex items-center gap-2 px-3 py-1 text-left text-sm hover:bg-[color:var(--color-surface-hover)]",
                      t === row.type && "text-foreground",
                    )}
                  >
                    <TIcon className="size-3.5" />
                    {TYPE_LABEL[t]}
                  </button>
                );
              })}
            </div>
          )}
        </div>
        <Input
          value={row.key}
          disabled={disabled}
          placeholder="property"
          aria-label="Property name"
          onChange={(e) => onPatch({ key: e.currentTarget.value })}
          onBlur={onCommit}
          onKeyDown={(e) => {
            if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
          }}
          className="h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0"
        />
      </div>

      {/* Value cell: typed editor */}
      <div className="min-w-0">
        <ValueInput row={row} disabled={disabled} onPatch={onPatch} onCommit={onCommit} />
      </div>

      {/* Remove */}
      <button
        type="button"
        disabled={disabled}
        aria-label={`Remove ${row.key || "property"}`}
        onClick={onRemove}
        className="flex size-6 items-center justify-center rounded text-[color:var(--color-text-quaternary)] opacity-0 transition-opacity hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-danger,#e5484d)] group-hover:opacity-100"
      >
        <Trash2 className="size-3.5" />
      </button>
    </div>
  );
}

function ValueInput({
  row,
  disabled,
  onPatch,
  onCommit,
}: {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
}) {
  const baseInput =
    "h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0";

  if (row.type === "checkbox") {
    return (
      <input
        type="checkbox"
        disabled={disabled}
        checked={row.bool}
        aria-label="Value"
        onChange={(e) => {
          onPatch({ bool: e.currentTarget.checked });
          // Checkboxes commit immediately (no blur).
          queueMicrotask(onCommit);
        }}
        className="size-4 accent-[color:var(--primary,#3b82f6)]"
      />
    );
  }

  if (row.type === "number") {
    // Keep the raw token verbatim (text input, not number) so leading-zero /
    // long-id strings the user TYPED are preserved exactly. Serialization will
    // emit unsafe numbers as quoted text.
    return (
      <Input
        type="text"
        inputMode="decimal"
        disabled={disabled}
        value={row.raw}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        onKeyDown={(e) => {
          if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
        }}
        className={baseInput}
      />
    );
  }

  if (row.type === "list") {
    // Structured list editor: each item is its own input so values containing
    // commas are never split irreversibly.
    return <ListEditor row={row} disabled={disabled} onPatch={onPatch} onCommit={onCommit} />;
  }

  if (row.type === "date") {
    return (
      <Input
        type="date"
        disabled={disabled}
        value={toDateInput(row.raw)}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        className={baseInput}
      />
    );
  }

  if (row.type === "datetime") {
    return (
      <Input
        type="datetime-local"
        disabled={disabled}
        value={toDatetimeInput(row.raw)}
        aria-label="Value"
        onChange={(e) => onPatch({ raw: e.currentTarget.value })}
        onBlur={onCommit}
        className={baseInput}
      />
    );
  }

  // text
  return (
    <Input
      type="text"
      disabled={disabled}
      value={row.raw}
      placeholder="empty"
      aria-label="Value"
      onChange={(e) => onPatch({ raw: e.currentTarget.value })}
      onBlur={onCommit}
      onKeyDown={(e) => {
        if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
      }}
      className={baseInput}
    />
  );
}

/**
 * Per-item list editor. Items are edited individually (no comma-splitting), so
 * a value like "Doe, John" survives intact. Add / remove items inline.
 */
function ListEditor({
  row,
  disabled,
  onPatch,
  onCommit,
}: {
  row: PropertyRowState;
  disabled: boolean;
  onPatch: (patch: Partial<PropertyRowState>) => void;
  onCommit: () => void;
}) {
  const baseInput =
    "h-7 border-transparent px-1 text-sm hover:border-[color:var(--border)] focus-visible:border-[color:var(--border)] focus-visible:ring-0";

  const setItem = (idx: number, value: string) => {
    const list = row.list.slice();
    list[idx] = value;
    onPatch({ list });
  };
  const removeItem = (idx: number) => {
    const list = row.list.slice();
    list.splice(idx, 1);
    onPatch({ list });
    queueMicrotask(onCommit);
  };
  const addItem = () => {
    onPatch({ list: [...row.list, ""] });
  };

  return (
    <div className="flex flex-col gap-1 py-0.5">
      {row.list.map((item, idx) => (
        <div key={idx} className="flex items-center gap-1">
          <Input
            type="text"
            disabled={disabled}
            value={item}
            placeholder="item"
            aria-label={`List item ${idx + 1}`}
            onChange={(e) => setItem(idx, e.currentTarget.value)}
            onBlur={onCommit}
            onKeyDown={(e) => {
              if (e.key === "Enter") (e.currentTarget as HTMLInputElement).blur();
            }}
            className={baseInput}
          />
          <button
            type="button"
            disabled={disabled}
            aria-label={`Remove list item ${idx + 1}`}
            onClick={() => removeItem(idx)}
            className="flex size-6 shrink-0 items-center justify-center rounded text-[color:var(--color-text-quaternary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-danger,#e5484d)]"
          >
            <X className="size-3.5" />
          </button>
        </div>
      ))}
      <Button
        type="button"
        variant="ghost"
        size="sm"
        disabled={disabled}
        onClick={addItem}
        className="h-6 w-fit gap-1 px-1.5 text-xs text-[color:var(--color-text-tertiary)]"
      >
        <Plus className="size-3" />
        Add item
      </Button>
    </div>
  );
}

/** Coerce a row's held value when its type changes, best-effort. */
function coerceType(row: PropertyRowState, next: PropType): Partial<PropertyRowState> {
  // Best-effort current scalar representation of the row.
  const current =
    row.type === "checkbox"
      ? row.bool
        ? "true"
        : "false"
      : row.type === "list"
        ? row.list.join(", ")
        : row.raw;

  switch (next) {
    case "checkbox":
      return { type: next, bool: current.trim() === "true", raw: "", list: [] };
    case "list":
      // When coming from a non-list, seed a single item with the whole value
      // (no comma-split) so commas in the scalar survive.
      return {
        type: next,
        list: row.type === "list" ? row.list : current.trim() === "" ? [] : [current],
        raw: "",
        bool: false,
      };
    case "number":
    case "date":
    case "datetime":
    case "text":
    default:
      return { type: next, raw: current, bool: false, list: [] };
  }
}
