import { describe, it, expect } from "vitest";
import { fuzzyMatch, fuzzyRank } from "./fuzzyRank";

describe("fuzzyMatch", () => {
  it("empty query matches anything at score 0", () => {
    expect(fuzzyMatch("", "anything")).toEqual({ score: 0, ranges: [] });
  });

  it("returns null when not all query chars are present in order", () => {
    expect(fuzzyMatch("xyz", "alpha beta")).toBeNull();
    expect(fuzzyMatch("ba", "alpha")).toBeNull(); // 'b' then 'a' not in order
  });

  it("matches a contiguous substring with its range", () => {
    const m = fuzzyMatch("pha", "alpha")!;
    expect(m).not.toBeNull();
    expect(m.ranges).toEqual([[2, 5]]);
  });

  it("ranks a prefix above a mid-string substring", () => {
    const prefix = fuzzyMatch("dev", "DevRel team")!;
    const mid = fuzzyMatch("dev", "Mobile DevRel")!;
    expect(prefix.score).toBeGreaterThan(mid.score);
  });

  it("ranks a word-boundary start above a non-boundary substring", () => {
    const boundary = fuzzyMatch("rel", "Dev Rel notes")!; // after a space
    const inside = fuzzyMatch("rel", "unrelated")!; // mid-word
    expect(boundary.score).toBeGreaterThan(inside.score);
  });

  it("falls back to a subsequence match across word boundaries", () => {
    // 'arp' -> AI R&D Pipeline initials-ish (subsequence)
    const m = fuzzyMatch("ard", "AI R&D")!;
    expect(m).not.toBeNull();
  });

  it("gently prefers shorter candidates on an equal substring", () => {
    const short = fuzzyMatch("ai", "AI")!;
    const long = fuzzyMatch("ai", "AI and the future of everything")!;
    expect(short.score).toBeGreaterThan(long.score);
  });
});

describe("fuzzyRank", () => {
  const items = ["DevRel Metrics", "AI Safety", "Developer Relations", "Mobile DevRel", "Random"];

  it("empty query returns list order up to the limit", () => {
    const r = fuzzyRank("", items, (x) => x, 3);
    expect(r.map((x) => x.item)).toEqual(["DevRel Metrics", "AI Safety", "Developer Relations"]);
  });

  it("ranks best matches first and drops non-matches", () => {
    const r = fuzzyRank("devrel", items, (x) => x);
    expect(r[0].item).toBe("DevRel Metrics"); // prefix wins
    expect(r.map((x) => x.item)).toContain("Mobile DevRel");
    expect(r.map((x) => x.item)).not.toContain("Random");
    expect(r.map((x) => x.item)).not.toContain("AI Safety");
  });

  it("respects the limit", () => {
    expect(fuzzyRank("e", items, (x) => x, 2)).toHaveLength(2);
  });
});
