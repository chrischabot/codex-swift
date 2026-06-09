// Wiki search query grammar — a client-side operator layer over the backend's
// lexical BM25 (which has no operator support). A query parses into OR-groups of
// AND-predicates; a page matches when ANY group fully matches. Each predicate
// can be negated. Matching runs over the fields a WikiPageSummary actually
// carries (title, excerpt, source) — tags are matched as `#tag` text since the
// summary has no structured tag list.
//
// Supported operators (Obsidian-flavored):
//   foo bar          two AND terms (word/substring in title+excerpt)
//   "foo bar"        a phrase (literal substring)
//   -foo             exclude (NOT)
//   foo OR bar       alternation (either side)
//   #tag / tag:foo   tag match (`#foo` literal or the word foo)
//   title:foo        title substring
//   path:foo         source/path substring
//   /re/flags        JavaScript regex over title+excerpt
//
// `[key]` / `[key:value]` property filters need page frontmatter (absent from
// the summary) and are intentionally parsed-but-ignored here (deferred).

import type { WikiPageSummary } from "@/runtime/connector";

export type PredicateKind = "term" | "phrase" | "tag" | "title" | "path" | "regex";

export interface Predicate {
  readonly kind: PredicateKind;
  readonly value: string;
  /** Compiled once for regex predicates (null if the pattern was invalid). */
  readonly re?: RegExp | null;
  readonly negate: boolean;
}

export interface SearchQuery {
  /** OR-groups; each is an AND-list of predicates. A summary matches if ANY
   *  group has ALL its predicates satisfied. Empty → match everything. */
  readonly groups: ReadonlyArray<ReadonlyArray<Predicate>>;
  /** Positive free-text/tag terms unioned across groups, for the BM25 candidate
   *  fetch. Empty → caller should list pages and filter client-side. */
  readonly fullText: string;
  /** Positive literal values to highlight in titles/excerpts (term/phrase/tag). */
  readonly highlightTerms: string[];
  /** True when the query has any predicate at all (vs blank). */
  readonly hasQuery: boolean;
}

// Tokenize respecting `/regex/flags`, "quoted phrases", and `[bracket]` groups,
// then whitespace for the rest.
function tokenize(raw: string): string[] {
  const tokens: string[] = [];
  let i = 0;
  const n = raw.length;
  while (i < n) {
    const ch = raw[i];
    if (ch === " " || ch === "\t" || ch === "\n") {
      i++;
      continue;
    }
    // Optional leading `-` stays attached to the token.
    let prefix = "";
    if (ch === "-" && i + 1 < n && raw[i + 1] !== " ") {
      prefix = "-";
      i++;
    }
    const c = raw[i];
    if (c === '"') {
      // Quoted phrase — to the next unescaped quote (or EOL).
      let j = i + 1;
      let buf = "";
      while (j < n && raw[j] !== '"') {
        buf += raw[j];
        j++;
      }
      tokens.push(prefix + '"' + buf + '"');
      i = j < n ? j + 1 : j;
    } else if (c === "/") {
      // Regex — to the next unescaped slash. Slurp trailing flag letters.
      let j = i + 1;
      let buf = "";
      while (j < n && !(raw[j] === "/" && raw[j - 1] !== "\\")) {
        buf += raw[j];
        j++;
      }
      let flags = "";
      j = j < n ? j + 1 : j;
      while (j < n && /[a-z]/i.test(raw[j])) {
        flags += raw[j];
        j++;
      }
      tokens.push(prefix + "/" + buf + "/" + flags);
      i = j;
    } else if (c === "[") {
      // Property filter — slurp to the matching `]` (parsed but ignored). An
      // UNTERMINATED `[` is NOT a property filter: fall through to plain-token
      // handling so a stray bracket becomes a literal term instead of silently
      // swallowing the rest of the query.
      let j = i + 1;
      while (j < n && raw[j] !== "]") j++;
      if (j < n) {
        tokens.push(prefix + "[" + raw.slice(i + 1, j) + "]");
        i = j + 1;
        continue;
      }
      // no closing ] → treat from `i` as a plain token (handled below)
      let k = i;
      let buf = "";
      while (k < n && !/\s/.test(raw[k])) {
        buf += raw[k];
        k++;
      }
      tokens.push(prefix + buf);
      i = k;
    } else {
      // Plain token to the next whitespace.
      let j = i;
      let buf = "";
      while (j < n && !/\s/.test(raw[j])) {
        buf += raw[j];
        j++;
      }
      tokens.push(prefix + buf);
      i = j;
    }
  }
  return tokens;
}

// Max regex pattern length + body window — bounds for the ReDoS mitigation.
const MAX_REGEX_LEN = 200;
const REGEX_BODY_CAP = 4000;
// Classic catastrophic-backtracking shape: a quantified group immediately
// quantified again, e.g. `(a+)+`, `(a*)*`, `(a+){2,}`. Not exhaustive, but it
// catches the common copy-paste ReDoS patterns.
const NESTED_QUANTIFIER_RE = /[+*}]\)\s*[+*{]/;

/**
 * Compile a user regex defensively:
 *  - empty pattern → null (a lone `//` must NOT match everything);
 *  - over-length or an obvious nested-quantifier (ReDoS) shape → null;
 *  - strip the stateful `g`/`y` flags (a shared compiled regex used across many
 *    summaries with `.test()` would otherwise skip every other match);
 *  - force case-insensitive `i`.
 * Returns null on any failure; a null `re` matches nothing.
 */
function compileSafeRegex(pattern: string, rawFlags: string): RegExp | null {
  if (!pattern || pattern.length > MAX_REGEX_LEN) return null;
  if (NESTED_QUANTIFIER_RE.test(pattern)) return null;
  const flags = [...new Set((rawFlags + "i").replace(/[gy]/g, "").split(""))].join("");
  try {
    return new RegExp(pattern, flags);
  } catch {
    return null;
  }
}

function toPredicate(token: string): Predicate | null {
  let negate = false;
  let t = token;
  if (t.startsWith("-")) {
    negate = true;
    t = t.slice(1);
  }
  if (!t) return null;
  const lower = t.toLowerCase();
  if (t.startsWith('"') && t.endsWith('"') && t.length >= 2) {
    const value = t.slice(1, -1);
    return value ? { kind: "phrase", value, negate } : null;
  }
  if (t.startsWith("/")) {
    const close = t.lastIndexOf("/");
    if (close > 0) {
      const pattern = t.slice(1, close);
      const flags = t.slice(close + 1);
      return { kind: "regex", value: pattern, re: compileSafeRegex(pattern, flags), negate };
    }
  }
  // A well-formed `[…]` property filter is deferred (ignored). An unterminated
  // `[foo` is NOT a property filter — fall through so it becomes a literal term.
  if (t.startsWith("[") && t.endsWith("]")) return null;
  if (lower.startsWith("tag:") && t.length > 4) {
    return { kind: "tag", value: t.slice(4).replace(/^#/, ""), negate };
  }
  if (lower.startsWith("title:") && t.length > 6) {
    return { kind: "title", value: t.slice(6), negate };
  }
  if (lower.startsWith("path:") && t.length > 5) {
    return { kind: "path", value: t.slice(5), negate };
  }
  if (t.startsWith("#") && t.length > 1) {
    return { kind: "tag", value: t.slice(1), negate };
  }
  return { kind: "term", value: t, negate };
}

export function parseSearchQuery(raw: string): SearchQuery {
  const tokens = tokenize(raw ?? "");
  const groups: Predicate[][] = [];
  let current: Predicate[] = [];
  const fullTextTerms: string[] = [];
  for (const tok of tokens) {
    if (tok === "OR" || tok === "||") {
      groups.push(current);
      current = [];
      continue;
    }
    const pred = toPredicate(tok);
    if (!pred) continue;
    current.push(pred);
    // Positive term/tag/phrase values seed the BM25 candidate fetch.
    if (!pred.negate && (pred.kind === "term" || pred.kind === "tag" || pred.kind === "phrase")) {
      fullTextTerms.push(pred.value);
    }
  }
  groups.push(current);
  const nonEmpty = groups.filter((g) => g.length > 0);
  const uniqueTerms = [...new Set(fullTextTerms)];
  return {
    groups: nonEmpty,
    fullText: uniqueTerms.join(" ").trim(),
    highlightTerms: uniqueTerms,
    hasQuery: nonEmpty.length > 0,
  };
}

function escapeRe(s: string): string {
  return s.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

/** Word-boundary-ish match (the `#`-aware boundary used by the M1 tag filter). */
function mentionsWord(hay: string, term: string): boolean {
  const esc = escapeRe(term);
  return new RegExp(`(^|[^\\w#])${esc}([^\\w]|$)`, "i").test(hay);
}

function predicateMatches(pred: Predicate, summary: WikiPageSummary): boolean {
  const title = summary.title ?? "";
  const excerpt = summary.excerpt ?? "";
  const source = summary.source ?? "";
  const body = `${title}\n${excerpt}`;
  const lowerBody = body.toLowerCase();
  let raw: boolean;
  switch (pred.kind) {
    case "term":
      raw = lowerBody.includes(pred.value.toLowerCase());
      break;
    case "phrase":
      raw = lowerBody.includes(pred.value.toLowerCase());
      break;
    case "title":
      raw = title.toLowerCase().includes(pred.value.toLowerCase());
      break;
    case "path":
      raw = source.toLowerCase().includes(pred.value.toLowerCase());
      break;
    case "tag":
      raw =
        lowerBody.includes(`#${pred.value.toLowerCase()}`) || mentionsWord(body, pred.value);
      break;
    case "regex":
      // Bound the input the (already nested-quantifier-screened) regex runs over.
      raw = pred.re ? pred.re.test(body.length > REGEX_BODY_CAP ? body.slice(0, REGEX_BODY_CAP) : body) : false;
      break;
    default:
      raw = false;
  }
  return pred.negate ? !raw : raw;
}

/** Does a summary satisfy the query (ANY OR-group fully matches)? */
export function matchSummary(summary: WikiPageSummary, query: SearchQuery): boolean {
  if (!query.hasQuery) return true;
  return query.groups.some((group) => group.every((p) => predicateMatches(p, summary)));
}
