import { describe, it, expect } from "vitest";
import { parseWikilinkInner, findWikilinks } from "./wikiLinks";

describe("parseWikilinkInner", () => {
  it("parses a bare target", () => {
    expect(parseWikilinkInner("My Page")).toEqual({ target: "My Page" });
  });
  it("splits an alias on |", () => {
    expect(parseWikilinkInner("My Page|the page")).toEqual({ target: "My Page", alias: "the page" });
  });
  it("splits a #heading", () => {
    expect(parseWikilinkInner("My Page#Intro")).toEqual({ target: "My Page", heading: "Intro" });
  });
  it("splits a #^block", () => {
    expect(parseWikilinkInner("My Page#^abc")).toEqual({ target: "My Page", block: "abc" });
  });
  it("handles alias + heading together", () => {
    expect(parseWikilinkInner("Page#Sec|alias")).toEqual({ target: "Page", heading: "Sec", alias: "alias" });
  });
  it("trims all parts", () => {
    expect(parseWikilinkInner("  Page  #  Sec  |  alias  ")).toEqual({
      target: "Page",
      heading: "Sec",
      alias: "alias",
    });
  });
});

describe("findWikilinks", () => {
  it("finds every link with display/embed/line, skipping fenced code", () => {
    const md = "see [[A]] and ![[B|bee]]\n```\n[[C]]\n```\n[[D#Sec]]";
    const found = findWikilinks(md);
    expect(found.map((f) => f.target)).toEqual(["A", "B", "D"]); // C is in a code fence
    const b = found.find((f) => f.target === "B")!;
    expect(b.display).toBe("bee");
    expect(b.embed).toBe(true);
    const a = found.find((f) => f.target === "A")!;
    expect(a.display).toBe("A"); // no alias → display = target
    expect(a.embed).toBe(false);
    expect(a.line).toBe(0);
    const d = found.find((f) => f.target === "D")!;
    expect(d.heading).toBe("Sec");
    expect(d.line).toBe(4);
  });

  it("ignores inline-code wikilinks", () => {
    expect(findWikilinks("text `[[X]]` more").map((f) => f.target)).toEqual([]);
  });
});
