import { describe, it, expect } from "vitest";
import { evalFormula } from "./formula";

const scope = (props: Record<string, unknown>) => (name: string) => props[name];

describe("evalFormula", () => {
  const s = scope({ a: 3, b: 4, status: "Draft", title: "Hello", done: true, tags: ["x", "y"] });

  it("evaluates arithmetic with precedence", () => {
    expect(evalFormula("a + b * 2", s).value).toBe(11);
    expect(evalFormula("(a + b) * 2", s).value).toBe(14);
  });

  it("resolves bracketed identifiers with spaces", () => {
    const s2 = scope({ "due date": 5 });
    expect(evalFormula("{due date} + 1", s2).value).toBe(6);
  });

  it("concatenates when a side is a string", () => {
    expect(evalFormula('title + "!"', s).value).toBe("Hello!");
    expect(evalFormula('"n=" + a', s).value).toBe("n=3");
  });

  it("comparisons and logical operators", () => {
    expect(evalFormula("a < b", s).value).toBe(true);
    expect(evalFormula("a > b || done", s).value).toBe(true);
    expect(evalFormula("a > b && done", s).value).toBe(false);
  });

  it("ternary", () => {
    expect(evalFormula('a > b ? "hi" : "lo"', s).value).toBe("lo");
  });

  it("loose equality is case-insensitive for strings, numeric for numbers", () => {
    expect(evalFormula('status == "draft"', s).value).toBe(true);
    expect(evalFormula("a == 3", s).value).toBe(true);
    expect(evalFormula("a != 3", s).value).toBe(false);
  });

  it("functions: if / round / concat / len / coalesce / contains", () => {
    expect(evalFormula('if(done, "yes", "no")', s).value).toBe("yes");
    expect(evalFormula("round(10 / 3, 2)", s).value).toBe(3.33);
    expect(evalFormula('concat(title, "-", a)', s).value).toBe("Hello-3");
    expect(evalFormula("len(title)", s).value).toBe(5);
    expect(evalFormula("coalesce(missing, a)", s).value).toBe(3);
    expect(evalFormula('contains(status, "raf")', s).value).toBe(true);
  });

  it("arrays coerce to comma strings in refs", () => {
    expect(evalFormula("tags", s).value).toBe("x, y");
  });

  it("unknown identifiers resolve to null (blank), not an error", () => {
    expect(evalFormula("missing", s)).toEqual({ value: null, error: null });
  });

  it("NaN normalizes to null so the cell renders blank", () => {
    expect(evalFormula('"x" * 2', s).value).toBeNull();
  });

  it("returns an error string on a parse failure (never throws)", () => {
    expect(evalFormula("a +", s).error).toBeTruthy();
    expect(evalFormula("a + )", s).error).toBeTruthy();
    expect(evalFormula("bogus(a)", s).error).toContain("unknown function");
  });

  it("an empty formula is null with no error", () => {
    expect(evalFormula("   ", s)).toEqual({ value: null, error: null });
  });

  it("cannot reach the host (no eval): identifiers are scope-only", () => {
    // `constructor` is just an unknown property name → null, not a function.
    expect(evalFormula("constructor", s).value).toBeNull();
  });
});
