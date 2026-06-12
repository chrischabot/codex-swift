import { describe, it, expect } from "vitest";
import { idStr, mapWikiSummary, mapWikiPage, mapWikiIndexEntry } from "./connector-codex";

// Characterization tests: lock the wire contract between the Swift wiki/* RPCs
// (ids arrive as integers; fields like data/props/links may be missing) and the
// UI's WikiPage/WikiPageSummary/WikiIndexEntry types. A backend field rename or
// id type-change should break THESE, not the running app.

describe("idStr", () => {
  it("stringifies numbers, passes strings, empties everything else", () => {
    expect(idStr(42)).toBe("42");
    expect(idStr("x")).toBe("x");
    expect(idStr(null)).toBe("");
    expect(idStr(undefined)).toBe("");
    expect(idStr({})).toBe("");
  });
});

describe("mapWikiSummary", () => {
  it("maps a full wire row, stringifying the id", () => {
    const s = mapWikiSummary({ id: 7, title: "Roadmap", source: "devrel", excerpt: "x", updatedAt: 1700000000000 });
    expect(s.id).toBe("7");
    expect(s.title).toBe("Roadmap");
    expect(s.source).toBe("devrel");
    expect(s.excerpt).toBe("x");
    expect(s.updatedAt).toBe(1700000000000);
  });

  it("defaults a missing title to Untitled and tolerates missing optionals", () => {
    const s = mapWikiSummary({ id: 1 });
    expect(s.title).toBe("Untitled");
    expect(s.source).toBeUndefined();
    expect(s.excerpt).toBeUndefined();
  });

  it("normalizes epoch SECONDS to milliseconds", () => {
    // a <1e12 value is treated as seconds and scaled up
    expect(mapWikiSummary({ id: 1, updatedAt: 1700000000 }).updatedAt).toBe(1700000000 * 1000);
  });
});

describe("mapWikiPage", () => {
  it("maps content + filters string tags + maps connections", () => {
    const p = mapWikiPage({
      id: 3,
      title: "Entity",
      content: "# body",
      tags: ["a", 2, "b"],
      connections: [
        { entityId: 9, canonical: "Alice", kind: "person", relation: "mentions", weight: 0.5 },
        { entityId: 10 }, // no canonical → dropped
      ],
    });
    expect(p.id).toBe("3");
    expect(p.content).toBe("# body");
    expect(p.tags).toEqual(["a", "b"]);
    expect(p.connections).toHaveLength(1);
    expect(p.connections?.[0]).toMatchObject({ entityId: "9", canonical: "Alice", weight: 0.5 });
  });

  it("omits empty tags/connections and tolerates a minimal object", () => {
    const p = mapWikiPage({ id: 1 });
    expect(p.tags).toBeUndefined();
    expect(p.connections).toBeUndefined();
    expect(p.content).toBe("");
  });
});

describe("mapWikiIndexEntry", () => {
  it("keeps only string links and string prop values", () => {
    const e = mapWikiIndexEntry({ id: 5, title: "P", links: ["A", 2, "B", null], props: { status: "draft", n: 3, ok: "yes" } });
    expect(e.id).toBe("5");
    expect(e.title).toBe("P");
    expect(e.links).toEqual(["A", "B"]);
    expect(e.props).toEqual({ status: "draft", ok: "yes" });
  });

  it("defaults missing links/props to empty", () => {
    const e = mapWikiIndexEntry({ id: 1, title: "P" });
    expect(e.links).toEqual([]);
    expect(e.props).toEqual({});
  });

  it("a missing id maps to empty string (caller drops it via .filter(e=>e.id))", () => {
    expect(mapWikiIndexEntry({ title: "no id" }).id).toBe("");
  });
});
