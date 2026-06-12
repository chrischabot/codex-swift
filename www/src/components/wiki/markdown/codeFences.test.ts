import { describe, it, expect } from "vitest";
import { maskFencedCode } from "./codeFences";

describe("maskFencedCode", () => {
  it("blanks fenced ``` code regions, length-preserving", () => {
    const md = "before\n```\n[[X]]\ncode\n```\nafter";
    expect(maskFencedCode(md)).toEqual(["before", "", "", "", "", "after"]);
  });

  it("blanks ~~~ fences and is not closed by a ``` fence", () => {
    const md = "~~~\n```\nstill code\n~~~\nout";
    // open ~~~; ``` does not close it; ~~~ closes; then "out"
    expect(maskFencedCode(md)).toEqual(["", "", "", "", "out"]);
  });

  it("blanks inline code by default (length-preserving)", () => {
    expect(maskFencedCode("a `code` b")).toEqual(["a        b"]);
  });

  it("preserves inline code when inlineCode:false", () => {
    expect(maskFencedCode("## API `v2`", { inlineCode: false })).toEqual(["## API `v2`"]);
  });

  it("preserves line count so indices survive", () => {
    const md = "l0\nl1\nl2";
    expect(maskFencedCode(md)).toHaveLength(3);
  });
});
