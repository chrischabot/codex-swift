import { describe, it, expect } from "vitest";
import { idStr, mapWikiSummary, mapWikiPage, mapWikiIndexEntry, mapLibrarianReport, mapAuditReport, mapInventoryRecord, mapDatasetManifest, mapCollectCatalog } from "./connector-codex";

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

describe("mapLibrarianReport", () => {
  it("maps the exact Swift wire keys (documentID/needsTier2/depthProxy/…)", () => {
    const r = mapLibrarianReport({
      pages: 5, flagged: 2,
      stalest: [
        { documentID: 12, volatility: "hot", staleness: 18.4, needsTier2: true, sourceCount: 1, depthProxy: 2 },
      ],
    });
    expect(r.pages).toBe(5);
    expect(r.flagged).toBe(2);
    expect(r.stalest).toHaveLength(1);
    expect(r.stalest[0]).toEqual({
      documentID: 12, volatility: "hot", staleness: 18.4, needsTier2: true, sourceCount: 1, depthProxy: 2,
    });
  });
  it("defaults missing/empty fields (a Swift rename → zeros here, not silently in the UI)", () => {
    const r = mapLibrarianReport({});
    expect(r).toEqual({ pages: 0, flagged: 0, stalest: [] });
    // a row missing documentID + a non-boolean needsTier2 default safely
    const r2 = mapLibrarianReport({ stalest: [{ staleness: 50 }] });
    expect(r2.stalest[0].documentID).toBe(0);
    expect(r2.stalest[0].volatility).toBe("warm");
    expect(r2.stalest[0].needsTier2).toBe(false);
  });
});

describe("mapAuditReport", () => {
  it("maps the exact Swift wire keys (pagesDetail/indirectlyDrifted/…)", () => {
    const r = mapAuditReport({
      pages: 3, drifted: 1, indirectlyDrifted: 1,
      pagesDetail: [{ id: 7, status: "drifted" }, { id: 3, status: "current" }],
    });
    expect(r.pages).toBe(3);
    expect(r.drifted).toBe(1);
    expect(r.indirectlyDrifted).toBe(1);
    expect(r.pagesDetail).toEqual([{ id: 7, status: "drifted" }, { id: 3, status: "current" }]);
  });
  it("defaults missing fields", () => {
    expect(mapAuditReport({})).toEqual({ pages: 0, drifted: 0, indirectlyDrifted: 0, pagesDetail: [] });
    expect(mapAuditReport({ pagesDetail: [{}] }).pagesDetail[0]).toEqual({ id: 0, status: "current" });
  });
});

describe("mapInventoryRecord", () => {
  it("maps wire keys + omits absent optionals", () => {
    const r = mapInventoryRecord({ slug: "rag", kind: "item", status: "active", priority: "p0", title: "RAG", summary: "s" });
    expect(r).toEqual({ slug: "rag", kind: "item", status: "active", priority: "p0", title: "RAG", summary: "s" });
    const bare = mapInventoryRecord({ slug: "x", kind: "item", status: "active", priority: "p2", title: "X" });
    expect(bare.summary).toBeUndefined();
    expect(bare.nextAction).toBeUndefined();
  });
  it("defaults missing string fields to empty", () => {
    expect(mapInventoryRecord({}).slug).toBe("");
  });
});

describe("mapDatasetManifest", () => {
  it("maps wire keys incl. optional numbers", () => {
    const d = mapDatasetManifest({ datasetID: "d1", title: "D1", status: "active", storage: "local", sizeBytes: 99, recordCount: 3 });
    expect(d).toEqual({ datasetID: "d1", title: "D1", status: "active", storage: "local", sizeBytes: 99, recordCount: 3 });
    const noNums = mapDatasetManifest({ datasetID: "d2", title: "D2", status: "external", storage: "remote" });
    expect(noNums.sizeBytes).toBeUndefined();
    expect(noNums.recordCount).toBeUndefined();
  });
});

describe("mapCollectCatalog", () => {
  it("maps slug + count, defaulting count to 0", () => {
    expect(mapCollectCatalog({ slug: "memes", count: 24 })).toEqual({ slug: "memes", count: 24 });
    expect(mapCollectCatalog({ slug: "empty" })).toEqual({ slug: "empty", count: 0 });
  });
});
