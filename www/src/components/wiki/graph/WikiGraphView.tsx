import * as React from "react";
import { Loader2, Workflow } from "lucide-react";
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
/** Show labels once we've zoomed past this. */
const LABEL_THRESHOLD = 1.1;
/** Stop the rAF loop when alpha drops below this AND nothing is animating. */
const COOL_ALPHA = 0.005;

const NODE_SIZE = 5;
const LINK_THICKNESS = 1;
const LABEL_SIZE = 11;

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
  const graph = useWikiGraph({ seedEntityId, depth });

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

  const rafRef = React.useRef(0);
  const draggingRef = React.useRef<{
    startX: number;
    startY: number;
    viewX: number;
    viewY: number;
    moved: boolean;
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
    // Re-tint existing draw nodes if we already have a graph.
    const nodes = graph.nodes;
    const dn = drawNodesRef.current;
    for (let i = 0; i < dn.length; i++) {
      const kind = nodes[i]?.kind ?? "";
      (dn[i] as DrawNode).color = kindMap.get(kind) ?? kindMap.get("") ?? "#888888";
    }
  }, [graph.nodes]);

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

    const sim = new ForceSimulation(simNodes, simEdges, { alphaDecay: 0.04, damping: 0.6 });
    simRef.current = sim;
    drawEdgesRef.current = drawEdges;
    neighborSetsRef.current = neighborSets;
    neighborMaskRef.current = new Uint8Array(nodes.length);

    const kindMap = kindColorRef.current;
    drawNodesRef.current = nodes.map((n, i) => ({
      x: sim.xAt(i),
      y: sim.yAt(i),
      color: kindMap.get(n.kind ?? "") ?? kindMap.get("") ?? "#888888",
      weight: n.weight ?? 1,
      label: n.title,
    }));

    // Seed node starts selected/centred.
    selectedIndexRef.current = seedEntityId ? (idToIndex.get(seedEntityId) ?? -1) : -1;
    hoverRef.current = -1;
    setHoverState(-1);
    viewRef.current = { x: 0, y: 0, scale: 1 };
  }, [graph, seedEntityId]);

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
      drawGraph(ctx, {
        size: sizeRef.current,
        dpr: dprRef.current,
        transform: viewRef.current,
        nodes: drawNodesRef.current,
        edges: drawEdgesRef.current,
        hoveredIndex: hovered,
        selectedIndex: selectedIndexRef.current,
        neighborMask: mask,
        nodeSize: NODE_SIZE,
        linkThickness: LINK_THICKNESS,
        labelSize: LABEL_SIZE,
        showLabels: viewRef.current.scale > LABEL_THRESHOLD,
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
      if (hot || draggingRef.current) {
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
      const hitR = (NODE_SIZE * 3) / Math.max(0.7, viewRef.current.scale);
      const hit = sim.hitTest(world.x, world.y, hitR);
      return hit ? hit.index : -1;
    },
    [screenToWorld],
  );

  // --- Pointer handlers.
  const onMouseDown = (e: React.MouseEvent) => {
    if (e.button !== 0) return;
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
    const drag = draggingRef.current;
    draggingRef.current = null;
    if (drag && !drag.moved) {
      const idx = hitTest(e.clientX, e.clientY);
      if (idx >= 0) selectNode(idx);
    }
    wake();
  };

  const onMouseLeave = () => {
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
