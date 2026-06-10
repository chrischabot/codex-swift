import { describe, it, expect } from "vitest";
import { compareNodes, type SortableNode } from "./sort";
import type { WikiPageSummary } from "@/runtime/connector";

// Locks in M33 explorer sort ordering: folders always lead files; files honour
// the four modes; undated pages sink under the date modes; ties break by label.

function file(label: string, updatedAt?: number): SortableNode {
  const page: WikiPageSummary = { id: label, title: label, updatedAt };
  return { type: "file", label, page };
}
function folder(label: string): SortableNode {
  return { type: "folder", label };
}

function sorted(nodes: SortableNode[], mode: Parameters<typeof compareNodes>[2]): string[] {
  return [...nodes].sort((a, b) => compareNodes(a, b, mode)).map((n) => n.label);
}

describe("compareNodes — folders before files", () => {
  it("keeps folders ahead of files in every mode", () => {
    const nodes = [file("a"), folder("z"), file("b"), folder("m")];
    for (const mode of ["name-asc", "name-desc", "date-newest", "date-oldest"] as const) {
      const out = sorted(nodes, mode);
      const firstFile = out.findIndex((l) => l === "a" || l === "b");
      const lastFolder = Math.max(out.indexOf("z"), out.indexOf("m"));
      expect(lastFolder).toBeLessThan(firstFile);
    }
  });

  it("folders stay alphabetical regardless of mode (no date)", () => {
    const nodes = [folder("Zebra"), folder("apple"), folder("Mango")];
    expect(sorted(nodes, "date-newest")).toEqual(["apple", "Mango", "Zebra"]);
    expect(sorted(nodes, "name-desc")).toEqual(["apple", "Mango", "Zebra"]);
  });
});

describe("compareNodes — name modes", () => {
  it("name-asc is case-insensitive A→Z", () => {
    expect(sorted([file("banana"), file("Apple"), file("cherry")], "name-asc")).toEqual([
      "Apple",
      "banana",
      "cherry",
    ]);
  });
  it("name-desc reverses to Z→A", () => {
    expect(sorted([file("banana"), file("Apple"), file("cherry")], "name-desc")).toEqual([
      "cherry",
      "banana",
      "Apple",
    ]);
  });
});

describe("compareNodes — date modes", () => {
  it("date-newest puts the highest updatedAt first", () => {
    expect(
      sorted([file("old", 100), file("new", 300), file("mid", 200)], "date-newest"),
    ).toEqual(["new", "mid", "old"]);
  });
  it("date-oldest reverses", () => {
    expect(
      sorted([file("old", 100), file("new", 300), file("mid", 200)], "date-oldest"),
    ).toEqual(["old", "mid", "new"]);
  });
  it("undated pages sink to the bottom in BOTH directions", () => {
    expect(sorted([file("dated", 100), file("undated")], "date-newest")).toEqual([
      "dated",
      "undated",
    ]);
    expect(sorted([file("dated", 100), file("undated")], "date-oldest")).toEqual([
      "dated",
      "undated",
    ]);
  });
  it("equal dates break the tie by label", () => {
    expect(sorted([file("b", 100), file("a", 100)], "date-newest")).toEqual(["a", "b"]);
  });
});
