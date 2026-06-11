import { describe, it, expect } from "vitest";
import { parseFragment, extractHeadingSection, extractBlock, sliceForFragment } from "./transclude";

describe("parseFragment", () => {
  it("parses a bare title", () => {
    expect(parseFragment("My Page")).toEqual({ title: "My Page" });
  });
  it("parses a heading fragment", () => {
    expect(parseFragment("My Page#Intro")).toEqual({ title: "My Page", heading: "Intro" });
  });
  it("parses a block fragment", () => {
    expect(parseFragment("My Page#^abc123")).toEqual({ title: "My Page", block: "abc123" });
  });
});

describe("extractHeadingSection", () => {
  const body = [
    "# Top",
    "intro text",
    "## Alpha",
    "alpha body",
    "more alpha",
    "## Beta",
    "beta body",
    "### Beta Sub",
    "sub body",
    "# Another Top",
    "tail",
  ].join("\n");

  it("slices a section up to the next same-level heading", () => {
    expect(extractHeadingSection(body, "Alpha")).toBe("## Alpha\nalpha body\nmore alpha");
  });

  it("includes deeper subsections under the target", () => {
    expect(extractHeadingSection(body, "Beta")).toBe("## Beta\nbeta body\n### Beta Sub\nsub body");
  });

  it("a top-level heading runs to the next top-level heading", () => {
    expect(extractHeadingSection(body, "Top")).toContain("## Beta");
    expect(extractHeadingSection(body, "Top")).not.toContain("Another Top");
  });

  it("is case-insensitive", () => {
    expect(extractHeadingSection(body, "alpha")).toBe("## Alpha\nalpha body\nmore alpha");
  });

  it("returns null for a missing heading", () => {
    expect(extractHeadingSection(body, "Nope")).toBeNull();
  });
});

describe("extractBlock", () => {
  it("captures a paragraph ending with the inline block marker", () => {
    const body = "first para\n\nthe target line ^abc\n\nnext para";
    expect(extractBlock(body, "abc")).toBe("the target line");
  });

  it("captures a multi-line paragraph with a trailing marker line", () => {
    const body = "line one\nline two\n^xyz\n\nafter";
    expect(extractBlock(body, "xyz")).toBe("line one\nline two");
  });

  it("returns null when the block id is absent", () => {
    expect(extractBlock("no markers here", "ghost")).toBeNull();
  });
});

describe("sliceForFragment", () => {
  it("returns the whole body with no fragment", () => {
    expect(sliceForFragment("hello", { title: "P" })).toBe("hello");
  });
  it("returns null when a heading is requested but missing", () => {
    expect(sliceForFragment("hello", { title: "P", heading: "X" })).toBeNull();
  });
});
