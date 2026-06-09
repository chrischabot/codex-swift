import { describe, it, expect } from "vitest";
import { parseSearchQuery, matchSummary, requiresFullCorpus } from "./searchQuery";
import type { WikiPageSummary } from "@/runtime/connector";

const page = (over: Partial<WikiPageSummary> = {}): WikiPageSummary => ({
  id: "1",
  title: "Untitled",
  ...over,
});

const matches = (raw: string, p: WikiPageSummary) => matchSummary(p, parseSearchQuery(raw));

describe("parseSearchQuery", () => {
  it("splits free terms into one AND group and seeds fullText", () => {
    const q = parseSearchQuery("alpha beta");
    expect(q.groups).toHaveLength(1);
    expect(q.groups[0].map((p) => p.value)).toEqual(["alpha", "beta"]);
    expect(q.fullText).toBe("alpha beta");
    expect(q.hasQuery).toBe(true);
  });

  it("splits OR into multiple groups", () => {
    const q = parseSearchQuery("alpha OR beta gamma");
    expect(q.groups).toHaveLength(2);
    expect(q.groups[0].map((p) => p.value)).toEqual(["alpha"]);
    expect(q.groups[1].map((p) => p.value)).toEqual(["beta", "gamma"]);
  });

  it("marks -term as negated and excludes it from fullText", () => {
    const q = parseSearchQuery("keep -drop");
    expect(q.groups[0][1].negate).toBe(true);
    expect(q.fullText).toBe("keep");
  });

  it("parses typed predicates tag/title/path and # sugar", () => {
    const q = parseSearchQuery("tag:work title:Report path:rss #urgent");
    const kinds = q.groups[0].map((p) => `${p.kind}:${p.value}`);
    expect(kinds).toEqual(["tag:work", "title:Report", "path:rss", "tag:urgent"]);
  });

  it("parses a quoted phrase as a single predicate", () => {
    const q = parseSearchQuery('"hello world" extra');
    expect(q.groups[0][0]).toMatchObject({ kind: "phrase", value: "hello world" });
    expect(q.groups[0][1].value).toBe("extra");
  });

  it("parses a /regex/flags predicate and compiles it", () => {
    const q = parseSearchQuery("/foo.*bar/");
    expect(q.groups[0][0].kind).toBe("regex");
    expect(q.groups[0][0].re).toBeInstanceOf(RegExp);
  });

  it("keeps an invalid regex as a predicate with re=null (matches nothing)", () => {
    const q = parseSearchQuery("/(/");
    expect(q.groups[0][0].kind).toBe("regex");
    expect(q.groups[0][0].re).toBeNull();
  });

  it("ignores [property] filters (deferred) without crashing", () => {
    const q = parseSearchQuery("[status:done] real");
    expect(q.groups[0].map((p) => p.value)).toEqual(["real"]);
  });

  it("treats a blank query as no query (matches all)", () => {
    expect(parseSearchQuery("   ").hasQuery).toBe(false);
  });

  it("strips stateful g/y flags from a regex (else .test() skips matches)", () => {
    const q = parseSearchQuery("/foo/g");
    const re = q.groups[0][0].re!;
    expect(re).toBeInstanceOf(RegExp);
    expect(re.global).toBe(false);
    expect(re.sticky).toBe(false);
    expect(re.ignoreCase).toBe(true);
  });

  it("refuses a catastrophic-backtracking (ReDoS) pattern → re=null", () => {
    expect(parseSearchQuery("/(a+)+$/").groups[0][0].re).toBeNull();
    expect(parseSearchQuery("/(a*)*/").groups[0][0].re).toBeNull();
  });

  it("refuses an over-long regex pattern → re=null", () => {
    expect(parseSearchQuery(`/${"a".repeat(300)}/`).groups[0][0].re).toBeNull();
  });

  it("an empty regex // does not match everything (re=null)", () => {
    const q = parseSearchQuery("//");
    expect(q.groups[0]?.[0]?.re ?? null).toBeNull();
  });

  it("an unterminated [bracket becomes a literal term, not a query-nuking ignore", () => {
    const q = parseSearchQuery("report [oops");
    const values = q.groups[0].map((p) => `${p.kind}:${p.value}`);
    expect(values).toContain("term:report");
    expect(values).toContain("term:[oops");
    expect(q.hasQuery).toBe(true);
  });

  it("a path-like /v1/memories is a literal TERM, not a malformed regex", () => {
    const q = parseSearchQuery("/v1/memories");
    expect(q.groups[0][0].kind).toBe("term");
    expect(q.groups[0][0].value).toBe("/v1/memories");
    expect(q.fullText).toBe("/v1/memories"); // so BM25 is seeded, not empty
  });

  it("still parses a well-formed /re/flags as a regex", () => {
    expect(parseSearchQuery("/foo/i").groups[0][0].kind).toBe("regex");
    expect(parseSearchQuery("/foo bar/").groups[0][0].kind).toBe("regex");
  });
});

describe("requiresFullCorpus (OR seeding correctness)", () => {
  it("is false when every group has a free-text seed", () => {
    expect(requiresFullCorpus(parseSearchQuery("alpha OR beta"))).toBe(false);
    expect(requiresFullCorpus(parseSearchQuery("alpha #tag"))).toBe(false);
  });
  it("is TRUE when an OR-group is operator-only (would be missed by BM25)", () => {
    // title:Roadmap has no free term → BM25 on 'urgent' can't surface it.
    expect(requiresFullCorpus(parseSearchQuery("title:Roadmap OR urgent"))).toBe(true);
  });
  it("is true for a single operator-only query", () => {
    expect(requiresFullCorpus(parseSearchQuery("title:Roadmap"))).toBe(true);
    expect(requiresFullCorpus(parseSearchQuery("-draft"))).toBe(true);
  });
  it("is false for a blank query", () => {
    expect(requiresFullCorpus(parseSearchQuery(""))).toBe(false);
  });
});

describe("matchSummary", () => {
  const p = page({ title: "Weekly Report", excerpt: "covers #work and #urgent items", source: "rss/feed" });

  it("AND requires all terms", () => {
    expect(matches("weekly report", p)).toBe(true);
    expect(matches("weekly missing", p)).toBe(false);
  });

  it("OR requires either group", () => {
    expect(matches("missing OR report", p)).toBe(true);
    expect(matches("missing OR alsomissing", p)).toBe(false);
  });

  it("negation excludes matches", () => {
    expect(matches("report -urgent", p)).toBe(false);
    expect(matches("report -nope", p)).toBe(true);
  });

  it("tag matches #tag text or the bare word", () => {
    expect(matches("#work", p)).toBe(true);
    expect(matches("tag:urgent", p)).toBe(true);
    expect(matches("#absent", p)).toBe(false);
  });

  it("title: matches only the title, path: only the source", () => {
    expect(matches("title:weekly", p)).toBe(true);
    expect(matches("title:work", p)).toBe(false); // 'work' is in excerpt, not title
    expect(matches("path:rss", p)).toBe(true);
    expect(matches("path:weekly", p)).toBe(false);
  });

  it("phrase matches a contiguous substring", () => {
    expect(matches('"weekly report"', p)).toBe(true);
    expect(matches('"report weekly"', p)).toBe(false);
  });

  it("regex matches over title+excerpt, case-insensitive", () => {
    expect(matches("/week.y/", p)).toBe(true);
    expect(matches("/zzz/", p)).toBe(false);
  });

  it("combines operators: tag AND title AND -exclusion", () => {
    expect(matches("#work title:report -draft", p)).toBe(true);
    expect(matches("#work title:report -urgent", p)).toBe(false);
  });

  it("an all-negated group still matches a page that lacks the excluded terms", () => {
    expect(matches("-draft -archived", p)).toBe(true);
  });

  it("a /g regex matches EVERY page in a filter pass (no lastIndex statefulness)", () => {
    // Reproduces the shared-compiled-regex bug: with a stateful /g flag, every
    // other page would be dropped. Parse once, reuse across all pages.
    const q = parseSearchQuery("/report/g");
    const pages = [1, 2, 3, 4].map((i) => page({ id: String(i), title: `Weekly Report ${i}` }));
    expect(pages.filter((pg) => matchSummary(pg, q)).map((pg) => pg.id)).toEqual(["1", "2", "3", "4"]);
  });
});
