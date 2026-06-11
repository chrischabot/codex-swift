import { describe, it, expect } from "vitest";
import { backlinksOf, propertyCatalog } from "./useWikiLinkIndex";
import type { WikiIndexEntry } from "@/runtime/connector";

const E = (
  id: string,
  title: string,
  links: string[] = [],
  props: Record<string, string> = {},
): WikiIndexEntry => ({ id, title, links, props });

// A tiny resolver: case-insensitive title → id over a fixed page set.
const PAGES: Record<string, string> = {
  "devrel metrics": "1",
  "ai safety": "2",
  "developer relations": "3",
};
const resolve = (t: string) => PAGES[t.trim().toLowerCase()];

describe("backlinksOf", () => {
  it("returns pages whose links resolve to the target, sorted by title", () => {
    const entries = [
      E("3", "Developer Relations", ["DevRel Metrics", "AI Safety"]),
      E("2", "AI Safety", ["DevRel Metrics"]),
      E("4", "Stray", ["Nonexistent"]),
    ];
    const bl = backlinksOf(entries, "1", resolve);
    expect(bl.map((b) => b.id)).toEqual(["2", "3"]); // AI Safety, Developer Relations
  });

  it("excludes self-links", () => {
    const entries = [E("1", "DevRel Metrics", ["DevRel Metrics"])];
    expect(backlinksOf(entries, "1", resolve)).toEqual([]);
  });

  it("ignores links that resolve nowhere", () => {
    const entries = [E("3", "Developer Relations", ["Ghost Page"])];
    expect(backlinksOf(entries, "1", resolve)).toEqual([]);
  });
});

describe("propertyCatalog", () => {
  it("aggregates keys with distinct values and page counts", () => {
    const entries = [
      E("1", "A", [], { status: "draft", area: "devrel" }),
      E("2", "B", [], { status: "done", area: "devrel" }),
      E("3", "C", [], { status: "draft" }),
    ];
    const cat = propertyCatalog(entries);
    const status = cat.find((k) => k.key === "status")!;
    expect(status.pageCount).toBe(3);
    expect(status.values).toEqual([
      { value: "draft", count: 2 },
      { value: "done", count: 1 },
    ]);
    const area = cat.find((k) => k.key === "area")!;
    expect(area.pageCount).toBe(2);
    expect(area.values).toEqual([{ value: "devrel", count: 2 }]);
  });

  it("sorts keys by page frequency (most-used first)", () => {
    const entries = [
      E("1", "A", [], { common: "x", rare: "y" }),
      E("2", "B", [], { common: "x" }),
    ];
    expect(propertyCatalog(entries).map((k) => k.key)).toEqual(["common", "rare"]);
  });

  it("returns an empty catalog when no page has props", () => {
    expect(propertyCatalog([E("1", "A", ["L"])])).toEqual([]);
  });
});
