// Canvas document schema — TS types + parse/serialize for a canvas stored as a
// wiki page. There is NO new backend: a canvas is a WikiPage whose markdown
// body is a frontmatter line (`wiki_type: canvas`) followed by a JSON blob. We
// read `WikiPage.content`, strip the frontmatter, and JSON.parse the rest; on
// save we reserialize the frontmatter + pretty JSON.
//
// The on-disk node/edge shape is Obsidian `.canvas`-compatible-ish: every node
// carries {id,type,x,y,w,h} plus type-specific fields. We use `w`/`h` (matching
// the task spec) rather than Obsidian's `width`/`height`, but the parser accepts
// both so hand-authored / imported docs degrade gracefully.

export type CanvasColor = "1" | "2" | "3" | "4" | "5" | "6" | string;
export type NodeType = "text" | "page" | "group" | "link";
export type EdgeSide = "top" | "right" | "bottom" | "left";

export interface CanvasNode {
  id: string;
  type: NodeType;
  x: number;
  y: number;
  w: number;
  h: number;
  /** text node body (markdown; rendered read-only via WikiMarkdown when the
   *  node is not being edited, raw in the textarea while editing). */
  text?: string;
  /** page node: id of the wiki page this card previews / opens. */
  pageId?: string;
  /** link node: external URL. */
  url?: string;
  /** group / page label (group title, or cached page title). */
  label?: string;
  /** swatch color ("1".."6") or a raw `#hex`. */
  color?: CanvasColor;
}

export interface CanvasEdge {
  id: string;
  fromNode: string;
  toNode: string;
  fromSide?: EdgeSide;
  toSide?: EdgeSide;
  label?: string;
  color?: CanvasColor;
}

export interface Canvas {
  nodes: CanvasNode[];
  edges: CanvasEdge[];
}

/**
 * Clone a selection of nodes (by id) with fresh ids, offset by `offset` px.
 * Edges are carried over ONLY when BOTH endpoints are in the selection (an edge
 * to an unselected node can't be meaningfully duplicated). `genId` is injected
 * so the result is deterministic in tests. Returns the clones + the new node
 * ids (for re-selecting the duplicates). Pure.
 */
export function cloneSelection(
  nodes: ReadonlyArray<CanvasNode>,
  edges: ReadonlyArray<CanvasEdge>,
  selectedIds: ReadonlySet<string>,
  offset: number,
  genId: () => string,
): { nodes: CanvasNode[]; edges: CanvasEdge[]; newIds: string[] } {
  const idMap = new Map<string, string>();
  const outNodes: CanvasNode[] = [];
  for (const n of nodes) {
    if (!selectedIds.has(n.id)) continue;
    const nid = genId();
    idMap.set(n.id, nid);
    outNodes.push({ ...n, id: nid, x: n.x + offset, y: n.y + offset });
  }
  const outEdges: CanvasEdge[] = [];
  for (const e of edges) {
    const from = idMap.get(e.fromNode);
    const to = idMap.get(e.toNode);
    if (from && to) outEdges.push({ ...e, id: genId(), fromNode: from, toNode: to });
  }
  return { nodes: outNodes, edges: outEdges, newIds: [...idMap.values()] };
}

export interface ParsedCanvasDoc {
  /** Raw frontmatter key/values parsed off the leading `---` block. */
  frontmatter: Record<string, string>;
  canvas: Canvas;
}

export const EMPTY_CANVAS: Canvas = { nodes: [], edges: [] };
export const CANVAS_WIKI_TYPE = "canvas";

const DEFAULT_W = 240;
const DEFAULT_H = 120;

// ── value coercion helpers ──────────────────────────────────────────────────

function asString(v: unknown): string | undefined {
  return typeof v === "string" ? v : undefined;
}
function asNumber(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}
function asNodeType(v: unknown): NodeType | undefined {
  if (v === "text" || v === "page" || v === "group" || v === "link") return v;
  // Obsidian-compat: a "file" node is our "page" node.
  if (v === "file") return "page";
  return undefined;
}
function asSide(v: unknown): EdgeSide | undefined {
  if (v === "top" || v === "right" || v === "bottom" || v === "left") return v;
  return undefined;
}

// ── frontmatter split ───────────────────────────────────────────────────────

/**
 * Split a body into its leading YAML-ish frontmatter block and the remaining
 * content. Only flat `key: value` lines are supported (sufficient for the
 * `wiki_type` marker). Returns `{ frontmatter, rest }`.
 */
function splitFrontmatter(body: string): {
  frontmatter: Record<string, string>;
  rest: string;
} {
  const fm: Record<string, string> = {};
  // Must start with `---` on its own line.
  const match = /^---[ \t]*\r?\n([\s\S]*?)\r?\n---[ \t]*\r?\n?/.exec(body);
  if (!match) return { frontmatter: fm, rest: body };
  const block = match[1];
  for (const line of block.split(/\r?\n/)) {
    const idx = line.indexOf(":");
    if (idx <= 0) continue;
    const key = line.slice(0, idx).trim();
    const value = line.slice(idx + 1).trim();
    if (key) fm[key] = value;
  }
  return { frontmatter: fm, rest: body.slice(match[0].length) };
}

// ── node / edge normalization ───────────────────────────────────────────────

function parseNode(raw: unknown): CanvasNode | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const id = asString(o.id);
  const type = asNodeType(o.type);
  if (!id || !type) return null;
  const node: CanvasNode = {
    id,
    type,
    x: asNumber(o.x, 0),
    y: asNumber(o.y, 0),
    // Accept both `w`/`h` (ours) and `width`/`height` (Obsidian).
    w: Math.max(1, asNumber(o.w, asNumber(o.width, DEFAULT_W))),
    h: Math.max(1, asNumber(o.h, asNumber(o.height, DEFAULT_H))),
  };
  const color = o.color;
  if (typeof color === "string" && color) node.color = color;
  if (type === "text") node.text = asString(o.text) ?? "";
  if (type === "page") {
    // Accept `pageId`, or Obsidian's `file` as the page reference.
    node.pageId = asString(o.pageId) ?? asString(o.file) ?? "";
    const label = asString(o.label);
    if (label) node.label = label;
  }
  if (type === "link") node.url = asString(o.url) ?? "";
  if (type === "group") {
    const label = asString(o.label);
    if (label) node.label = label;
  }
  return node;
}

function parseEdge(raw: unknown): CanvasEdge | null {
  if (!raw || typeof raw !== "object") return null;
  const o = raw as Record<string, unknown>;
  const id = asString(o.id);
  const fromNode = asString(o.fromNode);
  const toNode = asString(o.toNode);
  if (!id || !fromNode || !toNode) return null;
  const edge: CanvasEdge = { id, fromNode, toNode };
  const fromSide = asSide(o.fromSide);
  const toSide = asSide(o.toSide);
  if (fromSide) edge.fromSide = fromSide;
  if (toSide) edge.toSide = toSide;
  const label = asString(o.label);
  if (label) edge.label = label;
  const color = o.color;
  if (typeof color === "string" && color) edge.color = color;
  return edge;
}

/** Coerce arbitrary parsed JSON into a well-formed Canvas (dropping junk). */
export function normalizeCanvas(raw: unknown): Canvas {
  if (!raw || typeof raw !== "object") return { nodes: [], edges: [] };
  const root = raw as { nodes?: unknown; edges?: unknown };
  const nodesIn = Array.isArray(root.nodes) ? root.nodes : [];
  const edgesIn = Array.isArray(root.edges) ? root.edges : [];
  const nodes: CanvasNode[] = [];
  for (const n of nodesIn) {
    const node = parseNode(n);
    if (node) nodes.push(node);
  }
  const ids = new Set(nodes.map((n) => n.id));
  const edges: CanvasEdge[] = [];
  for (const e of edgesIn) {
    const edge = parseEdge(e);
    // Drop dangling edges whose endpoints no longer exist.
    if (edge && ids.has(edge.fromNode) && ids.has(edge.toNode)) edges.push(edge);
  }
  return { nodes, edges };
}

// ── public parse / serialize ────────────────────────────────────────────────

/**
 * Parse a wiki page body (`WikiPage.content`) into a canvas document. Tolerant:
 * malformed JSON or a missing frontmatter yields an empty canvas rather than
 * throwing, so a brand-new / non-canvas page opens as a blank board.
 */
export function parseCanvasDoc(content: string | undefined | null): ParsedCanvasDoc {
  const body = content ?? "";
  const { frontmatter, rest } = splitFrontmatter(body);
  const jsonText = rest.trim();
  if (!jsonText) return { frontmatter, canvas: { nodes: [], edges: [] } };
  let parsed: unknown;
  try {
    parsed = JSON.parse(jsonText);
  } catch {
    return { frontmatter, canvas: { nodes: [], edges: [] } };
  }
  return { frontmatter, canvas: normalizeCanvas(parsed) };
}

/**
 * Serialize a canvas back into a wiki page body: a `wiki_type: canvas`
 * frontmatter block followed by pretty-printed JSON. Extra frontmatter keys
 * (if provided) are preserved alongside the type marker.
 */
export function serializeCanvasDoc(
  canvas: Canvas,
  extraFrontmatter?: Record<string, string>,
): string {
  const fm: Record<string, string> = {
    ...(extraFrontmatter ?? {}),
    wiki_type: CANVAS_WIKI_TYPE,
  };
  const fmLines = Object.entries(fm)
    .filter(([k]) => k)
    .map(([k, v]) => `${k}: ${v}`)
    .join("\n");
  const json = JSON.stringify({ nodes: canvas.nodes, edges: canvas.edges }, null, 2);
  return `---\n${fmLines}\n---\n${json}\n`;
}

/** True when a wiki page body declares itself a canvas via frontmatter AND its
 *  body is an actual canvas JSON object. The body check guards against a normal
 *  prose page that merely happens to carry a `wiki_type: canvas` frontmatter
 *  key: such a page must open in the reading view (with an Edit escape hatch),
 *  not the full-bleed board — which would otherwise overwrite the prose with
 *  canvas JSON on the first edit. */
export function isCanvasDoc(content: string | undefined | null): boolean {
  if (!content) return false;
  const { frontmatter, rest } = splitFrontmatter(content);
  if (frontmatter.wiki_type !== CANVAS_WIKI_TYPE) return false;
  const jsonText = rest.trim();
  if (!jsonText) return false; // marker but no board payload → treat as prose
  try {
    const p = JSON.parse(jsonText);
    return !!p && typeof p === "object" && !Array.isArray(p) && ("nodes" in p || "edges" in p);
  } catch {
    return false;
  }
}

/** Short random node/edge id, stable across browsers (Web Crypto). */
export function newCanvasId(): string {
  const buf = new Uint8Array(8);
  crypto.getRandomValues(buf);
  return Array.from(buf, (b) => b.toString(16).padStart(2, "0")).join("");
}

/** Body for a freshly created, empty canvas page. */
export function emptyCanvasBody(): string {
  return serializeCanvasDoc({ nodes: [], edges: [] });
}
