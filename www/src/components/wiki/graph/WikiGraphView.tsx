import * as React from "react";
import { Loader2, Maximize2, SlidersHorizontal, Workflow, X } from "lucide-react";
import { cn } from "@/lib/utils";
import { useWikiGraph } from "@/state/wiki";
import { ForceSimulation, type SimEdge, type SimNode } from "./forceSimulation";
import {
  drawGraph,
  kindColorVarName,
  KIND_COLOR_VAR,
  KIND_FALLBACK_VAR,
  type DrawColors,
  type DrawEdge,
  type DrawNode,
} from "./drawGraph";
import { GraphControlsPanel } from "./GraphControlsPanel";
import {
  DEFAULT_GRAPH_SETTINGS,
  nodePassesFilter,
  resolveGroupColor,
  type GraphSettings,
} from "./GraphControls";

export interface Props {
  /** Entity id to seed/centre the graph on. Re-seeds when it changes. */
  seedEntityId?: string;
  /** Traversal depth from the seed (passed through to the connector). */
  depth?: number;
  /** Clicking a node re-explores the graph — NOT a page open. `canonical` is
   *  the node title, for breadcrumb / display use by the integrator. */
  onSelectEntity?: (entityId: string, canonical: string) => void;
  className?: string;
}

/** Min / max zoom (matches granite's clamp). */
const MIN_SCALE = 0.2;
const MAX_SCALE = 3;
/** Stop the rAF loop when alpha drops below this AND nothing is animating. */
const COOL_ALPHA = 0.005;

/** Padding (screen px) left around the graph when fitting to view. */
const FIT_PADDING = 48;

interface ViewState {
  x: number;
  y: number;
  scale: number;
}

/**
 * Obsidian-style force-directed graph of wiki entities. Mounts a canvas, runs
 * the force simulation in a single rAF loop, and supports pan / zoom / hover /
 * click. Clicking (or activating a node in the a11y list) calls `onSelectEntity`
 * so the parent can re-seed the graph.
 */
export function WikiGraphView({ seedEntityId, depth, onSelectEntity, className }: Props) {
  // --- Graph settings (force + display + colour + depth). The view owns this
  // state and passes value+onChange to the floating controls panel. A ref mirror
  // lets the per-frame rAF/draw path read the latest values without re-subscribing.
  // The `depth` prop seeds the initial traversal depth; the panel's depth slider
  // takes over from there (so the prop's behaviour is preserved on first mount).
  const [settings, setSettings] = React.useState<GraphSettings>(() => ({
    ...DEFAULT_GRAPH_SETTINGS,
    depth: typeof depth === "number" ? depth : DEFAULT_GRAPH_SETTINGS.depth,
  }));
  const settingsRef = React.useRef(settings);
  settingsRef.current = settings;
  const [controlsOpen, setControlsOpen] = React.useState(false);

  const rawGraph = useWikiGraph({ seedEntityId, depth: settings.depth });

  // --- Apply the live text filter: hide non-matching nodes AND their now-
  // dangling edges. The seed node is always kept so a filter can't orphan the
  // explore target. Recomputed only when the data or the filter string change
  // (NOT on every settings tweak), so dragging a slider doesn't rebuild the sim.
  const textFilter = settings.textFilter;
  const graph = React.useMemo(() => {
    if (textFilter.trim() === "") return rawGraph;
    const keep = new Set<string>();
    for (const n of rawGraph.nodes) {
      if (n.id === seedEntityId || nodePassesFilter(n, textFilter)) keep.add(n.id);
    }
    // No matches → fall back to the full graph rather than blanking the view;
    // the empty state is reserved for "no data", not "nothing matched".
    if (keep.size === 0) return rawGraph;
    const nodes = rawGraph.nodes.filter((n) => keep.has(n.id));
    const edges = rawGraph.edges.filter((e) => keep.has(e.source) && keep.has(e.target));
    return { nodes, edges };
  }, [rawGraph, textFilter, seedEntityId]);

  const containerRef = React.useRef<HTMLDivElement>(null);
  const canvasRef = React.useRef<HTMLCanvasElement>(null);

  // Size + DPR are kept in refs so the rAF loop reads them without re-subscribing.
  const [size, setSize] = React.useState({ w: 800, h: 600 });
  const sizeRef = React.useRef(size);
  sizeRef.current = size;
  const dprRef = React.useRef(typeof window !== "undefined" ? Math.max(1, window.devicePixelRatio || 1) : 1);

  // Viewport (pan + zoom). Mutated imperatively during drag/wheel; React state
  // only mirrors it for the empty-list rendering, not per-frame.
  const viewRef = React.useRef<ViewState>({ x: 0, y: 0, scale: 1 });

  // Interaction indices.
  const hoverRef = React.useRef(-1);
  const [hoverState, setHoverState] = React.useState(-1); // mirrors hoverRef for the a11y list
  const selectedIndexRef = React.useRef(-1);

  // Simulation + derived draw data, owned by refs (no per-frame React churn).
  const simRef = React.useRef<ForceSimulation | null>(null);
  const drawNodesRef = React.useRef<DrawNode[]>([]);
  const drawEdgesRef = React.useRef<DrawEdge[]>([]);
  const neighborSetsRef = React.useRef<Set<number>[]>([]);
  const neighborMaskRef = React.useRef<Uint8Array>(new Uint8Array(0));
  const idToIndexRef = React.useRef<Map<string, number>>(new Map());
  const colorsRef = React.useRef<DrawColors>({
    background: "#181818",
    accent: "#4aa3ff",
    edge: "#888888",
    nodeStroke: "#181818",
    text: "#dddddd",
  });
  // kind → resolved colour, recomputed on theme change.
  const kindColorRef = React.useRef<Map<string, string>>(new Map());

  // Resolve a node's fill. Custom color groups win FIRST (first matching group
  // in array order), overriding `colorBy`. Otherwise `none` collapses every
  // node onto the neutral fallback token and `kind` keys off the entity kind.
  // `node` may be undefined (e.g. a stale index after a graph swap) — treated
  // as the neutral fallback.
  const colorForNode = React.useCallback(
    (node: { title?: string; kind?: string } | undefined): string => {
      const s = settingsRef.current;
      if (node) {
        const groupColor = resolveGroupColor(
          { title: node.title ?? "", kind: node.kind },
          s.colorGroups,
        );
        if (groupColor) return groupColor;
      }
      const kindMap = kindColorRef.current;
      const fallback = kindMap.get("") ?? "#888888";
      if (s.colorBy === "none") return fallback;
      return kindMap.get(node?.kind ?? "") ?? fallback;
    },
    [],
  );

  const rafRef = React.useRef(0);
  const draggingRef = React.useRef<{
    startX: number;
    startY: number;
    viewX: number;
    viewY: number;
    moved: boolean;
  } | null>(null);
  // Active node drag (drag-to-pin). Distinct from the pan drag above: mousedown
  // landing on a node grabs it, drag moves its sim position + pins it.
  const nodeDragRef = React.useRef<{
    index: number;
    moved: boolean;
    /** Whether the node was already pinned before this drag began. */
    wasPinned: boolean;
  } | null>(null);

  // --- Resolve theme colours from CSS custom properties (Canvas can't use var()).
  const resolveColors = React.useCallback(() => {
    const root = document.documentElement;
    const cs = getComputedStyle(root);
    const read = (name: string, fallback: string) => {
      const v = cs.getPropertyValue(name).trim();
      return v || fallback;
    };
    const bg = read("--background", "#181818");
    colorsRef.current = {
      background: bg,
      accent: read("--text-link", "#4aa3ff"),
      edge: read("--border", "#888888"),
      // Stroke == background gives the Obsidian "halo" between overlapping nodes.
      nodeStroke: bg,
      text: read("--color-text-secondary", "#dddddd"),
    };
    const kindMap = new Map<string, string>();
    for (const kind of Object.keys(KIND_COLOR_VAR)) {
      kindMap.set(kind, read(kindColorVarName(kind), "#888888"));
    }
    kindMap.set("", read(KIND_FALLBACK_VAR, "#888888"));
    kindColorRef.current = kindMap;
    // Re-tint existing draw nodes if we already have a graph (honours colorBy).
    const nodes = graph.nodes;
    const dn = drawNodesRef.current;
    for (let i = 0; i < dn.length; i++) {
      (dn[i] as DrawNode).color = colorForNode(nodes[i]);
    }
  }, [graph.nodes, colorForNode]);

  // Re-resolve on the .dark class toggling (or any class change on <html>).
  React.useEffect(() => {
    resolveColors();
    const obs = new MutationObserver(() => resolveColors());
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => obs.disconnect();
  }, [resolveColors]);

  // --- Build the simulation + derived arrays whenever the graph data changes.
  React.useEffect(() => {
    const { nodes, edges } = graph;
    if (nodes.length === 0) {
      simRef.current = null;
      drawNodesRef.current = [];
      drawEdgesRef.current = [];
      neighborSetsRef.current = [];
      neighborMaskRef.current = new Uint8Array(0);
      idToIndexRef.current = new Map();
      selectedIndexRef.current = -1;
      hoverRef.current = -1;
      setHoverState(-1);
      return;
    }

    const idToIndex = new Map<string, number>();
    for (let i = 0; i < nodes.length; i++) idToIndex.set(nodes[i]!.id, i);
    idToIndexRef.current = idToIndex;

    const simNodes: SimNode[] = nodes.map((n) => ({ id: n.id, weight: n.weight }));
    const simEdges: SimEdge[] = [];
    const drawEdges: DrawEdge[] = [];
    const neighborSets: Set<number>[] = nodes.map(() => new Set<number>());
    for (const e of edges) {
      const a = idToIndex.get(e.source);
      const b = idToIndex.get(e.target);
      if (a === undefined || b === undefined || a === b) continue;
      simEdges.push({ source: e.source, target: e.target });
      drawEdges.push({ source: a, target: b });
      neighborSets[a]!.add(b);
      neighborSets[b]!.add(a);
    }

    const s = settingsRef.current;
    const sim = new ForceSimulation(simNodes, simEdges, {
      alphaDecay: 0.04,
      damping: 0.6,
      repulsion: s.repulsion,
      attraction: s.attraction,
      linkDistance: s.linkDistance,
      centerGravity: s.centerGravity,
    });
    simRef.current = sim;
    drawEdgesRef.current = drawEdges;
    neighborSetsRef.current = neighborSets;
    neighborMaskRef.current = new Uint8Array(nodes.length);

    drawNodesRef.current = nodes.map((n, i) => ({
      x: sim.xAt(i),
      y: sim.yAt(i),
      color: colorForNode(n),
      weight: n.weight ?? 1,
      label: n.title,
    }));

    // Seed node starts selected/centred.
    selectedIndexRef.current = seedEntityId ? (idToIndex.get(seedEntityId) ?? -1) : -1;
    hoverRef.current = -1;
    setHoverState(-1);
    viewRef.current = { x: 0, y: 0, scale: 1 };
  }, [graph, seedEntityId, colorForNode]);

  // --- ResizeObserver: track CSS size + DPR for the backing store.
  React.useEffect(() => {
    const el = containerRef.current;
    if (!el) return;
    const ro = new ResizeObserver((entries) => {
      for (const entry of entries) {
        dprRef.current = Math.max(1, window.devicePixelRatio || 1);
        setSize({ w: Math.max(1, entry.contentRect.width), h: Math.max(1, entry.contentRect.height) });
      }
    });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  // --- The single rAF loop: step the sim (while hot), then draw.
  React.useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    const ctx = canvas.getContext("2d", { alpha: false });
    if (!ctx) return;

    const dpr = dprRef.current;
    canvas.width = Math.max(1, Math.floor(size.w * dpr));
    canvas.height = Math.max(1, Math.floor(size.h * dpr));
    canvas.style.width = `${size.w}px`;
    canvas.style.height = `${size.h}px`;

    let stopped = false;

    const syncDrawPositions = () => {
      const sim = simRef.current;
      const dn = drawNodesRef.current;
      if (!sim) return;
      for (let i = 0; i < dn.length; i++) {
        (dn[i] as DrawNode).x = sim.xAt(i);
        (dn[i] as DrawNode).y = sim.yAt(i);
      }
    };

    const renderOnce = () => {
      syncDrawPositions();
      const hovered = hoverRef.current;
      const mask = neighborMaskRef.current;
      mask.fill(0);
      if (hovered >= 0) {
        const set = neighborSetsRef.current[hovered];
        if (set) for (const idx of set) mask[idx] = 1;
      }
      const s = settingsRef.current;
      drawGraph(ctx, {
        size: sizeRef.current,
        dpr: dprRef.current,
        transform: viewRef.current,
        nodes: drawNodesRef.current,
        edges: drawEdgesRef.current,
        hoveredIndex: hovered,
        selectedIndex: selectedIndexRef.current,
        neighborMask: mask,
        nodeSize: s.nodeSize,
        linkThickness: s.linkThickness,
        labelSize: s.textSize,
        showLabels: viewRef.current.scale > s.labelThreshold,
        colors: colorsRef.current,
      });
    };

    const tick = () => {
      if (stopped) return;
      const sim = simRef.current;
      const hot = sim ? sim.alpha > COOL_ALPHA : false;
      if (sim && hot) sim.step();
      renderOnce();
      // Keep ticking while the sim is hot OR the user is dragging (pan still
      // needs redraws). Once cooled and idle, park the loop — hover/drag/wheel
      // handlers kick it back via `wake()`.
      if (hot || draggingRef.current || nodeDragRef.current) {
        rafRef.current = requestAnimationFrame(tick);
      } else {
        rafRef.current = 0;
      }
    };

    // Expose a wake fn on the canvas element for the event handlers.
    const wake = () => {
      if (stopped) return;
      if (rafRef.current === 0) rafRef.current = requestAnimationFrame(tick);
    };
    (canvas as HTMLCanvasElement & { __wake?: () => void }).__wake = wake;

    rafRef.current = requestAnimationFrame(tick);
    return () => {
      stopped = true;
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
      rafRef.current = 0;
      delete (canvas as HTMLCanvasElement & { __wake?: () => void }).__wake;
    };
  }, [size, graph]);

  const wake = React.useCallback(() => {
    const canvas = canvasRef.current as (HTMLCanvasElement & { __wake?: () => void }) | null;
    canvas?.__wake?.();
  }, []);

  // --- Apply settings changes to the live simulation / draw.
  //  - Force sliders → push into the running sim, reheat, and wake the loop so
  //    the layout re-settles under the new forces.
  //  - colorBy → re-tint the existing draw nodes (no reheat needed).
  //  - Display sliders (nodeSize / linkThickness / labelThreshold / textSize)
  //    are read per-frame from settingsRef, so a wake() is enough to repaint.
  const prevForcesRef = React.useRef<{ repulsion: number; attraction: number; linkDistance: number; centerGravity: number } | null>(null);
  React.useEffect(() => {
    const sim = simRef.current;
    if (sim) {
      const next = {
        repulsion: settings.repulsion,
        attraction: settings.attraction,
        linkDistance: settings.linkDistance,
        centerGravity: settings.centerGravity,
      };
      const prev = prevForcesRef.current;
      if (!prev) {
        // First run after the sim is built: the sim was already constructed WITH
        // these forces (and alpha=1), so don't reheat — just record the baseline.
        // Reheating here would needlessly drop the opening anneal from 1.0→0.6.
        prevForcesRef.current = next;
      } else {
        const forcesChanged =
          prev.repulsion !== next.repulsion ||
          prev.attraction !== next.attraction ||
          prev.linkDistance !== next.linkDistance ||
          prev.centerGravity !== next.centerGravity;
        // Only push forces + reheat when a FORCE slider actually moved. Display
        // sliders (nodeSize/linkThickness/labelThreshold/textSize) and colorBy are read
        // per-frame / re-tinted below, so they just need a repaint — reheating on
        // them would visibly disturb an already-settled layout.
        if (forcesChanged) {
          sim.setForces({ ...next, theta: sim.getParams().theta });
          sim.reheat(0.6);
          prevForcesRef.current = next;
        }
      }
    }
    // Re-tint for the current colorBy + color groups (cheap; safe even when
    // neither changed — covers colorBy toggles and color-group CRUD edits).
    const dn = drawNodesRef.current;
    const nodes = graph.nodes;
    for (let i = 0; i < dn.length; i++) {
      (dn[i] as DrawNode).color = colorForNode(nodes[i]);
    }
    wake();
  }, [settings, graph.nodes, colorForNode, wake]);

  // --- Screen → world (inverse of drawGraph's transform).
  const screenToWorld = React.useCallback((clientX: number, clientY: number) => {
    const canvas = canvasRef.current;
    if (!canvas) return { x: 0, y: 0 };
    const rect = canvas.getBoundingClientRect();
    const sx = clientX - rect.left;
    const sy = clientY - rect.top;
    const v = viewRef.current;
    const cx = sizeRef.current.w / 2 + v.x;
    const cy = sizeRef.current.h / 2 + v.y;
    return { x: (sx - cx) / v.scale, y: (sy - cy) / v.scale };
  }, []);

  const hitTest = React.useCallback(
    (clientX: number, clientY: number): number => {
      const sim = simRef.current;
      if (!sim) return -1;
      const world = screenToWorld(clientX, clientY);
      // Generous radius scaled inversely with zoom, mirroring granite.
      const hitR = (settingsRef.current.nodeSize * 3) / Math.max(0.7, viewRef.current.scale);
      const hit = sim.hitTest(world.x, world.y, hitR);
      return hit ? hit.index : -1;
    },
    [screenToWorld],
  );

  // --- Pointer handlers.
  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
    // Mousedown on a node grabs THAT node (drag-to-pin); empty space pans.
    const idx = hitTest(e.clientX, e.clientY);
    const sim = simRef.current;
    if (idx >= 0 && sim) {
      const wasPinned = sim.isPinned(idx);
      sim.pin(idx); // hold it while dragging; may be unpinned again on a click.
      nodeDragRef.current = { index: idx, moved: false, wasPinned };
      wake();
      return;
    }
    draggingRef.current = {
      startX: e.clientX,
      startY: e.clientY,
      viewX: viewRef.current.x,
      viewY: viewRef.current.y,
      moved: false,
    };
    wake();
  };

  const onMouseMove = (e: React.MouseEvent) => {
    const nodeDrag = nodeDragRef.current;
    if (nodeDrag) {
      const sim = simRef.current;
      if (sim) {
        const world = screenToWorld(e.clientX, e.clientY);
        sim.setNodePosition(nodeDrag.index, world.x, world.y);
        nodeDrag.moved = true;
        // Nudge the rest of the layout so neighbours follow the dragged node.
        sim.reheat(0.3);
      }
      wake();
      return;
    }
    const drag = draggingRef.current;
    if (drag) {
      const dx = e.clientX - drag.startX;
      const dy = e.clientY - drag.startY;
      if (Math.abs(dx) > 2 || Math.abs(dy) > 2) drag.moved = true;
      viewRef.current = { ...viewRef.current, x: drag.viewX + dx, y: drag.viewY + dy };
      wake();
      return;
    }
    const idx = hitTest(e.clientX, e.clientY);
    if (idx !== hoverRef.current) {
      hoverRef.current = idx;
      setHoverState(idx);
      wake();
    }
  };

  const onMouseUp = (e: React.MouseEvent) => {
    const nodeDrag = nodeDragRef.current;
    if (nodeDrag) {
      nodeDragRef.current = null;
      const sim = simRef.current;
      if (!nodeDrag.moved) {
        // A click (no drag): select it. Restore the pre-grab pin state so a
        // plain click doesn't accidentally pin an otherwise-free node.
        if (sim && !nodeDrag.wasPinned) sim.unpin(nodeDrag.index);
        selectNode(nodeDrag.index);
      }
      // If it moved, the node stays pinned where the user dropped it.
      wake();
      return;
    }
    const drag = draggingRef.current;
    draggingRef.current = null;
    if (drag && !drag.moved) {
      const idx = hitTest(e.clientX, e.clientY);
      if (idx >= 0) selectNode(idx);
    }
    wake();
  };

  const onMouseLeave = () => {
    // End an in-flight node drag, leaving the node wherever it currently sits
    // (pinned if it had moved, restored otherwise).
    const nodeDrag = nodeDragRef.current;
    if (nodeDrag) {
      const sim = simRef.current;
      if (sim && !nodeDrag.moved && !nodeDrag.wasPinned) sim.unpin(nodeDrag.index);
      nodeDragRef.current = null;
    }
    draggingRef.current = null;
    if (hoverRef.current !== -1) {
      hoverRef.current = -1;
      setHoverState(-1);
      wake();
    }
  };

  // Zoom toward the cursor. Attached as a NATIVE non-passive listener (below) so
  // preventDefault() actually stops the page from scrolling while zooming —
  // React's synthetic onWheel is passive and cannot preventDefault.
  const handleWheel = React.useCallback(
    (e: WheelEvent) => {
      e.preventDefault();
      const factor = e.deltaY > 0 ? 0.9 : 1.1;
      const v = viewRef.current;
      const nextScale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, v.scale * factor));
      if (nextScale === v.scale) return;
      // Keep the world point under the cursor fixed across the zoom.
      const world = screenToWorld(e.clientX, e.clientY);
      const cxw = sizeRef.current.w / 2;
      const cyw = sizeRef.current.h / 2;
      const rect = canvasRef.current?.getBoundingClientRect();
      const sx = rect ? e.clientX - rect.left : cxw;
      const sy = rect ? e.clientY - rect.top : cyw;
      viewRef.current = {
        scale: nextScale,
        x: sx - cxw - world.x * nextScale,
        y: sy - cyw - world.y * nextScale,
      };
      wake();
    },
    [screenToWorld, wake],
  );

  React.useEffect(() => {
    const canvas = canvasRef.current;
    if (!canvas) return;
    canvas.addEventListener("wheel", handleWheel, { passive: false });
    return () => canvas.removeEventListener("wheel", handleWheel);
  }, [handleWheel]);

  const selectNode = React.useCallback(
    (idx: number) => {
      const node = graph.nodes[idx];
      if (!node) return;
      selectedIndexRef.current = idx;
      wake();
      onSelectEntity?.(node.id, node.title);
    },
    [graph.nodes, onSelectEntity, wake],
  );

  // --- Fit-to-view: frame all nodes via sim.bounds() → set pan + scale so the
  // whole layout fits with padding. Inverse of drawGraph's world→screen map
  // (centre + pan, then scale), so x/y are stored pre-scale screen offsets.
  const fitToView = React.useCallback(() => {
    const sim = simRef.current;
    if (!sim || sim.count === 0) return;
    const { minX, minY, maxX, maxY } = sim.bounds();
    const { w, h } = sizeRef.current;
    const worldW = Math.max(1, maxX - minX);
    const worldH = Math.max(1, maxY - minY);
    const availW = Math.max(1, w - FIT_PADDING * 2);
    const availH = Math.max(1, h - FIT_PADDING * 2);
    const scale = Math.max(MIN_SCALE, Math.min(MAX_SCALE, Math.min(availW / worldW, availH / worldH)));
    // World centre we want to land on the canvas centre.
    const wcx = (minX + maxX) / 2;
    const wcy = (minY + maxY) / 2;
    // screen = (w/2 + pan) + world*scale  ⇒  pan = -world*scale for the centre.
    viewRef.current = { scale, x: -wcx * scale, y: -wcy * scale };
    wake();
  }, [wake]);

  // --- Loading / empty states.
  const isLoading = graph.nodes.length === 0 && !!seedEntityId;
  const isEmpty = graph.nodes.length === 0;

  return (
    <div
      ref={containerRef}
      className={cn(
        "relative h-full w-full overflow-hidden rounded-md border border-border bg-background",
        "touch-none select-none",
        className,
      )}
    >
      <canvas
        ref={canvasRef}
        className="block h-full w-full cursor-grab active:cursor-grabbing"
        role="img"
        aria-label="Wiki entity graph"
        onMouseDown={onMouseDown}
        onMouseMove={onMouseMove}
        onMouseUp={onMouseUp}
        onMouseLeave={onMouseLeave}
      />

      {/* Overlay toolbar (top-right): fit-to-view + controls toggle. The panel
          itself stops pointer/wheel events so it doesn't pan/zoom the canvas. */}
      {!isEmpty && (
        <div className="pointer-events-none absolute right-2 top-2 flex flex-col items-end gap-2">
          <div className="pointer-events-auto flex items-center gap-1.5">
            <button
              type="button"
              onClick={fitToView}
              title="Fit graph to view"
              aria-label="Fit graph to view"
              onMouseDown={(e) => e.stopPropagation()}
              className={cn(
                "flex h-7 w-7 items-center justify-center rounded-md border",
                "border-[color:var(--border)] bg-[color:var(--background)]/95 backdrop-blur",
                "text-[color:var(--color-text-tertiary)] shadow-sm",
                "hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
              )}
            >
              <Maximize2 size={14} />
            </button>
            <button
              type="button"
              onClick={() => setControlsOpen((v) => !v)}
              title={controlsOpen ? "Hide graph controls" : "Show graph controls"}
              aria-label={controlsOpen ? "Hide graph controls" : "Show graph controls"}
              aria-expanded={controlsOpen}
              onMouseDown={(e) => e.stopPropagation()}
              className={cn(
                "flex h-7 w-7 items-center justify-center rounded-md border shadow-sm",
                "border-[color:var(--border)] backdrop-blur",
                controlsOpen
                  ? "bg-[color:var(--color-surface-hover)] text-foreground"
                  : "bg-[color:var(--background)]/95 text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
              )}
            >
              {controlsOpen ? <X size={14} /> : <SlidersHorizontal size={14} />}
            </button>
          </div>
          {controlsOpen && <GraphControlsPanel settings={settings} onChange={setSettings} />}
        </div>
      )}

      {/* Accessibility mirror: a focusable, keyboard-navigable node list. Visually
          hidden but reachable by SR + keyboard. Enter/Space re-explores the node. */}
      <ul
        className="sr-only"
        aria-label={`Wiki graph: ${graph.nodes.length} entities, ${graph.edges.length} connections`}
      >
        {graph.nodes.map((n, i) => (
          <li key={n.id}>
            <button
              type="button"
              onFocus={() => {
                hoverRef.current = i;
                setHoverState(i);
                wake();
              }}
              onBlur={() => {
                if (hoverRef.current === i) {
                  hoverRef.current = -1;
                  setHoverState(-1);
                  wake();
                }
              }}
              onClick={() => selectNode(i)}
            >
              {n.title}
              {n.kind ? ` (${n.kind})` : ""}
            </button>
          </li>
        ))}
      </ul>

      {/* Stats chrome (www tokens). */}
      {!isEmpty && (
        <div className="pointer-events-none absolute bottom-2 left-2 rounded bg-[color:var(--color-surface-hover)] px-2 py-1 text-xs text-[color:var(--color-text-tertiary)]">
          {graph.nodes.length} {graph.nodes.length === 1 ? "entity" : "entities"} ·{" "}
          {graph.edges.length} {graph.edges.length === 1 ? "link" : "links"}
          {hoverState >= 0 && graph.nodes[hoverState] ? (
            <span className="text-[color:var(--color-text-secondary)]">
              {" · "}
              {graph.nodes[hoverState]!.title}
            </span>
          ) : null}
        </div>
      )}

      {isLoading && (
        <div className="absolute inset-0 flex items-center justify-center text-[color:var(--color-text-tertiary)]">
          <Loader2 className="mr-2 h-4 w-4 animate-spin" aria-hidden />
          <span className="text-sm">Building graph…</span>
        </div>
      )}

      {isEmpty && !isLoading && (
        <div className="absolute inset-0 flex flex-col items-center justify-center gap-2 text-[color:var(--color-text-tertiary)]">
          <Workflow className="h-8 w-8 opacity-50" aria-hidden />
          <span className="text-sm">No entities to graph yet.</span>
        </div>
      )}
    </div>
  );
}
