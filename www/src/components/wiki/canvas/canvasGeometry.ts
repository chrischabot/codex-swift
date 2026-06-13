// Pure geometry for the canvas whiteboard, extracted from WikiCanvasView so the
// math is testable in isolation (snap-to-grid, side anchors, edge bezier paths,
// color resolution). No React, no closure state.

import type { CanvasEdge, CanvasNode, EdgeSide } from "./canvasSchema";

/** Grid pitch (world units) for snap-to-grid. */
export const GRID = 20;

/** Swatch palette → rgb triplets (fallbacks; --color-*-rgb override if present). */
export const COLOR_MAP: Record<string, string> = {
  "1": "233, 49, 71",
  "2": "236, 117, 0",
  "3": "224, 172, 0",
  "4": "8, 185, 78",
  "5": "0, 191, 188",
  "6": "120, 82, 238",
};

/** Snap a coordinate to the grid (or to the nearest integer when off). */
export function snap(value: number, on: boolean): number {
  if (!Number.isFinite(value)) return 0;
  return on ? Math.round(value / GRID) * GRID : Math.round(value);
}

/** The anchor point on a given side of a node (center when side is undefined). */
export function sideAnchor(n: CanvasNode, side: EdgeSide | undefined): { x: number; y: number } {
  switch (side) {
    case "top":
      return { x: n.x + n.w / 2, y: n.y };
    case "bottom":
      return { x: n.x + n.w / 2, y: n.y + n.h };
    case "left":
      return { x: n.x, y: n.y + n.h / 2 };
    case "right":
      return { x: n.x + n.w, y: n.y + n.h / 2 };
    default:
      return { x: n.x + n.w / 2, y: n.y + n.h / 2 };
  }
}

/** Pick the nearest side of a node to an absolute world point. */
export function nearestSide(n: CanvasNode, px: number, py: number): EdgeSide {
  const cx = n.x + n.w / 2;
  const cy = n.y + n.h / 2;
  const dx = px - cx;
  const dy = py - cy;
  if (Math.abs(dx) * n.h > Math.abs(dy) * n.w) return dx >= 0 ? "right" : "left";
  return dy >= 0 ? "bottom" : "top";
}

/** Axis-aligned rectangle intersection test. */
export function rectsIntersect(
  a: { x: number; y: number; w: number; h: number },
  b: { x: number; y: number; w: number; h: number },
): boolean {
  return a.x <= b.x + b.w && a.x + a.w >= b.x && a.y <= b.y + b.h && a.y + a.h >= b.y;
}

/** Resolve a swatch id / hex into a color string (or null). `resolved` is the
 *  live `--color-*-rgb` map, with COLOR_MAP as the fallback. */
export function colorRgb(c: string | undefined, resolved: Record<string, string>): string | null {
  if (!c) return null;
  if (c.startsWith("#")) return c;
  return resolved[c] ?? COLOR_MAP[c] ?? null;
}

/** Cubic-bezier control offset for an edge leaving a node on `side`. */
export function controlOffset(p: { x: number; y: number }, side: EdgeSide, k: number): { x: number; y: number } {
  switch (side) {
    case "top":
      return { x: p.x, y: p.y - k };
    case "bottom":
      return { x: p.x, y: p.y + k };
    case "left":
      return { x: p.x - k, y: p.y };
    case "right":
      return { x: p.x + k, y: p.y };
  }
}

/** SVG path `d` for a curved edge between two nodes (honoring explicit sides). */
export function edgePath(a: CanvasNode, b: CanvasNode, e: CanvasEdge): string {
  const fromSide = e.fromSide ?? nearestSide(a, b.x + b.w / 2, b.y + b.h / 2);
  const toSide = e.toSide ?? nearestSide(b, a.x + a.w / 2, a.y + a.h / 2);
  const p1 = sideAnchor(a, fromSide);
  const p2 = sideAnchor(b, toSide);
  const k = Math.max(40, Math.hypot(p2.x - p1.x, p2.y - p1.y) * 0.4);
  const c1 = controlOffset(p1, fromSide, k);
  const c2 = controlOffset(p2, toSide, k);
  return `M ${p1.x} ${p1.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p2.x} ${p2.y}`;
}

/** Midpoint of an edge's two anchor points (where the label/handle sits). */
export function edgeMidpoint(a: CanvasNode, b: CanvasNode, e: CanvasEdge): { x: number; y: number } {
  const p1 = sideAnchor(a, e.fromSide ?? nearestSide(a, b.x + b.w / 2, b.y + b.h / 2));
  const p2 = sideAnchor(b, e.toSide ?? nearestSide(b, a.x + a.w / 2, a.y + a.h / 2));
  return { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 };
}

/** Stroke color for an edge (resolves swatch/hex → CSS color). */
export function edgeStroke(e: CanvasEdge, resolved: Record<string, string>): string {
  const rgb = colorRgb(e.color, resolved);
  if (!rgb) return "var(--muted-foreground)";
  if (rgb.startsWith("#")) return rgb;
  return `rgb(${rgb})`;
}
