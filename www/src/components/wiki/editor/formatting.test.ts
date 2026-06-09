import { describe, it, expect } from "vitest";
import { EditorState, EditorSelection } from "@codemirror/state";
import { wrapToggle, wrapWikilink, toggleLinePrefix, wrapRange } from "./formatting";

// Render a result as a string with the selection marked by │…│ for readability.
function show(r: { text: string; from: number; to: number }): string {
  return r.text.slice(0, r.from) + "│" + r.text.slice(r.from, r.to) + "│" + r.text.slice(r.to);
}

describe("wrapToggle (bold/italic/code)", () => {
  it("wraps a selection and keeps the inner text selected", () => {
    // "hello [world]" → bold the word
    const r = wrapToggle("hello world", 6, 11, "**");
    expect(r.text).toBe("hello **world**");
    expect(show(r)).toBe("hello **│world│**");
  });

  it("unwraps when the selection is already wrapped (markers inside)", () => {
    const r = wrapToggle("a **bold** b", 2, 10, "**"); // selects "**bold**"
    expect(r.text).toBe("a bold b");
    expect(show(r)).toBe("a │bold│ b");
  });

  it("unwraps when the markers sit just OUTSIDE the selection", () => {
    const r = wrapToggle("a **bold** b", 4, 8, "**"); // selects "bold"
    expect(r.text).toBe("a bold b");
    expect(show(r)).toBe("a │bold│ b");
  });

  it("inserts empty markers with the caret between for a collapsed selection", () => {
    const r = wrapToggle("ab", 1, 1, "**");
    expect(r.text).toBe("a****b");
    expect(r.from).toBe(3);
    expect(r.to).toBe(3); // caret between the ** pairs
  });

  it("supports single-char markers (italic, code)", () => {
    expect(wrapToggle("x", 0, 1, "*").text).toBe("*x*");
    expect(wrapToggle("x", 0, 1, "`").text).toBe("`x`");
  });

  it("round-trips: wrap then unwrap returns the original", () => {
    const wrapped = wrapToggle("the word here", 4, 8, "**"); // "word"
    expect(wrapped.text).toBe("the **word** here");
    const unwrapped = wrapToggle(wrapped.text, wrapped.from, wrapped.to, "**");
    expect(unwrapped.text).toBe("the word here");
  });

  it("italicizing already-bold text WRAPS (does not strip a * off the **)", () => {
    // "**bold**", select "bold" (2..6), apply italic `*` → ***bold*** (not *bold*)
    const r = wrapToggle("**bold**", 2, 6, "*");
    expect(r.text).toBe("**" + "*bold*" + "**");
    expect(r.text).toBe("***bold***");
  });

  it("bolding inside bold still unwraps (markers-outside, same marker)", () => {
    const r = wrapToggle("**bold**", 2, 6, "**");
    expect(r.text).toBe("bold");
  });
});

describe("wrapWikilink", () => {
  it("wraps a selection in [[ ]]", () => {
    const r = wrapWikilink("see Foo bar", 4, 7); // "Foo"
    expect(r.text).toBe("see [[Foo]] bar");
    expect(show(r)).toBe("see [[│Foo│]] bar");
  });
  it("inserts [[]] with the caret inside for a collapsed selection", () => {
    const r = wrapWikilink("x", 1, 1);
    expect(r.text).toBe("x[[]]");
    expect(r.from).toBe(3);
  });
});

describe("wrapRange — multi-cursor via changeByRange", () => {
  const mkState = (doc: string, ranges: Array<[number, number]>) =>
    EditorState.create({
      doc,
      selection: EditorSelection.create(ranges.map(([a, b]) => EditorSelection.range(a, b))),
      extensions: [EditorState.allowMultipleSelections.of(true)],
    });

  it("wraps EVERY selection range (not just the main one)", () => {
    // The CRITICAL bug: a full-doc replace wrapped only selection.main and
    // collapsed the other cursors. changeByRange must wrap both.
    const state = mkState("foo bar", [[0, 3], [4, 7]]);
    const next = state.update(state.changeByRange((r) => wrapRange(state, r, "**", "**"))).state;
    expect(next.doc.toString()).toBe("**foo** **bar**");
    expect(next.selection.ranges).toHaveLength(2);
  });

  it("only edits the wrapped spans (text outside the selections is untouched)", () => {
    const state = mkState("a foo b bar c", [[2, 5], [8, 11]]);
    const next = state.update(state.changeByRange((r) => wrapRange(state, r, "*", "*"))).state;
    expect(next.doc.toString()).toBe("a *foo* b *bar* c");
  });
});

describe("toggleLinePrefix (headings / quote / bullet)", () => {
  it("adds a heading prefix to the current line", () => {
    const r = toggleLinePrefix("title\nbody", 0, 0, "## ");
    expect(r.text).toBe("## title\nbody");
  });

  it("removes the prefix when the line already has it (toggle off)", () => {
    const r = toggleLinePrefix("## title\nbody", 0, 0, "## ");
    expect(r.text).toBe("title\nbody");
  });

  it("replaces a different heading level (mutually exclusive)", () => {
    const r = toggleLinePrefix("# title", 0, 0, "### ");
    expect(r.text).toBe("### title");
  });

  it("applies to every line a multi-line selection touches", () => {
    const r = toggleLinePrefix("a\nb\nc", 0, 5, "> ");
    expect(r.text).toBe("> a\n> b\n> c");
  });

  it("toggles a multi-line block off when all lines have the prefix", () => {
    const r = toggleLinePrefix("- a\n- b", 0, 7, "- ");
    expect(r.text).toBe("a\nb");
  });

  it("does NOT double-add a prefix to lines that already have it (mixed block)", () => {
    // "- a\nb" → bullet → "- a\n- b" (the already-bulleted line is left alone)
    const r = toggleLinePrefix("- a\nb", 0, 5, "- ");
    expect(r.text).toBe("- a\n- b");
  });

  it("replaces an existing heading level on every line (mixed levels)", () => {
    const r = toggleLinePrefix("# a\n### b", 0, 9, "## ");
    expect(r.text).toBe("## a\n## b");
  });

  it("toggles a heading block off regardless of level", () => {
    const r = toggleLinePrefix("## a\n## b", 0, 9, "## ");
    expect(r.text).toBe("a\nb");
  });
});
