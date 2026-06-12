import { describe, it, expect } from "vitest";
import { parseFootnotes } from "./WikiOutlinePanel";

describe("parseFootnotes", () => {
  it("parses footnote definitions with their rendered anchor id", () => {
    const md = "Body with a ref[^1].\n\n[^1]: The first note.\n[^note]: A named note.";
    expect(parseFootnotes(md)).toEqual([
      { id: "1", text: "The first note.", anchorId: "user-content-fn-1" },
      { id: "note", text: "A named note.", anchorId: "user-content-fn-note" },
    ]);
  });

  it("strips inline markdown from the definition text", () => {
    const md = "[^1]: see [[Page|alias]] and `code` and **bold**";
    expect(parseFootnotes(md)[0].text).toBe("see alias and code and bold");
  });

  it("ignores definitions inside fenced code", () => {
    const md = "```\n[^1]: not a footnote\n```\n[^2]: a real one";
    expect(parseFootnotes(md).map((f) => f.id)).toEqual(["2"]);
  });

  it("de-dupes a repeated label and falls back when text is empty", () => {
    const md = "[^x]:\n[^x]: second wins? no — first kept";
    const fns = parseFootnotes(md);
    expect(fns).toHaveLength(1);
    expect(fns[0].text).toBe("Footnote x");
  });

  it("returns nothing when there are no definitions", () => {
    expect(parseFootnotes("just a [^1] reference, no definition")).toEqual([]);
  });
});
