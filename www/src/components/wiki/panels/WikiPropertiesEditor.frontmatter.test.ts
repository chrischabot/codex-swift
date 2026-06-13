import { describe, it, expect } from "vitest";
import { splitFrontmatter, parseSegments, serialize } from "./frontmatterModel";

// These suites lock in the CRITICAL data-loss fixes for the frontmatter editor.
// CLAIM: parse → serialize is byte-for-byte verbatim for any unedited doc, and
// editing one property never disturbs another construct (block scalars, folded
// scalars, flow maps, comments, lists, quoted scalars). SEVERITY: severe.

/** Full parse → serialize with no edits — must reproduce the input exactly. */
function roundTrip(content: string): string {
  const split = splitFrontmatter(content);
  const { segments } = parseSegments(split.yamlText);
  return serialize(segments, split.body, split.newline, split.endFence);
}

describe("splitFrontmatter", () => {
  it("detects LF newline + --- fence", () => {
    const s = splitFrontmatter("---\na: 1\n---\nbody\n");
    expect(s.newline).toBe("\n");
    expect(s.endFence).toBe("---");
    expect(s.yamlText).toBe("a: 1");
    expect(s.body).toBe("body\n");
  });

  it("takes newline from the OPENING fence, not a stray CRLF in the body", () => {
    // An LF fence with a CRLF line in the body must STILL be recognized — the
    // old global detection forced a \r\n end-marker that never matched.
    const content = "---\na: 1\n---\nbody win\r\nend\n";
    const s = splitFrontmatter(content);
    expect(s.newline).toBe("\n");
    expect(s.yamlText).toBe("a: 1");
    expect(s.body).toBe("body win\r\nend\n");
  });

  it("recognizes the YAML document-end `...` fence and records it", () => {
    const s = splitFrontmatter("---\na: 1\n...\nbody\n");
    expect(s.endFence).toBe("...");
    expect(s.yamlText).toBe("a: 1");
    expect(s.body).toBe("body\n");
  });

  it("handles a CRLF document end-to-end", () => {
    const s = splitFrontmatter("---\r\na: 1\r\n---\r\nbody\r\n");
    expect(s.newline).toBe("\r\n");
    expect(s.yamlText).toBe("a: 1");
  });

  it("treats a doc with no frontmatter as all body", () => {
    const s = splitFrontmatter("# just a note\n");
    expect(s.yamlText).toBeNull();
    expect(s.body).toBe("# just a note\n");
  });

  it("accepts an EOF closing fence (no trailing newline)", () => {
    const s = splitFrontmatter("---\na: 1\n---");
    expect(s.yamlText).toBe("a: 1");
    expect(s.body).toBe("");
  });
});

describe("verbatim round-trip (no edits)", () => {
  const cases: Record<string, string> = {
    "simple scalars": "---\ntitle: Hello\nn: 42\n---\nBody.\n",
    "block scalar |": "---\nnote: |\n  line one\n  line two\n    deeper\n---\nbody\n",
    "folded scalar >": "---\nfolded: >\n  wrap a\n  wrap b\n---\nbody\n",
    "inline flow map": "---\nconfig: {a: 1, b: 2}\n---\nbody\n",
    "standalone comment": "---\n# a comment\nk: v\n---\nbody\n",
    "block list": "---\ntags:\n  - alpha\n  - beta\n---\nbody\n",
    "quoted scalars": '---\nq: "hi: there"\ns: \'a\'\'b\'\n---\nbody\n',
    "leading-zero string": '---\nticket: "007"\n---\nbody\n',
    "dots fence": "---\na: 1\nnote: |\n  blk\n...\nbody\n",
    "leading-whitespace body": "---\na: 1\n---\n\n    indented code\nplain\n",
    "crlf body line": "---\na: 1\n---\nwin\r\nend\n",
    "all combined": "---\ntitle: T\nticket: \"007\"\nconfig: {a: 1}\n# c\nnote: |\n  b1\n  b2\ntags:\n  - x\nedit: me\n...\n\n    indented\nwin\r\nend\n",
  };
  for (const [name, content] of Object.entries(cases)) {
    it(`reproduces "${name}" byte-for-byte`, () => {
      expect(roundTrip(content)).toBe(content);
    });
  }
});

describe("edit-path: changing one property preserves everything else", () => {
  it("edits a scalar while leaving block scalar, flow map, comment, list intact", () => {
    const content =
      "---\ntitle: T\nticket: \"007\"\nconfig: {a: 1}\n# c\nnote: |\n  b1\n  b2\ntags:\n  - x\nedit: me\n...\n\n    indented\nwin\r\nend\n";
    const split = splitFrontmatter(content);
    const { segments } = parseSegments(split.yamlText);
    // Mutate the `edit` row's scalar value.
    const row = segments.find((s) => s.kind === "row" && (s as { key?: string }).key === "edit") as
      | { kind: "row"; raw: string }
      | undefined;
    expect(row).toBeTruthy();
    row!.raw = "changed";
    const out = serialize(segments, split.body, split.newline, split.endFence);

    expect(out).toContain("edit: changed");
    expect(out).not.toContain("edit: me");
    // Every other construct survives byte-identically.
    expect(out).toContain('ticket: "007"');
    expect(out).toContain("config: {a: 1}");
    expect(out).toContain("# c");
    expect(out).toContain("note: |\n  b1\n  b2");
    expect(out).toContain("tags:\n  - x");
    expect(out).toContain("\n...\n"); // dots fence preserved
    expect(out).toContain("    indented"); // body indentation preserved
    expect(out).toContain("win\r\nend"); // CRLF body preserved
  });
});
