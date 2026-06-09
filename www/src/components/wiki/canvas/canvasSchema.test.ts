import { describe, it, expect } from "vitest";
import {
  parseCanvasDoc,
  serializeCanvasDoc,
  isCanvasDoc,
  normalizeCanvas,
  emptyCanvasBody,
  EMPTY_CANVAS,
  type Canvas,
} from "./canvasSchema";

// CLAIM: a canvas is a wiki document (frontmatter `wiki_type: canvas` + JSON
// body). parse/serialize must round-trip; isCanvasDoc must NOT hijack a prose
// page that merely carries the marker (which would let the board overwrite the
// prose on first edit). SEVERITY: severe — misrouting is silent data loss.

const SAMPLE: Canvas = {
  nodes: [
    { id: "n1", type: "text", x: 0, y: 0, w: 200, h: 100, text: "hello **world**" },
    { id: "n2", type: "page", x: 300, y: 50, w: 180, h: 90, pageId: "42", label: "A page" },
    { id: "n3", type: "group", x: -100, y: -100, w: 400, h: 400, label: "Group", color: "3" },
    { id: "n4", type: "link", x: 10, y: 500, w: 160, h: 60, url: "https://example.com" },
  ],
  edges: [
    { id: "e1", fromNode: "n1", toNode: "n2", fromSide: "right", toSide: "left", label: "rel" },
  ],
};

describe("canvasSchema round-trip", () => {
  it("serialize → parse is identity for a populated canvas", () => {
    const body = serializeCanvasDoc(SAMPLE);
    const { canvas } = parseCanvasDoc(body);
    expect(canvas.nodes).toEqual(SAMPLE.nodes);
    expect(canvas.edges).toEqual(SAMPLE.edges);
  });

  it("emptyCanvasBody parses back to an empty canvas and is detected as a canvas", () => {
    const body = emptyCanvasBody();
    expect(isCanvasDoc(body)).toBe(true);
    const { canvas } = parseCanvasDoc(body);
    expect(canvas).toEqual(EMPTY_CANVAS);
  });

  it("preserves extra frontmatter keys through a serialize round-trip", () => {
    const body = serializeCanvasDoc(SAMPLE, { aliases: "Board One", custom: "x" });
    // re-detect + the extra keys survive in the raw body text
    expect(isCanvasDoc(body)).toBe(true);
    expect(body).toContain("aliases: Board One");
    expect(body).toContain("custom: x");
    expect(body).toContain("wiki_type: canvas");
  });
});

describe("isCanvasDoc hardening (anti-misrouting)", () => {
  it("is false for plain prose with no frontmatter", () => {
    expect(isCanvasDoc("# A note\n\nSome prose.")).toBe(false);
  });

  it("is FALSE for a prose page that merely carries a wiki_type: canvas marker", () => {
    // The body is prose, not canvas JSON — must NOT route to the board view
    // (which would overwrite the prose on first edit).
    const trap = "---\nwiki_type: canvas\n---\n# Documenting the canvas format\n\nProse here.";
    expect(isCanvasDoc(trap)).toBe(false);
  });

  it("is false when the marker is present but the body is not a JSON object", () => {
    expect(isCanvasDoc("---\nwiki_type: canvas\n---\n[1,2,3]")).toBe(false);
    expect(isCanvasDoc("---\nwiki_type: canvas\n---\nnot json")).toBe(false);
  });

  it("is true only when the marker AND a canvas JSON body are present", () => {
    expect(isCanvasDoc('---\nwiki_type: canvas\n---\n{"nodes":[],"edges":[]}')).toBe(true);
  });

  it("is false for null/empty", () => {
    expect(isCanvasDoc(null)).toBe(false);
    expect(isCanvasDoc("")).toBe(false);
    expect(isCanvasDoc(undefined)).toBe(false);
  });
});

describe("normalizeCanvas resilience", () => {
  it("drops malformed nodes/edges instead of throwing", () => {
    const messy = normalizeCanvas({
      nodes: [
        { id: "ok", type: "text", x: 1, y: 2, w: 3, h: 4 },
        { id: "", type: "text", x: 0, y: 0, w: 1, h: 1 }, // empty id
        { type: "text", x: 0, y: 0, w: 1, h: 1 }, // missing id
        null,
        "garbage",
      ],
      edges: [
        { id: "e", fromNode: "ok", toNode: "ok" },
        { id: "", fromNode: "ok", toNode: "ok" }, // empty id
        { id: "e2", fromNode: "ok" }, // missing toNode
      ],
    });
    expect(messy.nodes.map((n) => n.id)).toEqual(["ok"]);
    expect(messy.edges.map((e) => e.id)).toEqual(["e"]);
  });

  it("returns an empty canvas for non-object input", () => {
    expect(normalizeCanvas(null)).toEqual(EMPTY_CANVAS);
    expect(normalizeCanvas("nope")).toEqual(EMPTY_CANVAS);
    expect(normalizeCanvas(42)).toEqual(EMPTY_CANVAS);
  });
});
