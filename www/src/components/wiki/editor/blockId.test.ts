import { describe, it, expect } from "vitest";
import { generateBlockId, planBlockIdInsert } from "./blockId";

describe("generateBlockId", () => {
  it("produces a 6-char lowercased-alphanumeric id", () => {
    const id = generateBlockId(() => 0);
    expect(id).toMatch(/^[a-z0-9]{6}$/);
  });

  it("is deterministic for a fixed rng", () => {
    const rng = () => 0; // always first alphabet char ('a')
    expect(generateBlockId(rng)).toBe("aaaaaa");
  });

  it("walks the alphabet with a stepping rng", () => {
    // rng just under 1 → last char ('9'); a fixed near-1 value picks '9' each time.
    expect(generateBlockId(() => 0.999)).toBe("999999");
  });
});

describe("planBlockIdInsert", () => {
  it("appends ` ^id` at the end of a single-line doc", () => {
    const plan = planBlockIdInsert("hello world", 3, "abc123");
    expect(plan).not.toBeNull();
    expect(plan!.at).toBe(11);
    expect(plan!.insert).toBe(" ^abc123");
    expect(plan!.caret).toBe(11 + " ^abc123".length);
  });

  it("appends at the END of the cursor's line, not the doc", () => {
    const text = "first line\nsecond line\nthird";
    // cursor inside "first line" (offset 3)
    const plan = planBlockIdInsert(text, 3, "id0001");
    expect(plan).not.toBeNull();
    // end of "first line" is offset 10
    expect(plan!.at).toBe(10);
    expect(plan!.insert).toBe(" ^id0001");
  });

  it("omits the leading space on a blank line", () => {
    const text = "para\n\nmore";
    // cursor on the empty line (offset 5)
    const plan = planBlockIdInsert(text, 5, "blk999");
    expect(plan).not.toBeNull();
    expect(plan!.at).toBe(5);
    expect(plan!.insert).toBe("^blk999");
  });

  it("trims trailing whitespace before appending", () => {
    const plan = planBlockIdInsert("text   ", 2, "abcdef");
    expect(plan).not.toBeNull();
    expect(plan!.at).toBe(4); // end of "text"
    expect(plan!.insert).toBe(" ^abcdef");
  });

  it("refuses to stack a second id on a line that already has one", () => {
    expect(planBlockIdInsert("done ^existing", 2, "newid1")).toBeNull();
    expect(planBlockIdInsert("done ^existing   ", 2, "newid1")).toBeNull();
  });

  it("does not treat a bare `^foo` without leading space as a block id", () => {
    // `^foo` glued to the word is NOT a block id per BLOCK_ID_RE (needs space).
    const plan = planBlockIdInsert("word^foo", 2, "abc123");
    expect(plan).not.toBeNull();
    expect(plan!.insert).toBe(" ^abc123");
  });
});
