import { describe, it, expect } from "vitest";
import { linkAtPosition } from "./sourceLinkNav";

describe("linkAtPosition", () => {
  it("finds a wikilink containing the offset", () => {
    const line = "see [[Other Page]] now";
    // offset inside "Other Page"
    const hit = linkAtPosition(line, 9);
    expect(hit).toEqual({ target: "Other Page", kind: "wiki" });
  });

  it("returns the full wiki target including a #heading suffix", () => {
    const line = "[[Notes#Section Two]]";
    const hit = linkAtPosition(line, 4);
    expect(hit).toEqual({ target: "Notes#Section Two", kind: "wiki" });
  });

  it("returns the full wiki target including a #^block suffix", () => {
    const line = "x [[Notes#^blk9]] y";
    const hit = linkAtPosition(line, 6);
    expect(hit).toEqual({ target: "Notes#^blk9", kind: "wiki" });
  });

  it("keeps the alias in the target for resolveWikilinkNav to parse", () => {
    const line = "[[Page|Pretty]]";
    const hit = linkAtPosition(line, 3);
    expect(hit).toEqual({ target: "Page|Pretty", kind: "wiki" });
  });

  it("finds a markdown link's url", () => {
    const line = "go [here](https://x.test/page) ok";
    const hit = linkAtPosition(line, 5);
    expect(hit).toEqual({ target: "https://x.test/page", kind: "markdown" });
  });

  it("returns null when the offset is outside any link", () => {
    const line = "plain text [[Link]] here";
    expect(linkAtPosition(line, 2)).toBeNull(); // in "plain"
    expect(linkAtPosition(line, 22)).toBeNull(); // in "here"
  });

  it("prefers a wikilink over a markdown link when both exist on the line", () => {
    const line = "[[Wiki]] and [md](url)";
    expect(linkAtPosition(line, 3)).toEqual({ target: "Wiki", kind: "wiki" });
    expect(linkAtPosition(line, 16)).toEqual({ target: "url", kind: "markdown" });
  });

  it("matches at the inclusive boundaries of a token", () => {
    const line = "[[A]]";
    expect(linkAtPosition(line, 0)).toEqual({ target: "A", kind: "wiki" });
    expect(linkAtPosition(line, 5)).toEqual({ target: "A", kind: "wiki" });
  });
});
