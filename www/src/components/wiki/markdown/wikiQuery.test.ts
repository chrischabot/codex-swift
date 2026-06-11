import { describe, it, expect } from "vitest";
import { parseWikiQuery, evalWikiQuery } from "./wikiQuery";
import type { WikiPageSummary, WikiIndexEntry } from "@/runtime/connector";

const P = (id: string, title: string, source?: string, updatedAt?: number): WikiPageSummary => ({
  id,
  title,
  source,
  updatedAt,
});
const E = (id: string, title: string, links: string[], props: Record<string, string>): WikiIndexEntry => ({
  id,
  title,
  links,
  props,
});

describe("parseWikiQuery", () => {
  it("parses directives and defaults", () => {
    const q = parseWikiQuery("title: dev\nlimit: 10\nsort: recent\nprop.status: draft");
    expect(q.title).toBe("dev");
    expect(q.limit).toBe(10);
    expect(q.sort).toBe("recent");
    expect(q.props).toEqual([{ key: "status", value: "draft" }]);
  });
  it("ignores comments and unknown lines, clamps limit", () => {
    const q = parseWikiQuery("# a comment\ngibberish line\nlimit: 9999");
    expect(q.limit).toBe(500);
    expect(q.sort).toBe("title");
  });
});

describe("evalWikiQuery", () => {
  const pages = [
    P("1", "DevRel Metrics", "devrel", 30),
    P("2", "AI Safety", "ai", 20),
    P("3", "Developer Tooling", "devrel", 10),
  ];
  const byId = new Map<string, WikiIndexEntry>([
    ["1", E("1", "DevRel Metrics", ["AI Safety"], { status: "draft", tags: "metrics, devrel" })],
    ["3", E("3", "Developer Tooling", ["DevRel Metrics"], { status: "done" })],
  ]);

  it("filters by title substring", () => {
    const r = evalWikiQuery(parseWikiQuery("title: dev"), pages, byId);
    // Sorted by title (locale-aware): "Developer Tooling" < "DevRel Metrics".
    expect(r.map((p) => p.id)).toEqual(["3", "1"]);
  });

  it("filters by source", () => {
    const r = evalWikiQuery(parseWikiQuery("source: ai"), pages, byId);
    expect(r.map((p) => p.id)).toEqual(["2"]);
  });

  it("filters by links-to", () => {
    const r = evalWikiQuery(parseWikiQuery("links-to: AI Safety"), pages, byId);
    expect(r.map((p) => p.id)).toEqual(["1"]);
  });

  it("filters by frontmatter prop", () => {
    const r = evalWikiQuery(parseWikiQuery("prop.status: draft"), pages, byId);
    expect(r.map((p) => p.id)).toEqual(["1"]);
  });

  it("filters by tag (frontmatter tags or source)", () => {
    const byTag = evalWikiQuery(parseWikiQuery("tag: metrics"), pages, byId);
    expect(byTag.map((p) => p.id)).toEqual(["1"]);
    const bySource = evalWikiQuery(parseWikiQuery("tag: ai"), pages, byId);
    expect(bySource.map((p) => p.id)).toEqual(["2"]);
  });

  it("sorts by recency and respects limit", () => {
    const r = evalWikiQuery(parseWikiQuery("source: devrel\nsort: recent\nlimit: 1"), pages, byId);
    expect(r.map((p) => p.id)).toEqual(["1"]); // updatedAt 30 > 10
  });
});
