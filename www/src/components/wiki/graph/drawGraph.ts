/**
 * Pure canvas draw function for the wiki graph view.
 *
 * Ported from granite's `drawGraphFrame` (src/ui/views/GraphView.tsx) and
 * re-shaped for the codex-swift www app:
 *   - Colours are resolved from the entity `kind` to a www chart token, but the
 *     CALLER must pass already-resolved hex/rgb strings (Canvas2D silently
 *     rejects `var(--…)`). `kindColorVarName` here maps kind → the CSS custom
 *     property name; `WikiGraphView` resolves it via getComputedStyle.
 *   - No global state. Safe to call from a rAF loop or a test harness.
 *
 * Draw order (Obsidian look):
 *   1. Edges (dimmed unless incident to the hovered node).
 *   2. Highlighted edges (incident to hover), drawn in the accent colour.
 *   3. Nodes — batched by fill colour in the no-hover fast path; per-node in the
 *      hover/selected slow path (tinting + dimming).
 *   4. Labels, only above a zoom threshold.
 */

/** A node ready to draw: world position, colour and weight already resolved. */
export interface DrawNode {
  /** World-space x (from the simulation). */
  x: number;
  /** World-space y (from the simulation). */
  y: number;
  /** Already-resolved fill colour (hex / rgb / rgba — never `var(...)`). */
  color: string;
  /** Degree-ish weight; drives node radius. */
  weight: number;
  /** Visible label (entity title). */
  label: string;
}

/** An edge as index pairs into the `nodes` array. */
export interface DrawEdge {
  source: number;
  target: number;
}

/** Viewport transform: pan offset (screen px) + uniform scale. */
export interface DrawTransform {
  x: number;
  y: number;
  scale: number;
}

/** Already-resolved theme colours (hex / rgb). */
export interface DrawColors {
  /** Canvas background fill. */
  background: string;
  /** Accent used for the hovered/selected node and its incident edges. */
  accent: string;
  /** Base edge colour. */
  edge: string;
  /** Node stroke (usually == background for the Obsidian "halo" look). */
  nodeStroke: string;
  /** Label text colour. */
  text: string;
}

/** Per-frame draw options. */
export interface DrawGraphOptions {
  /** CSS-pixel size of the canvas (pre-DPR). */
  size: { w: number; h: number };
  /** Device pixel ratio for the backing store. */
  dpr: number;
  /** Viewport transform. */
  transform: DrawTransform;
  nodes: ReadonlyArray<DrawNode>;
  edges: ReadonlyArray<DrawEdge>;
  /** Index of the hovered node, or -1. Highlights it + incident edges, dims the rest. */
  hoveredIndex: number;
  /** Index of the selected/seed node, or -1. Drawn in the accent colour. */
  selectedIndex: number;
  /**
   * `neighborMask[i] === 1` means node `i` is adjacent to the hovered node and
   * should NOT be dimmed. Caller-owned, reused across frames. Length must be
   * >= nodes.length (extra entries ignored).
   */
  neighborMask: Uint8Array;
  /** Base node radius in screen px (before per-node weight scaling). */
  nodeSize: number;
  /** Base link thickness in screen px. */
  linkThickness: number;
  /** Label font size in screen px. */
  labelSize: number;
  /** Whether to draw labels this frame (caller gates on the zoom threshold). */
  showLabels: boolean;
  /** Already-resolved theme colours. */
  colors: DrawColors;
}

/** Maps an entity `kind` to a www chart-token CSS custom property name. The
 *  caller resolves these to concrete colours via getComputedStyle. Unknown /
 *  missing kinds fall back to a neutral tertiary text token. */
export const KIND_COLOR_VAR: Readonly<Record<string, string>> = {
  person: "--color-charts-blue",
  org: "--color-charts-purple",
  product: "--color-charts-green",
  paper: "--color-charts-orange",
  repo: "--color-charts-green",
  concept: "--color-charts-blue",
  tag: "--color-charts-red",
};

/** The fallback token name for unknown / missing kinds. */
export const KIND_FALLBACK_VAR = "--color-text-tertiary";

/** CSS var name for the colour of an entity `kind` (fallback for unknowns). */
export function kindColorVarName(kind?: string): string {
  if (kind && kind in KIND_COLOR_VAR) return KIND_COLOR_VAR[kind] as string;
  return KIND_FALLBACK_VAR;
}

/** Per-node radius from weight, clamped — mirrors granite's curve. */
function radiusFor(baseR: number, weight: number): number {
  const w = Math.max(0.6, Math.min(2.4, Math.sqrt(Math.max(0, weight) || 1) * 0.6));
  return baseR * w;
}

/**
 * Draw one frame. Pure over its arguments; mutates only the supplied `ctx`.
 */
export function drawGraph(ctx: CanvasRenderingContext2D, options: DrawGraphOptions): void {
  const {
    size,
    dpr,
    transform,
    nodes,
    edges,
    hoveredIndex,
    selectedIndex,
    neighborMask,
    nodeSize,
    linkThickness,
    labelSize,
    showLabels,
  } = options;
  const { background, accent, edge, nodeStroke, text } = options.colors;

  // Reset to device space and clear.
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  ctx.fillStyle = background;
  ctx.fillRect(0, 0, size.w, size.h);

  // World → screen: centre + pan, then scale. (Matches WikiGraphView.screenToWorld.)
  const cx = size.w / 2 + transform.x;
  const cy = size.h / 2 + transform.y;
  ctx.translate(cx, cy);
  ctx.scale(transform.scale, transform.scale);

  const invScale = 1 / Math.max(0.7, transform.scale);
  const hasHover = hoveredIndex >= 0 && hoveredIndex < nodes.length;

  // --- 1) Edges (dimmed; skip those incident to hover, drawn highlighted later).
  ctx.lineWidth = linkThickness * invScale;
  ctx.strokeStyle = edge;
  ctx.beginPath();
  for (let e = 0; e < edges.length; e++) {
    const { source: a, target: b } = edges[e] as DrawEdge;
    if (a < 0 || b < 0 || a >= nodes.length || b >= nodes.length) continue;
    if (hasHover && (a === hoveredIndex || b === hoveredIndex)) continue;
    const na = nodes[a] as DrawNode;
    const nb = nodes[b] as DrawNode;
    ctx.moveTo(na.x, na.y);
    ctx.lineTo(nb.x, nb.y);
  }
  ctx.globalAlpha = hasHover ? 0.1 : 0.4;
  ctx.stroke();
  ctx.globalAlpha = 1;

  // --- 2) Highlighted edges (incident to hover), in accent.
  if (hasHover) {
    ctx.beginPath();
    for (let e = 0; e < edges.length; e++) {
      const { source: a, target: b } = edges[e] as DrawEdge;
      if (a < 0 || b < 0 || a >= nodes.length || b >= nodes.length) continue;
      if (a !== hoveredIndex && b !== hoveredIndex) continue;
      const na = nodes[a] as DrawNode;
      const nb = nodes[b] as DrawNode;
      ctx.moveTo(na.x, na.y);
      ctx.lineTo(nb.x, nb.y);
    }
    ctx.globalAlpha = 0.9;
    ctx.strokeStyle = accent;
    ctx.stroke();
    ctx.globalAlpha = 1;
  }

  // --- 3) Nodes.
  const baseR = nodeSize * invScale;
  ctx.lineWidth = 1 * invScale;
  ctx.strokeStyle = nodeStroke;

  const hasSelected = selectedIndex >= 0 && selectedIndex < nodes.length;
  if (!hasHover && !hasSelected) {
    // Fast path: batch by colour so we do one path per fill style.
    const byColor = new Map<string, number[]>();
    for (let i = 0; i < nodes.length; i++) {
      const c = (nodes[i] as DrawNode).color;
      let arr = byColor.get(c);
      if (!arr) {
        arr = [];
        byColor.set(c, arr);
      }
      arr.push(i);
    }
    for (const [color, indices] of byColor) {
      ctx.fillStyle = color;
      ctx.beginPath();
      for (const i of indices) {
        const n = nodes[i] as DrawNode;
        const r = radiusFor(baseR, n.weight);
        ctx.moveTo(n.x + r, n.y);
        ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      }
      ctx.fill();
      ctx.stroke();
    }
  } else {
    // Slow path: per-node tinting + dimming for hover/selection.
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i] as DrawNode;
      const isHover = i === hoveredIndex;
      const isSelected = i === selectedIndex;
      const isNeighbor = neighborMask[i] === 1;
      const dim = hasHover && !isHover && !isNeighbor && !isSelected;
      const r = radiusFor(baseR, n.weight) * (isHover ? 1.4 : isSelected ? 1.25 : 1);
      ctx.globalAlpha = dim ? 0.22 : 1;
      ctx.beginPath();
      ctx.fillStyle = isHover || isSelected ? accent : n.color;
      ctx.arc(n.x, n.y, r, 0, Math.PI * 2);
      ctx.fill();
      ctx.stroke();
    }
    ctx.globalAlpha = 1;
  }

  // --- 4) Labels (above the zoom threshold only).
  if (showLabels) {
    ctx.font = `${labelSize * invScale}px var(--font-sans, ui-sans-serif, system-ui, sans-serif)`;
    ctx.fillStyle = text;
    ctx.textAlign = "center";
    ctx.textBaseline = "top";
    for (let i = 0; i < nodes.length; i++) {
      const n = nodes[i] as DrawNode;
      const isHover = i === hoveredIndex;
      const isSelected = i === selectedIndex;
      const isNeighbor = neighborMask[i] === 1;
      const dim = hasHover && !isHover && !isNeighbor && !isSelected;
      const r = radiusFor(baseR, n.weight);
      ctx.globalAlpha = dim ? 0.35 : 1;
      ctx.fillText(n.label, n.x, n.y + r + 4 * invScale);
    }
    ctx.globalAlpha = 1;
  }
}
