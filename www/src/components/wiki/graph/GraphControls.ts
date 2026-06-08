/**
 * Settings model for the wiki graph view. The view owns this state and passes
 * it down to {@link GraphControlsPanel} as a controlled value+onChange pair.
 *
 * Ported from granite's GraphView controls (filter / local-graph + depth /
 * color-by / display sliders / force sliders / reset), rescoped to the
 * codex-swift wiki graph where nodes are entities and edges connect entity ids.
 */

/** How node colors are derived in the canvas render loop. */
export type GraphColorBy = "kind" | "none";

export interface GraphSettings {
  // --- Forces (passed into the force simulation) ---
  /** Node-node charge / repulsion strength. Higher spreads the graph out. */
  repulsion: number;
  /** Edge spring strength pulling linked nodes together. */
  attraction: number;
  /** Target rest length for edges. */
  linkDistance: number;
  /** Pull toward the layout center; keeps disconnected clusters on screen. */
  centerGravity: number;

  // --- Display (passed into the draw frame) ---
  /** Base node radius in world units. */
  nodeSize: number;
  /** Edge stroke width in world units. */
  linkThickness: number;
  /**
   * Minimum view scale at which labels become visible. Lower shows labels when
   * zoomed further out; higher hides them until you zoom in.
   */
  labelThreshold: number;

  // --- Filters / data shaping ---
  /** Node coloring mode. */
  colorBy: GraphColorBy;
  /** Neighborhood expansion radius when a node is seeded (local graph). */
  depth: number;
}

/**
 * Sensible defaults tuned for the entity-graph sizes the wiki connector
 * returns. Mirrors granite's DEFAULT_GRAPH_CONFIG where the knobs overlap.
 */
export const DEFAULT_GRAPH_SETTINGS: GraphSettings = {
  repulsion: 6000,
  attraction: 0.01,
  linkDistance: 80,
  centerGravity: 0.001,
  nodeSize: 5,
  linkThickness: 1,
  labelThreshold: 1.1,
  colorBy: "kind",
  depth: 2,
};

/** Bounds + step for each numeric knob, shared by the panel sliders. */
export interface GraphSliderSpec {
  key: keyof GraphSettings;
  label: string;
  min: number;
  max: number;
  step: number;
}

export const GRAPH_DISPLAY_SLIDERS: GraphSliderSpec[] = [
  { key: "nodeSize", label: "Node size", min: 2, max: 12, step: 1 },
  { key: "linkThickness", label: "Link thickness", min: 0.2, max: 3, step: 0.1 },
  { key: "labelThreshold", label: "Label threshold", min: 0.4, max: 3, step: 0.1 },
];

export const GRAPH_FORCE_SLIDERS: GraphSliderSpec[] = [
  { key: "repulsion", label: "Repulsion", min: 1000, max: 15000, step: 500 },
  { key: "attraction", label: "Attraction", min: 0.001, max: 0.05, step: 0.001 },
  { key: "linkDistance", label: "Link distance", min: 20, max: 300, step: 10 },
  { key: "centerGravity", label: "Center gravity", min: 0, max: 0.005, step: 0.0001 },
];

export const GRAPH_DEPTH_SLIDER: GraphSliderSpec = {
  key: "depth",
  label: "Depth",
  min: 1,
  max: 4,
  step: 1,
};
