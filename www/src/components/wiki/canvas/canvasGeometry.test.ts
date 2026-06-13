import { describe, it, expect } from "vitest";
import {
  GRID,
  snap,
  sideAnchor,
  nearestSide,
  rectsIntersect,
  colorRgb,
  edgePath,
  edgeMidpoint,
  edgeStroke,
} from "./canvasGeometry";
import type { CanvasNode, CanvasEdge } from "./canvasSchema";

const node = (x: number, y: number, w = 100, h = 60): CanvasNode =>
  ({ id: "n", type: "text", x, y, w, h }) as CanvasNode;

describe("snap", () => {
  it("snaps to the grid when on, to the integer when off", () => {
    expect(snap(27, true)).toBe(GRID * Math.round(27 / GRID));
    expect(snap(27.6, false)).toBe(28);
    expect(snap(NaN, true)).toBe(0);
  });
});

describe("sideAnchor", () => {
  it("returns the correct edge midpoints and centers", () => {
    const n = node(0, 0, 100, 60);
    expect(sideAnchor(n, "top")).toEqual({ x: 50, y: 0 });
    expect(sideAnchor(n, "bottom")).toEqual({ x: 50, y: 60 });
    expect(sideAnchor(n, "left")).toEqual({ x: 0, y: 30 });
    expect(sideAnchor(n, "right")).toEqual({ x: 100, y: 30 });
    expect(sideAnchor(n, undefined)).toEqual({ x: 50, y: 30 });
  });
});

describe("nearestSide", () => {
  const n = node(0, 0, 100, 60); // center (50,30)
  it("picks the side facing the point", () => {
    expect(nearestSide(n, 200, 30)).toBe("right");
    expect(nearestSide(n, -200, 30)).toBe("left");
    expect(nearestSide(n, 50, 300)).toBe("bottom");
    expect(nearestSide(n, 50, -300)).toBe("top");
  });
});

describe("rectsIntersect", () => {
  it("detects overlap and separation", () => {
    expect(rectsIntersect({ x: 0, y: 0, w: 10, h: 10 }, { x: 5, y: 5, w: 10, h: 10 })).toBe(true);
    expect(rectsIntersect({ x: 0, y: 0, w: 10, h: 10 }, { x: 20, y: 20, w: 5, h: 5 })).toBe(false);
  });
});

describe("colorRgb / edgeStroke", () => {
  it("resolves hex, swatch (live + fallback), and null", () => {
    expect(colorRgb("#abc", {})).toBe("#abc");
    expect(colorRgb("1", { "1": "1,2,3" })).toBe("1,2,3"); // live map wins
    expect(colorRgb("2", {})).toBe("236, 117, 0"); // COLOR_MAP fallback
    expect(colorRgb(undefined, {})).toBeNull();
  });
  it("edgeStroke wraps an rgb triplet and falls back", () => {
    expect(edgeStroke({ color: "2" } as CanvasEdge, {})).toBe("rgb(236, 117, 0)");
    expect(edgeStroke({ color: "#fff" } as CanvasEdge, {})).toBe("#fff");
    expect(edgeStroke({} as CanvasEdge, {})).toBe("var(--muted-foreground)");
  });
});

describe("edgePath / edgeMidpoint", () => {
  const a = node(0, 0);
  const b = node(300, 0);
  const e = { fromSide: "right", toSide: "left" } as CanvasEdge;
  it("emits a cubic bezier between the chosen sides", () => {
    expect(edgePath(a, b, e)).toMatch(/^M 100 30 C .* 300 30$/);
  });
  it("midpoint is between the two anchors", () => {
    expect(edgeMidpoint(a, b, e)).toEqual({ x: 200, y: 30 });
  });
});
