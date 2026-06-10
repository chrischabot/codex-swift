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

/**
 * A user-defined color group. `query` is either a plain substring (matched
 * case-insensitively against the node label) or a `kind:` prefix (matched
 * against the entity kind). Nodes matching a group render in `color`,
 * overriding {@link GraphSettings.colorBy}; the FIRST group in array order
 * whose query matches wins. Mirrors granite's search-query coloring groups,
 * rescoped to the label/kind data the wiki entity graph actually carries.
 */
export interface GraphColorGroup {
  /** Stable id (keys React elements + remove). */
  readonly id: string;
  /** Substring or `kind:x` query. Empty query never matches. */
  readonly query: string;
  /** CSS color applied to matching nodes (hex, e.g. `#4aa3ff`). */
  readonly color: string;
}

/** Minimal node shape the filter/group logic reads. Subset of WikiGraphNode. */
export interface GraphFilterNode {
  /** Entity title / label. */
  readonly title: string;
  /** Entity kind (e.g. `person`), if known. */
  readonly kind?: string;
}

/**
 * A parsed filter/group query. A `kind:` prefix targets the entity kind; any
 * other text is a plain label substring. Both are lower-cased for
 * case-insensitive matching.
 */
export interface ParsedGraphQuery {
  /** `"kind"` → match against node.kind; `"label"` → substring of node.title. */
  readonly mode: "kind" | "label";
  /** Lower-cased needle (kind value or label substring). */
  readonly term: string;
}

/** `kind:` prefix marker for the text filter + color-group queries. */
const KIND_PREFIX = "kind:";

/**
 * Parse a raw filter/group query string. Leading/trailing whitespace is
 * trimmed; a `kind:` prefix (case-insensitive) switches to kind-matching on the
 * remainder. Everything else is a label substring. Pure.
 */
export function parseGraphQuery(raw: string): ParsedGraphQuery {
  const trimmed = raw.trim();
  const lower = trimmed.toLowerCase();
  if (lower.startsWith(KIND_PREFIX)) {
    return { mode: "kind", term: lower.slice(KIND_PREFIX.length).trim() };
  }
  return { mode: "label", term: lower };
}

/**
 * Test whether a node matches a parsed query.
 *  - `label` mode: case-insensitive substring of the node title. An EMPTY term
 *    matches everything (so an empty text filter shows the whole graph).
 *  - `kind` mode: case-insensitive substring of the node kind. An empty term
 *    (`kind:`) matches any node that HAS a kind. A node with no kind never
 *    matches a kind query.
 * Pure over its arguments.
 */
export function nodeMatchesQuery(node: GraphFilterNode, q: ParsedGraphQuery): boolean {
  if (q.mode === "kind") {
    const kind = (node.kind ?? "").toLowerCase();
    if (kind === "") return false;
    if (q.term === "") return true;
    return kind.includes(q.term);
  }
  if (q.term === "") return true;
  return (node.title ?? "").toLowerCase().includes(q.term);
}

/**
 * Whether a node passes the live text filter. An empty/whitespace filter shows
 * every node. Convenience wrapper that parses + matches in one call.
 */
export function nodePassesFilter(node: GraphFilterNode, filter: string): boolean {
  if (filter.trim() === "") return true;
  return nodeMatchesQuery(node, parseGraphQuery(filter));
}

/**
 * Resolve a node's color-group override: the color of the FIRST group whose
 * (non-empty) query matches, or `null` if no group matches. Groups with an
 * empty query are skipped so a half-typed group doesn't recolor everything.
 * The caller falls back to its default `colorBy` color when this returns null.
 * Pure over its arguments.
 */
export function resolveGroupColor(
  node: GraphFilterNode,
  groups: ReadonlyArray<GraphColorGroup>,
): string | null {
  for (const g of groups) {
    if (g.query.trim() === "") continue;
    if (nodeMatchesQuery(node, parseGraphQuery(g.query))) return g.color;
  }
  return null;
}

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
  /**
   * Node-label font size in screen px. Decoupled from {@link labelThreshold}
   * (which only gates label VISIBILITY): this scales how large visible labels
   * render. Read per-frame in the draw path.
   */
  textSize: number;

  // --- Filters / data shaping ---
  /** Node coloring mode. */
  colorBy: GraphColorBy;
  /** Neighborhood expansion radius when a node is seeded (local graph). */
  depth: number;
  /**
   * Live node filter. A plain substring matches the node label
   * (case-insensitive); a `kind:` prefix matches the entity kind. Filtered-out
   * nodes (and their now-dangling edges) are hidden from the sim/render. Empty
   * shows the whole graph. Session-only by default (not persisted via the
   * shared settings; see {@link GraphSettings.colorGroups} note).
   */
  textFilter: string;
  /**
   * User-defined color groups. The first group whose query matches a node
   * recolors it, overriding {@link colorBy}. See {@link GraphColorGroup}.
   */
  colorGroups: GraphColorGroup[];
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
  textSize: 11,
  colorBy: "kind",
  depth: 2,
  textFilter: "",
  colorGroups: [],
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
  { key: "textSize", label: "Text size", min: 8, max: 24, step: 1 },
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
