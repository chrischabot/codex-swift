import { describe, it, expect } from "vitest";
import {
  parseGraphQuery,
  nodeMatchesQuery,
  nodePassesFilter,
  resolveGroupColor,
  type GraphColorGroup,
  type GraphFilterNode,
} from "./GraphControls";

const node = (title: string, kind?: string): GraphFilterNode => ({ title, kind });
const group = (query: string, color: string, id = query): GraphColorGroup => ({ id, query, color });

describe("parseGraphQuery", () => {
  it("treats plain text as a lower-cased label query", () => {
    expect(parseGraphQuery("  Ada  ")).toEqual({ mode: "label", term: "ada" });
  });
  it("recognises a kind: prefix (case-insensitive) and trims the remainder", () => {
    expect(parseGraphQuery("KIND: Person ")).toEqual({ mode: "kind", term: "person" });
  });
  it("parses a bare kind: into an empty kind term", () => {
    expect(parseGraphQuery("kind:")).toEqual({ mode: "kind", term: "" });
  });
});

describe("nodeMatchesQuery — label mode", () => {
  it("matches a case-insensitive substring of the title", () => {
    expect(nodeMatchesQuery(node("Ada Lovelace"), parseGraphQuery("lovel"))).toBe(true);
  });
  it("does not match a non-substring", () => {
    expect(nodeMatchesQuery(node("Ada Lovelace"), parseGraphQuery("turing"))).toBe(false);
  });
  it("an empty label term matches everything", () => {
    expect(nodeMatchesQuery(node("anything"), parseGraphQuery(""))).toBe(true);
  });
  it("a label query never accidentally matches against the kind", () => {
    expect(nodeMatchesQuery(node("Ada", "person"), parseGraphQuery("person"))).toBe(false);
  });
});

describe("nodeMatchesQuery — kind mode", () => {
  it("matches a substring of the node kind", () => {
    expect(nodeMatchesQuery(node("Ada", "person"), parseGraphQuery("kind:person"))).toBe(true);
    expect(nodeMatchesQuery(node("Ada", "person"), parseGraphQuery("kind:per"))).toBe(true);
  });
  it("is case-insensitive on the kind", () => {
    expect(nodeMatchesQuery(node("Ada", "Person"), parseGraphQuery("kind:PERSON"))).toBe(true);
  });
  it("a node with no kind never matches a kind query", () => {
    expect(nodeMatchesQuery(node("Ada"), parseGraphQuery("kind:person"))).toBe(false);
    expect(nodeMatchesQuery(node("Ada"), parseGraphQuery("kind:"))).toBe(false);
  });
  it("a bare kind: matches any node that HAS a kind", () => {
    expect(nodeMatchesQuery(node("Ada", "org"), parseGraphQuery("kind:"))).toBe(true);
  });
  it("does not match a different kind", () => {
    expect(nodeMatchesQuery(node("Ada", "org"), parseGraphQuery("kind:person"))).toBe(false);
  });
});

describe("nodePassesFilter", () => {
  it("an empty / whitespace filter passes every node", () => {
    expect(nodePassesFilter(node("Ada", "person"), "")).toBe(true);
    expect(nodePassesFilter(node("Ada", "person"), "   ")).toBe(true);
  });
  it("filters by label substring", () => {
    expect(nodePassesFilter(node("Ada Lovelace"), "ada")).toBe(true);
    expect(nodePassesFilter(node("Charles Babbage"), "ada")).toBe(false);
  });
  it("filters by kind: prefix", () => {
    expect(nodePassesFilter(node("Ada", "person"), "kind:person")).toBe(true);
    expect(nodePassesFilter(node("OpenAI", "org"), "kind:person")).toBe(false);
  });
});

describe("resolveGroupColor", () => {
  const groups = [
    group("kind:person", "#blue"),
    group("ada", "#green"),
  ];

  it("returns null when no group matches", () => {
    expect(resolveGroupColor(node("OpenAI", "org"), groups)).toBeNull();
  });
  it("returns the matching group's color", () => {
    expect(resolveGroupColor(node("Babbage", "person"), groups)).toBe("#blue");
  });
  it("first matching group wins (array order), not most specific", () => {
    // "Ada" is a person AND matches the label group — the kind:person group is
    // earlier, so it wins.
    expect(resolveGroupColor(node("Ada", "person"), groups)).toBe("#blue");
    // Reorder: label group first now wins.
    const reordered = [group("ada", "#green"), group("kind:person", "#blue")];
    expect(resolveGroupColor(node("Ada", "person"), reordered)).toBe("#green");
  });
  it("skips groups with an empty / whitespace query (half-typed CRUD rows)", () => {
    const withEmpty = [group("", "#orange"), group("ada", "#green")];
    expect(resolveGroupColor(node("Ada"), withEmpty)).toBe("#green");
    // A node that only the empty group would have "matched" stays uncolored.
    expect(resolveGroupColor(node("Babbage"), withEmpty)).toBeNull();
  });
  it("returns null for an empty group list", () => {
    expect(resolveGroupColor(node("Ada", "person"), [])).toBeNull();
  });
});
