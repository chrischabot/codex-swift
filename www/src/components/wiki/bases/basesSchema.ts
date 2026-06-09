// basesSchema.ts — types + parse/serialize for a "base" wiki document, plus a
// small frontmatter-property reader to expose page fields as base columns.
//
// STORAGE MODEL: a base is just a wiki page whose markdown body is a leading
// frontmatter sentinel followed by a JSON blob:
//
//   ---
//   wiki_type: base
//   ---
//   { "view": "table", "source": { … }, "columns": [ … ], … }
//
// We read a page's `content`, strip that frontmatter, and JSON.parse the rest.
// Saving reverses it. There is NO new backend — getWikiPage/saveWikiPage from
// the connector persist the document.
//
// ROWS are wiki pages. A column key is one of the structural pseudo-fields
// ("title" | "source" | "updatedAt" | "tags") or an arbitrary frontmatter
// property key read from the row page's own `content` frontmatter.

import type { WikiPage, WikiPageSummary } from "@/runtime/connector";

// ─────────────────────────────────────────────────────────────────────────────
// Types
// ─────────────────────────────────────────────────────────────────────────────

export type BaseViewType = "table" | "list" | "cards";

export type SortDir = "asc" | "desc";

/** A column key — a structural pseudo-field, or a frontmatter property key. */
export type ColumnKey = "title" | "source" | "updatedAt" | "tags" | (string & {});

export const BUILTIN_COLUMNS: ReadonlyArray<ColumnKey> = ["title", "source", "updatedAt", "tags"];

export type FilterOp = "contains" | "eq" | "neq" | "exists" | "empty" | "gt" | "lt";

export const FILTER_OPS: ReadonlyArray<FilterOp> = [
  "contains",
  "eq",
  "neq",
  "exists",
  "empty",
  "gt",
  "lt",
];

export const FILTER_OP_LABEL: Record<FilterOp, string> = {
  contains: "contains",
  eq: "is",
  neq: "is not",
  exists: "is set",
  empty: "is empty",
  gt: ">",
  lt: "<",
};

/** Operators that don't use the `value` field. */
export const UNARY_OPS: ReadonlySet<FilterOp> = new Set<FilterOp>(["exists", "empty"]);

export interface BaseColumn {
  readonly key: ColumnKey;
  readonly label: string;
}

export interface BaseFilter {
  readonly key: ColumnKey;
  readonly op: FilterOp;
  readonly value: string;
}

export interface BaseSort {
  readonly key: ColumnKey;
  readonly dir: SortDir;
}

export interface BaseSource {
  /** Client-filter rows whose page.tags include this tag. */
  readonly tag?: string;
  /** Full-text query sent to searchWiki. When empty, listWikiPages is used. */
  readonly query?: string;
}

export interface BaseConfig {
  readonly view: BaseViewType;
  readonly source: BaseSource;
  readonly columns: ReadonlyArray<BaseColumn>;
  readonly filters: ReadonlyArray<BaseFilter>;
  readonly sort: ReadonlyArray<BaseSort>;
  readonly group?: ColumnKey;
  /** Per-column footer summary op (e.g. {prio: "sum"}). Op strings are validated
   *  by the view (baseSummaries.SummaryOp); kept loose here to avoid a cycle. */
  readonly summaries?: Readonly<Record<string, string>>;
}

export const DEFAULT_BASE: BaseConfig = {
  view: "table",
  source: {},
  columns: [
    { key: "title", label: "Title" },
    { key: "tags", label: "Tags" },
    { key: "updatedAt", label: "Updated" },
  ],
  filters: [],
  sort: [{ key: "title", dir: "asc" }],
};

export const WIKI_TYPE = "base";

// ─────────────────────────────────────────────────────────────────────────────
// Frontmatter split (shared shape with the wiki properties editor)
// ─────────────────────────────────────────────────────────────────────────────

const FENCE_RE = /^---\r?\n/;

interface Split {
  /** The text between the `---` fences, or null when there's no frontmatter. */
  frontmatter: string | null;
  /** The document body after the closing fence. */
  body: string;
  newline: "\n" | "\r\n";
}

/** Split a leading `---\n … \n---\n` block off the front of `text`. */
export function splitFrontmatter(text: string): Split {
  const newline: "\n" | "\r\n" = text.includes("\r\n") ? "\r\n" : "\n";
  if (!FENCE_RE.test(text)) return { frontmatter: null, body: text, newline };
  const startLen = 3 + newline.length;
  const endMarker = `${newline}---${newline}`;
  const end = text.indexOf(endMarker, startLen);
  if (end === -1) {
    const tailMarker = `${newline}---`;
    if (text.endsWith(tailMarker)) {
      return { frontmatter: text.slice(startLen, text.length - tailMarker.length), body: "", newline };
    }
    return { frontmatter: null, body: text, newline };
  }
  return { frontmatter: text.slice(startLen, end), body: text.slice(end + endMarker.length), newline };
}

/** Read a single top-level `key:` scalar out of a frontmatter block. */
function readFrontmatterKey(frontmatter: string, key: string): string | null {
  for (const line of frontmatter.split(/\r?\n/)) {
    const m = /^([^\s:][^:]*?):(.*)$/.exec(line);
    if (m && m[1].trim() === key) return m[2].trim();
  }
  return null;
}

// ─────────────────────────────────────────────────────────────────────────────
// Base doc parse / serialize
// ─────────────────────────────────────────────────────────────────────────────

function unquote(s: string): string {
  const t = s.trim();
  if (t.length >= 2 && ((t[0] === '"' && t.endsWith('"')) || (t[0] === "'" && t.endsWith("'")))) {
    return t.slice(1, -1);
  }
  return t;
}

/** Is this page body a `wiki_type: base` document? */
export function isBaseBody(content: string | undefined | null): boolean {
  if (!content) return false;
  const { frontmatter, body } = splitFrontmatter(content);
  if (frontmatter === null) return false;
  const v = readFrontmatterKey(frontmatter, "wiki_type");
  if (v === null || unquote(v) !== WIKI_TYPE) return false;
  // Require the body to actually be a base JSON object, so a normal prose page
  // that merely carries a `wiki_type: base` frontmatter key is NOT hijacked into
  // the full-bleed base view (which has no Edit escape hatch).
  const jsonText = body.trim();
  if (!jsonText) return false;
  try {
    const p = JSON.parse(jsonText);
    return !!p && typeof p === "object" && !Array.isArray(p);
  } catch {
    return false;
  }
}

function asView(v: unknown): BaseViewType {
  return v === "list" || v === "cards" ? v : "table";
}

function asColumns(v: unknown): BaseColumn[] {
  if (!Array.isArray(v)) return [...DEFAULT_BASE.columns];
  const out: BaseColumn[] = [];
  for (const c of v) {
    if (!c || typeof c !== "object") continue;
    const rec = c as Record<string, unknown>;
    const key = typeof rec.key === "string" ? rec.key : null;
    if (!key) continue;
    const label = typeof rec.label === "string" && rec.label ? rec.label : defaultColumnLabel(key);
    out.push({ key, label });
  }
  return out.length > 0 ? out : [...DEFAULT_BASE.columns];
}

function asFilters(v: unknown): BaseFilter[] {
  if (!Array.isArray(v)) return [];
  const out: BaseFilter[] = [];
  for (const f of v) {
    if (!f || typeof f !== "object") continue;
    const rec = f as Record<string, unknown>;
    const key = typeof rec.key === "string" ? rec.key : null;
    const op = typeof rec.op === "string" && (FILTER_OPS as string[]).includes(rec.op)
      ? (rec.op as FilterOp)
      : null;
    if (!key || !op) continue;
    out.push({ key, op, value: typeof rec.value === "string" ? rec.value : "" });
  }
  return out;
}

function asSort(v: unknown): BaseSort[] {
  if (!Array.isArray(v)) return [];
  const out: BaseSort[] = [];
  for (const s of v) {
    if (!s || typeof s !== "object") continue;
    const rec = s as Record<string, unknown>;
    const key = typeof rec.key === "string" ? rec.key : null;
    if (!key) continue;
    out.push({ key, dir: rec.dir === "desc" ? "desc" : "asc" });
  }
  return out;
}

function asSource(v: unknown): BaseSource {
  if (!v || typeof v !== "object") return {};
  const rec = v as Record<string, unknown>;
  const source: { tag?: string; query?: string } = {};
  if (typeof rec.tag === "string" && rec.tag) source.tag = rec.tag;
  if (typeof rec.query === "string" && rec.query) source.query = rec.query;
  return source;
}

/** Parse a base wiki page's `content` into a BaseConfig (defaults filled in). */
export function parseBaseConfig(content: string | undefined | null): BaseConfig {
  if (!content) return DEFAULT_BASE;
  const { frontmatter, body } = splitFrontmatter(content);
  // The JSON blob is everything after the frontmatter (or the whole thing if a
  // doc was hand-written without a fence).
  const jsonText = (frontmatter !== null ? body : content).trim();
  if (!jsonText) return DEFAULT_BASE;
  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    return DEFAULT_BASE;
  }
  if (!parsed || typeof parsed !== "object" || Array.isArray(parsed)) return DEFAULT_BASE;
  const obj = parsed as Record<string, unknown>;
  const group = typeof obj.group === "string" && obj.group ? (obj.group as ColumnKey) : undefined;
  const config: BaseConfig = {
    view: asView(obj.view),
    source: asSource(obj.source),
    columns: asColumns(obj.columns),
    filters: asFilters(obj.filters),
    sort: asSort(obj.sort),
    summaries: asSummaries(obj.summaries),
  };
  return group ? { ...config, group } : config;
}

/** A `{ columnKey: opString }` map of string→string, or undefined. */
function asSummaries(v: unknown): Readonly<Record<string, string>> | undefined {
  if (!v || typeof v !== "object" || Array.isArray(v)) return undefined;
  const out: Record<string, string> = {};
  for (const [k, val] of Object.entries(v as Record<string, unknown>)) {
    if (typeof val === "string" && val) out[k] = val;
  }
  return Object.keys(out).length > 0 ? out : undefined;
}

/** Serialize a BaseConfig back into a wiki page body (frontmatter + JSON). */
export function serializeBaseConfig(config: BaseConfig): string {
  const json: Record<string, unknown> = {
    view: config.view,
    source: config.source,
    columns: config.columns.map((c) => ({ key: c.key, label: c.label })),
    filters: config.filters.map((f) => ({ key: f.key, op: f.op, value: f.value })),
    sort: config.sort.map((s) => ({ key: s.key, dir: s.dir })),
  };
  if (config.group) json.group = config.group;
  if (config.summaries && Object.keys(config.summaries).length > 0) json.summaries = config.summaries;
  return `---\nwiki_type: ${WIKI_TYPE}\n---\n${JSON.stringify(json, null, 2)}\n`;
}

// ─────────────────────────────────────────────────────────────────────────────
// Row value extraction — a wiki page IS a row
// ─────────────────────────────────────────────────────────────────────────────

/** Default human label for a column key. */
export function defaultColumnLabel(key: ColumnKey): string {
  switch (key) {
    case "title":
      return "Title";
    case "source":
      return "Source";
    case "updatedAt":
      return "Updated";
    case "tags":
      return "Tags";
    default:
      // Humanize a frontmatter key ("due_date" → "Due date").
      return key
        .replace(/[_-]+/g, " ")
        .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
        .replace(/^./, (c) => c.toUpperCase());
  }
}

/**
 * Read the frontmatter properties of a row page's `content`. Returns a flat
 * `key → value` record where values are string | number | boolean | string[].
 * Reuses the same YAML-subset grammar as the properties editor (scalars, inline
 * flow lists, and block `- item` lists).
 */
export function readPageProperties(content: string | undefined | null): Record<string, unknown> {
  if (!content) return {};
  const { frontmatter } = splitFrontmatter(content);
  if (frontmatter === null) return {};
  const lines = frontmatter.split(/\r?\n/);
  const out: Record<string, unknown> = {};
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    if (line.trim() === "" || line.trimStart().startsWith("#")) continue;
    const m = /^([^\s:][^:]*?):(.*)$/.exec(line);
    if (!m) continue;
    const key = m[1].trim();
    if (key === "wiki_type") continue;
    const after = m[2];
    // Inline flow list: [a, b, c]
    const flow = after.trim();
    if (flow.startsWith("[") && flow.endsWith("]")) {
      const inner = flow.slice(1, -1).trim();
      out[key] = inner
        ? inner.split(",").map((p) => unquote(p)).filter((p) => p.length > 0)
        : [];
      continue;
    }
    const valueText = after.trim();
    if (valueText === "") {
      // Possibly a block list on following indented `- ` lines.
      const items: string[] = [];
      let j = i + 1;
      for (; j < lines.length; j++) {
        const lm = /^(\s+)-\s+(.*)$/.exec(lines[j]);
        if (!lm) {
          if (lines[j].trim() === "") continue;
          break;
        }
        items.push(unquote(lm[2]));
      }
      if (items.length > 0) {
        out[key] = items;
        i = j - 1;
      }
      continue;
    }
    out[key] = coerceScalar(unquote(valueText));
  }
  return out;
}

function coerceScalar(s: string): string | number | boolean {
  if (s === "true") return true;
  if (s === "false") return false;
  // Only numify when the string round-trips through Number losslessly, so
  // leading-zero ids ('007'), hex ('0x10'), and big-ints that lose precision
  // stay verbatim strings. Anchored decimal form + String(Number(s)) === s.
  if (/^-?(?:0|[1-9]\d*)(?:\.\d+)?$/.test(s)) {
    const n = Number(s);
    if (Number.isFinite(n) && String(n) === s) return n;
  }
  return s;
}

/** A row is a page summary plus its parsed frontmatter properties. */
export interface BaseRow {
  readonly page: WikiPageSummary;
  readonly props: Record<string, unknown>;
}

/** Build a BaseRow from a (possibly full) page + its content for properties. */
export function makeRow(page: WikiPageSummary, content?: string | null): BaseRow {
  return { page, props: readPageProperties(content) };
}

/** Extract a column's raw value from a row. */
export function cellValue(row: BaseRow, key: ColumnKey): unknown {
  switch (key) {
    case "title":
      return row.page.title;
    case "source":
      return row.page.source ?? "";
    case "updatedAt":
      return row.page.updatedAt ?? null;
    case "tags": {
      // Tags can come from the full WikiPage (when fetched) or frontmatter.
      const fromPage = (row.page as Partial<WikiPage>).tags;
      if (Array.isArray(fromPage)) return fromPage;
      const fromProps = row.props.tags;
      return Array.isArray(fromProps) ? fromProps : fromProps != null ? [fromProps] : [];
    }
    default:
      return row.props[key];
  }
}

/** Page tags regardless of whether we hold a summary or full page. */
export function rowTags(row: BaseRow): string[] {
  const v = cellValue(row, "tags");
  return Array.isArray(v) ? v.map((x) => String(x)) : [];
}

// ─────────────────────────────────────────────────────────────────────────────
// Format / sort helpers
// ─────────────────────────────────────────────────────────────────────────────

export function formatCell(value: unknown, key: ColumnKey): string {
  if (value === null || value === undefined) return "";
  if (Array.isArray(value)) return value.map((x) => String(x)).join(", ");
  if (key === "updatedAt") {
    const ts = typeof value === "number" ? value : Number(value);
    if (!Number.isFinite(ts) || ts === 0) return "";
    return new Date(ts).toLocaleDateString(undefined, {
      year: "numeric",
      month: "short",
      day: "numeric",
    });
  }
  if (typeof value === "object") return JSON.stringify(value);
  return String(value);
}

function sortKey(v: unknown): number | string {
  if (v === null || v === undefined) return "";
  if (typeof v === "number") return v;
  if (Array.isArray(v)) return v.map((x) => String(x)).join(", ").toLowerCase();
  if (typeof v === "boolean") return v ? 1 : 0;
  const n = Number(v);
  if (typeof v === "string" && v.trim() !== "" && Number.isFinite(n)) return n;
  return String(v).toLowerCase();
}

/** Multi-key client-side sort. */
export function sortRows(rows: ReadonlyArray<BaseRow>, sort: ReadonlyArray<BaseSort>): BaseRow[] {
  if (sort.length === 0) return [...rows];
  const copy = [...rows];
  copy.sort((a, b) => {
    for (const s of sort) {
      const ka = sortKey(cellValue(a, s.key));
      const kb = sortKey(cellValue(b, s.key));
      if (ka < kb) return s.dir === "asc" ? -1 : 1;
      if (ka > kb) return s.dir === "asc" ? 1 : -1;
    }
    return 0;
  });
  return copy;
}

/** Apply one filter to a row. */
function rowMatchesFilter(row: BaseRow, filter: BaseFilter): boolean {
  const raw = cellValue(row, filter.key);
  const isEmpty =
    raw === null ||
    raw === undefined ||
    raw === "" ||
    (Array.isArray(raw) && raw.length === 0);
  switch (filter.op) {
    case "exists":
      return !isEmpty;
    case "empty":
      return isEmpty;
    case "eq":
      return formatCell(raw, filter.key).toLowerCase() === filter.value.trim().toLowerCase();
    case "neq":
      return formatCell(raw, filter.key).toLowerCase() !== filter.value.trim().toLowerCase();
    case "contains":
      return formatCell(raw, filter.key).toLowerCase().includes(filter.value.trim().toLowerCase());
    case "gt":
    case "lt": {
      const n = Number(raw);
      const target = Number(filter.value);
      if (!Number.isFinite(n) || !Number.isFinite(target)) {
        // Fall back to string compare.
        const s = formatCell(raw, filter.key).toLowerCase();
        const t = filter.value.trim().toLowerCase();
        return filter.op === "gt" ? s > t : s < t;
      }
      return filter.op === "gt" ? n > target : n < target;
    }
    default:
      return true;
  }
}

/** Apply ALL filters (AND semantics) to a row set. */
export function filterRows(
  rows: ReadonlyArray<BaseRow>,
  filters: ReadonlyArray<BaseFilter>,
): BaseRow[] {
  if (filters.length === 0) return [...rows];
  return rows.filter((r) => filters.every((f) => rowMatchesFilter(r, f)));
}

/** Group rows by the value of a column. Returns insertion-ordered buckets. */
export function groupRows(
  rows: ReadonlyArray<BaseRow>,
  key: ColumnKey,
): Map<string, BaseRow[]> {
  const out = new Map<string, BaseRow[]>();
  for (const row of rows) {
    const raw = cellValue(row, key);
    const label =
      raw === null || raw === undefined || raw === ""
        ? "(none)"
        : Array.isArray(raw)
          ? raw.length === 0
            ? "(none)"
            : raw.map((x) => String(x)).join(", ")
          : String(raw);
    const bucket = out.get(label);
    if (bucket) bucket.push(row);
    else out.set(label, [row]);
  }
  return out;
}

/** All column keys observed across a row set (for the "add column" picker). */
export function discoverColumnKeys(rows: ReadonlyArray<BaseRow>): ColumnKey[] {
  const keys = new Set<ColumnKey>();
  for (const row of rows) {
    for (const k of Object.keys(row.props)) {
      if (k !== "wiki_type") keys.add(k);
    }
  }
  return [...keys].sort();
}
