// WikiCanvasView — an infinite pan/zoom whiteboard rendered over a wiki page.
//
// Storage: the board is persisted as JSON inside a WikiPage body via
// `useCanvasDoc` (see canvasSchema.ts). This component owns *interaction*: pan,
// zoom, select, marquee, drag-to-move (grid-snapped), resize, edge drawing, and
// node CRUD. Persistence is fire-and-forget through `setCanvas`.
//
// Performance: there is a single world→screen transform (`{x,y,scale}`) applied
// to one absolutely-positioned layer; individual nodes are NOT re-laid-out per
// frame. Live drag / pan / resize mutate refs and write `transform` strings
// directly to the relevant DOM nodes via rAF, committing to React state only on
// mouse-up. Edges are SVG beziers between node sides.
//
// Theme: card / accent colours come from CSS custom properties resolved with
// getComputedStyle (an SVG/Canvas-ish surface can't rely on Tailwind classes for
// the swatch palette), with sensible fallbacks.

import * as React from "react";
import {
  ArrowLeft,
  ArrowRight,
  FileText,
  Frame,
  Link as LinkIcon,
  Magnet,
  Maximize2,
  Minus,
  MoveHorizontal,
  Trash2,
  Type as TypeIcon,
  ZoomIn,
  ZoomOut,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage } from "@/runtime/connector";
import { Button } from "@/components/ui/button";
import {
  type Canvas,
  type CanvasEdge,
  type CanvasNode,
  type EdgeSide,
  type NodeType,
  newCanvasId,
  cloneSelection,
  edgeEnds,
} from "./canvasSchema";
import { useCanvasDoc } from "./useCanvasDoc";
import {
  GRID,
  COLOR_MAP,
  snap,
  sideAnchor,
  nearestSide,
  rectsIntersect,
  colorRgb,
  edgePath,
  edgeMidpoint,
  edgeStroke,
} from "./canvasGeometry";
import { type View, ToolButton, CanvasNodeView, CanvasMinimap } from "./canvasComponents";

export interface WikiCanvasViewProps {
  pageId: string;
  /**
   * Optional: open a wiki page (e.g. router push) on page-card double-click.
   * The second arg is the node's optional in-page fragment ("#heading" /
   * "#^block") so the caller can scroll to it. Backward-compatible with a
   * `(id: string) => void` consumer (extra arg ignored).
   */
  onOpenPage?: (pageId: string, subpath?: string) => void;
  className?: string;
}

const MIN_W = 80;
const MIN_H = 48;
const SCALE_MIN = 0.2;
const SCALE_MAX = 3;
const COLOR_SWATCHES: Array<string | null> = [null, "1", "2", "3", "4", "5", "6"];

// ── component ───────────────────────────────────────────────────────────────

export function WikiCanvasView({ pageId, onOpenPage, className }: WikiCanvasViewProps) {
  const { canvas, status, title, canSave, saveState, setCanvas } = useCanvasDoc(pageId);

  const [view, setView] = React.useState<View>({ x: 0, y: 0, scale: 1 });
  const [selected, setSelected] = React.useState<string[]>([]);
  const [selectedEdge, setSelectedEdge] = React.useState<string | null>(null);
  const [editingId, setEditingId] = React.useState<string | null>(null);
  const [snapOn, setSnapOn] = React.useState(true);
  const [marquee, setMarquee] = React.useState<{
    x: number;
    y: number;
    w: number;
    h: number;
  } | null>(null);
  const [edgeDraftEnd, setEdgeDraftEnd] = React.useState<{ x: number; y: number } | null>(null);

  const containerRef = React.useRef<HTMLDivElement>(null);
  const worldRef = React.useRef<HTMLDivElement>(null);
  const svgGroupRef = React.useRef<SVGGElement>(null);

  // Mirror reactive bits into refs for the document-level handlers.
  const canvasRef = React.useRef<Canvas>(canvas);
  const viewRef = React.useRef<View>(view);
  const selectedRef = React.useRef<string[]>(selected);
  const selectedEdgeRef = React.useRef<string | null>(selectedEdge);
  const snapRef = React.useRef(snapOn);
  React.useEffect(() => void (canvasRef.current = canvas), [canvas]);
  React.useEffect(() => void (viewRef.current = view), [view]);
  React.useEffect(() => void (selectedRef.current = selected), [selected]);
  React.useEffect(() => void (selectedEdgeRef.current = selectedEdge), [selectedEdge]);
  React.useEffect(() => void (snapRef.current = snapOn), [snapOn]);

  // Interaction state (refs only — never trigger re-render mid-gesture).
  const panRef = React.useRef<{ x: number; y: number; vx: number; vy: number } | null>(null);
  const dragRef = React.useRef<{
    sx: number;
    sy: number;
    nodes: Array<{ id: string; x: number; y: number }>;
  } | null>(null);
  const resizeRef = React.useRef<{ id: string; sx: number; sy: number; w: number; h: number } | null>(
    null,
  );
  const marqueeRef = React.useRef<{ x: number; y: number; append: boolean } | null>(null);
  const edgeDraftRef = React.useRef<{ fromId: string; fromSide: EdgeSide } | null>(null);
  const rafRef = React.useRef(0);

  // Resolve theme colours once (and on theme flips via observer below).
  const [resolvedColors, setResolvedColors] = React.useState<Record<string, string>>({});
  React.useEffect(() => {
    const resolve = () => {
      const cs = getComputedStyle(document.documentElement);
      const map: Record<string, string> = {};
      for (const k of Object.keys(COLOR_MAP)) {
        const named = ["red", "orange", "yellow", "green", "cyan", "purple"][Number(k) - 1];
        const v = cs.getPropertyValue(`--color-${named}-rgb`).trim();
        if (v) map[k] = v;
      }
      setResolvedColors(map);
    };
    resolve();
    const obs = new MutationObserver(resolve);
    obs.observe(document.documentElement, { attributes: true, attributeFilter: ["class"] });
    return () => obs.disconnect();
  }, []);

  // ── world<->screen ──
  const screenToWorld = React.useCallback((clientX: number, clientY: number) => {
    const rect = containerRef.current?.getBoundingClientRect();
    const v = viewRef.current;
    if (!rect) return null;
    return {
      x: (clientX - rect.left - v.x) / v.scale,
      y: (clientY - rect.top - v.y) / v.scale,
    };
  }, []);

  // Imperatively write the live transform during pan (no React re-render).
  const applyViewTransform = React.useCallback((v: View) => {
    const t = `translate(${v.x}px, ${v.y}px) scale(${v.scale})`;
    if (worldRef.current) worldRef.current.style.transform = t;
    if (svgGroupRef.current)
      svgGroupRef.current.setAttribute("transform", `translate(${v.x}, ${v.y}) scale(${v.scale})`);
    const c = containerRef.current;
    if (c) {
      c.style.backgroundSize = `${GRID * v.scale}px ${GRID * v.scale}px`;
      c.style.backgroundPosition = `${v.x}px ${v.y}px`;
    }
  }, []);

  // ── canvas mutation helpers ──
  const mutate = React.useCallback(
    (next: Canvas) => {
      canvasRef.current = next;
      setCanvas(next);
    },
    [setCanvas],
  );

  const updateNode = React.useCallback(
    (id: string, patch: Partial<CanvasNode>) => {
      mutate({
        ...canvasRef.current,
        nodes: canvasRef.current.nodes.map((n) => (n.id === id ? { ...n, ...patch } : n)),
      });
    },
    [mutate],
  );

  const deleteSelected = React.useCallback(() => {
    const ids = new Set(selectedRef.current);
    if (ids.size === 0) return;
    mutate({
      nodes: canvasRef.current.nodes.filter((n) => !ids.has(n.id)),
      edges: canvasRef.current.edges.filter((e) => !ids.has(e.fromNode) && !ids.has(e.toNode)),
    });
    setSelected([]);
  }, [mutate]);

  const setNodeColor = React.useCallback(
    (id: string, color: string | null) => {
      mutate({
        ...canvasRef.current,
        nodes: canvasRef.current.nodes.map((n) => {
          if (n.id !== id) return n;
          if (color === null) {
            const { color: _omit, ...rest } = n;
            return rest;
          }
          return { ...n, color };
        }),
      });
    },
    [mutate],
  );

  const updateEdge = React.useCallback(
    (id: string, patch: Partial<CanvasEdge>) => {
      mutate({
        ...canvasRef.current,
        edges: canvasRef.current.edges.map((e) => (e.id === id ? { ...e, ...patch } : e)),
      });
    },
    [mutate],
  );

  // Cycle an edge through the four end configurations (parity with Obsidian's
  // edge-direction control): →  |  ←  |  ↔  |  —  (none). Persists fromEnd/toEnd
  // explicitly so the chosen state round-trips.
  const cycleEdgeDirection = React.useCallback(
    (id: string) => {
      const e = canvasRef.current.edges.find((x) => x.id === id);
      if (!e) return;
      const { fromEnd, toEnd } = edgeEnds(e);
      // none/arrow → arrow/arrow → arrow/none → none/none → (loop) none/arrow
      let next: { fromEnd: "none" | "arrow"; toEnd: "none" | "arrow" };
      if (fromEnd === "none" && toEnd === "arrow") next = { fromEnd: "arrow", toEnd: "arrow" };
      else if (fromEnd === "arrow" && toEnd === "arrow") next = { fromEnd: "arrow", toEnd: "none" };
      else if (fromEnd === "arrow" && toEnd === "none") next = { fromEnd: "none", toEnd: "none" };
      else next = { fromEnd: "none", toEnd: "arrow" };
      updateEdge(id, next);
    },
    [updateEdge],
  );

  // Add a node centered in the current viewport.
  const addNode = React.useCallback(
    (type: NodeType) => {
      const rect = containerRef.current?.getBoundingClientRect();
      const v = viewRef.current;
      if (!rect) return;
      const cx = (rect.width / 2 - v.x) / v.scale;
      const cy = (rect.height / 2 - v.y) / v.scale;
      const w = type === "group" ? 320 : 240;
      const h = type === "group" ? 220 : type === "text" ? 100 : 120;
      const node: CanvasNode = {
        id: newCanvasId(),
        type,
        x: snap(cx - w / 2, snapRef.current),
        y: snap(cy - h / 2, snapRef.current),
        w,
        h,
        ...(type === "text" ? { text: "" } : {}),
        ...(type === "group" ? { label: "Group" } : {}),
        ...(type === "page" ? { pageId: "" } : {}),
        ...(type === "link" ? { url: "" } : {}),
      };
      mutate({ ...canvasRef.current, nodes: [...canvasRef.current.nodes, node] });
      setSelected([node.id]);
      if (type === "text") setEditingId(node.id);
    },
    [mutate],
  );

  // ── fit-to-content / initial centering ──
  const fitToContent = React.useCallback((c: Canvas) => {
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return;
    if (c.nodes.length === 0) {
      const v = { x: rect.width / 2, y: rect.height / 2, scale: 1 };
      setView(v);
      applyViewTransform(v);
      return;
    }
    let minX = Infinity;
    let minY = Infinity;
    let maxX = -Infinity;
    let maxY = -Infinity;
    for (const n of c.nodes) {
      minX = Math.min(minX, n.x);
      minY = Math.min(minY, n.y);
      maxX = Math.max(maxX, n.x + n.w);
      maxY = Math.max(maxY, n.y + n.h);
    }
    const w = Math.max(1, maxX - minX);
    const h = Math.max(1, maxY - minY);
    const pad = 80;
    const scale = Math.max(
      SCALE_MIN,
      Math.min(1, (rect.width - pad) / w, (rect.height - pad) / h),
    );
    const v = {
      x: rect.width / 2 - ((minX + maxX) / 2) * scale,
      y: rect.height / 2 - ((minY + maxY) / 2) * scale,
      scale,
    };
    setView(v);
    applyViewTransform(v);
  }, [applyViewTransform]);

  // Center the viewport on a world-space point (used by the minimap click/drag),
  // preserving the current zoom.
  const panToWorld = React.useCallback((wx: number, wy: number) => {
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return;
    const v = viewRef.current;
    const nv = { ...v, x: rect.width / 2 - wx * v.scale, y: rect.height / 2 - wy * v.scale };
    setView(nv);
    applyViewTransform(nv);
  }, [applyViewTransform]);

  // Fit once when the document first becomes ready.
  const fittedRef = React.useRef(false);
  React.useEffect(() => {
    if (status === "ready" && !fittedRef.current) {
      fittedRef.current = true;
      requestAnimationFrame(() => fitToContent(canvasRef.current));
    }
    if (status !== "ready") fittedRef.current = false;
  }, [status, fitToContent]);

  // ── document-level pointer lifecycle ──
  React.useEffect(() => {
    const onMove = (ev: MouseEvent) => {
      const v = viewRef.current;

      // Edge draft.
      if (edgeDraftRef.current) {
        const p = screenToWorld(ev.clientX, ev.clientY);
        if (p) setEdgeDraftEnd(p);
        return;
      }

      // Resize.
      const rs = resizeRef.current;
      if (rs) {
        const dx = (ev.clientX - rs.sx) / v.scale;
        const dy = (ev.clientY - rs.sy) / v.scale;
        const nw = Math.max(MIN_W, snap(rs.w + dx, snapRef.current));
        const nh = Math.max(MIN_H, snap(rs.h + dy, snapRef.current));
        const el = worldRef.current?.querySelector<HTMLElement>(`[data-node="${rs.id}"]`);
        if (el) {
          el.style.width = `${nw}px`;
          el.style.height = `${nh}px`;
        }
        return;
      }

      // Marquee.
      const mq = marqueeRef.current;
      if (mq) {
        const end = screenToWorld(ev.clientX, ev.clientY);
        if (!end) return;
        const r = {
          x: Math.min(mq.x, end.x),
          y: Math.min(mq.y, end.y),
          w: Math.abs(end.x - mq.x),
          h: Math.abs(end.y - mq.y),
        };
        setMarquee(r);
        const hit = canvasRef.current.nodes
          .filter((n) => rectsIntersect(r, { x: n.x, y: n.y, w: n.w, h: n.h }))
          .map((n) => n.id);
        setSelected(mq.append ? Array.from(new Set([...selectedRef.current, ...hit])) : hit);
        return;
      }

      // Drag move — imperatively translate selected node elements.
      const dr = dragRef.current;
      if (dr) {
        let dx = (ev.clientX - dr.sx) / v.scale;
        let dy = (ev.clientY - dr.sy) / v.scale;
        if (ev.shiftKey) {
          if (Math.abs(dx) >= Math.abs(dy)) dy = 0;
          else dx = 0;
        }
        for (const start of dr.nodes) {
          const nx = snap(start.x + dx, snapRef.current);
          const ny = snap(start.y + dy, snapRef.current);
          const el = worldRef.current?.querySelector<HTMLElement>(`[data-node="${start.id}"]`);
          if (el) {
            el.style.left = `${nx}px`;
            el.style.top = `${ny}px`;
          }
        }
        // Live-update edges attached to dragged nodes.
        if (rafRef.current) cancelAnimationFrame(rafRef.current);
        rafRef.current = requestAnimationFrame(() => redrawDraggedEdges(dr, ev, v));
        return;
      }

      // Pan.
      const pn = panRef.current;
      if (pn) {
        const nv = { ...viewRef.current, x: pn.vx + (ev.clientX - pn.x), y: pn.vy + (ev.clientY - pn.y) };
        viewRef.current = nv;
        applyViewTransform(nv);
      }
    };

    // Recompute the on-screen position of edges touching dragged nodes.
    const redrawDraggedEdges = (
      dr: NonNullable<typeof dragRef.current>,
      ev: MouseEvent,
      v: View,
    ) => {
      const moved = new Map<string, { x: number; y: number }>();
      let dx = (ev.clientX - dr.sx) / v.scale;
      let dy = (ev.clientY - dr.sy) / v.scale;
      if (ev.shiftKey) {
        if (Math.abs(dx) >= Math.abs(dy)) dy = 0;
        else dx = 0;
      }
      for (const s of dr.nodes) {
        moved.set(s.id, { x: snap(s.x + dx, snapRef.current), y: snap(s.y + dy, snapRef.current) });
      }
      for (const e of canvasRef.current.edges) {
        const path = svgGroupRef.current?.querySelector<SVGPathElement>(`[data-edge="${e.id}"]`);
        if (!path) continue;
        const a = canvasRef.current.nodes.find((n) => n.id === e.fromNode);
        const b = canvasRef.current.nodes.find((n) => n.id === e.toNode);
        if (!a || !b) continue;
        const an = moved.has(a.id) ? { ...a, ...moved.get(a.id) } : a;
        const bn = moved.has(b.id) ? { ...b, ...moved.get(b.id) } : b;
        path.setAttribute("d", edgePath(an, bn, e));
      }
    };

    const onUp = (ev: MouseEvent) => {
      const v = viewRef.current;

      // Finalize edge draft.
      const draft = edgeDraftRef.current;
      if (draft) {
        edgeDraftRef.current = null;
        setEdgeDraftEnd(null);
        const target = ev.target as HTMLElement | null;
        const anchor = target?.closest<HTMLElement>("[data-anchor-node]");
        const nodeEl = target?.closest<HTMLElement>("[data-node]");
        const toId =
          anchor?.getAttribute("data-anchor-node") ?? nodeEl?.getAttribute("data-node") ?? null;
        if (toId && toId !== draft.fromId) {
          const toNode = canvasRef.current.nodes.find((n) => n.id === toId);
          let toSide: EdgeSide | undefined =
            (anchor?.getAttribute("data-anchor-side") as EdgeSide | null) ?? undefined;
          if (!toSide && toNode) {
            const p = screenToWorld(ev.clientX, ev.clientY);
            if (p) toSide = nearestSide(toNode, p.x, p.y);
          }
          const edge: CanvasEdge = {
            id: newCanvasId(),
            fromNode: draft.fromId,
            toNode: toId,
            fromSide: draft.fromSide,
            ...(toSide ? { toSide } : {}),
          };
          mutate({ ...canvasRef.current, edges: [...canvasRef.current.edges, edge] });
        }
      }

      // Commit drag to state.
      const dr = dragRef.current;
      if (dr) {
        let dx = (ev.clientX - dr.sx) / v.scale;
        let dy = (ev.clientY - dr.sy) / v.scale;
        if (ev.shiftKey) {
          if (Math.abs(dx) >= Math.abs(dy)) dy = 0;
          else dx = 0;
        }
        if (dx !== 0 || dy !== 0) {
          const starts = new Map(dr.nodes.map((s) => [s.id, s]));
          mutate({
            ...canvasRef.current,
            nodes: canvasRef.current.nodes.map((n) => {
              const s = starts.get(n.id);
              if (!s) return n;
              return { ...n, x: snap(s.x + dx, snapRef.current), y: snap(s.y + dy, snapRef.current) };
            }),
          });
        }
      }

      // Commit resize to state.
      const rs = resizeRef.current;
      if (rs) {
        const dx = (ev.clientX - rs.sx) / v.scale;
        const dy = (ev.clientY - rs.sy) / v.scale;
        const nw = Math.max(MIN_W, snap(rs.w + dx, snapRef.current));
        const nh = Math.max(MIN_H, snap(rs.h + dy, snapRef.current));
        updateNode(rs.id, { w: nw, h: nh });
      }

      // Commit pan to state.
      if (panRef.current) setView(viewRef.current);

      panRef.current = null;
      dragRef.current = null;
      resizeRef.current = null;
      marqueeRef.current = null;
      setMarquee(null);
    };

    document.addEventListener("mousemove", onMove);
    document.addEventListener("mouseup", onUp);
    return () => {
      document.removeEventListener("mousemove", onMove);
      document.removeEventListener("mouseup", onUp);
      if (rafRef.current) cancelAnimationFrame(rafRef.current);
    };
  }, [screenToWorld, applyViewTransform, mutate, updateNode]);

  // ── background / wheel / node handlers ──
  const onBackgroundMouseDown = (e: React.MouseEvent) => {
    const target = e.target as HTMLElement;
    if (target.closest("[data-node]") || target.closest("[data-anchor-node]")) return;
    // Middle-drag or space-drag pans; shift-drag marquees; plain click pans.
    if (e.button === 1 || (e.button === 0 && spaceHeldRef.current)) {
      e.preventDefault();
      panRef.current = { x: e.clientX, y: e.clientY, vx: viewRef.current.x, vy: viewRef.current.y };
      return;
    }
    if (e.button !== 0) return;
    if (e.shiftKey) {
      const start = screenToWorld(e.clientX, e.clientY);
      if (!start) return;
      const append = e.metaKey || e.ctrlKey;
      marqueeRef.current = { x: start.x, y: start.y, append };
      setMarquee({ x: start.x, y: start.y, w: 0, h: 0 });
      if (!append) setSelected([]);
      return;
    }
    panRef.current = { x: e.clientX, y: e.clientY, vx: viewRef.current.x, vy: viewRef.current.y };
    setSelected([]);
    setSelectedEdge(null);
    setEditingId(null);
  };

  const onWheel = (e: React.WheelEvent) => {
    // Zoom toward the cursor.
    e.preventDefault();
    const rect = containerRef.current?.getBoundingClientRect();
    if (!rect) return;
    const v = viewRef.current;
    const factor = e.deltaY > 0 ? 0.9 : 1.1;
    const nextScale = Math.max(SCALE_MIN, Math.min(SCALE_MAX, v.scale * factor));
    const mx = e.clientX - rect.left;
    const my = e.clientY - rect.top;
    // Keep the world point under the cursor fixed.
    const wx = (mx - v.x) / v.scale;
    const wy = (my - v.y) / v.scale;
    const nv = { scale: nextScale, x: mx - wx * nextScale, y: my - wy * nextScale };
    viewRef.current = nv;
    applyViewTransform(nv);
    setView(nv);
  };

  // Track Space for space-drag panning.
  const spaceHeldRef = React.useRef(false);
  React.useEffect(() => {
    const down = (e: KeyboardEvent) => {
      const t = e.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      if (e.code === "Space") spaceHeldRef.current = true;
    };
    const up = (e: KeyboardEvent) => {
      if (e.code === "Space") spaceHeldRef.current = false;
    };
    window.addEventListener("keydown", down);
    window.addEventListener("keyup", up);
    return () => {
      window.removeEventListener("keydown", down);
      window.removeEventListener("keyup", up);
    };
  }, []);

  const onNodeMouseDown = (e: React.MouseEvent, node: CanvasNode) => {
    if (e.button !== 0 || spaceHeldRef.current) return;
    e.stopPropagation();
    setSelectedEdge(null);
    const sel = selectedRef.current.includes(node.id)
      ? selectedRef.current
      : e.shiftKey
        ? [...selectedRef.current, node.id]
        : [node.id];
    setSelected(sel);
    const starts = canvasRef.current.nodes
      .filter((n) => sel.includes(n.id))
      .map((n) => ({ id: n.id, x: n.x, y: n.y }));
    dragRef.current = { sx: e.clientX, sy: e.clientY, nodes: starts };
  };

  const onResizeStart = (e: React.MouseEvent, node: CanvasNode) => {
    e.stopPropagation();
    e.preventDefault();
    setSelected([node.id]);
    resizeRef.current = { id: node.id, sx: e.clientX, sy: e.clientY, w: node.w, h: node.h };
  };

  const onAnchorMouseDown = (e: React.MouseEvent, node: CanvasNode, side: EdgeSide) => {
    e.stopPropagation();
    e.preventDefault();
    edgeDraftRef.current = { fromId: node.id, fromSide: side };
    const p = screenToWorld(e.clientX, e.clientY);
    if (p) setEdgeDraftEnd(p);
  };

  // Clipboard for canvas copy/paste (in-app, not the OS clipboard). The paste
  // offset grows per consecutive paste so repeated ⌘V cascades instead of
  // stacking exactly.
  const clipboardRef = React.useRef<{ nodes: CanvasNode[]; edges: CanvasEdge[] } | null>(null);
  const pasteOffsetRef = React.useRef(0);

  const duplicateSelection = React.useCallback(
    (ids: ReadonlySet<string>) => {
      if (ids.size === 0) return;
      const c = canvasRef.current;
      const cloned = cloneSelection(c.nodes, c.edges, ids, GRID, newCanvasId);
      if (cloned.nodes.length === 0) return;
      mutate({ nodes: [...c.nodes, ...cloned.nodes], edges: [...c.edges, ...cloned.edges] });
      setSelected(cloned.newIds);
    },
    [mutate],
  );

  // ── keyboard: copy/paste/duplicate + delete + arrow nudge ──
  React.useEffect(() => {
    const onKey = (ev: KeyboardEvent) => {
      const t = ev.target as HTMLElement | null;
      if (t && (t.tagName === "INPUT" || t.tagName === "TEXTAREA")) return;
      const mod = ev.metaKey || ev.ctrlKey;
      // Cmd-V pastes even with nothing selected (it places the clipboard).
      // Repeated pastes CASCADE (offset grows each time) so they don't stack
      // exactly on top of one another (Obsidian parity).
      if (mod && ev.key.toLowerCase() === "v" && clipboardRef.current) {
        ev.preventDefault();
        const c = canvasRef.current;
        const ids = new Set(clipboardRef.current.nodes.map((n) => n.id));
        pasteOffsetRef.current += GRID;
        const pasted = cloneSelection(clipboardRef.current.nodes, clipboardRef.current.edges, ids, pasteOffsetRef.current, newCanvasId);
        if (pasted.nodes.length > 0) {
          mutate({ nodes: [...c.nodes, ...pasted.nodes], edges: [...c.edges, ...pasted.edges] });
          setSelected(pasted.newIds);
        }
        return;
      }
      // Edge-only selection: delete the selected edge.
      if (selectedRef.current.length === 0) {
        const eid = selectedEdgeRef.current;
        if (eid && (ev.key === "Backspace" || ev.key === "Delete")) {
          ev.preventDefault();
          mutate({
            ...canvasRef.current,
            edges: canvasRef.current.edges.filter((e) => e.id !== eid),
          });
          setSelectedEdge(null);
        }
        return;
      }
      const sel = new Set(selectedRef.current);
      if (mod && ev.key.toLowerCase() === "c") {
        ev.preventDefault();
        const c = canvasRef.current;
        clipboardRef.current = {
          nodes: c.nodes.filter((n) => sel.has(n.id)),
          edges: c.edges.filter((e) => sel.has(e.fromNode) && sel.has(e.toNode)),
        };
        pasteOffsetRef.current = 0; // fresh copy → next paste starts one grid out
        return;
      }
      if (mod && ev.key.toLowerCase() === "d") {
        ev.preventDefault();
        duplicateSelection(sel);
        return;
      }
      if (ev.key === "Backspace" || ev.key === "Delete") {
        ev.preventDefault();
        deleteSelected();
        return;
      }
      // Nudge: 1px fine step; Shift accelerates by ×5 (or, when snap is on, a
      // full grid jump — whichever moves further, so Shift always feels coarser
      // than a plain press regardless of grid size).
      const fine = 1;
      const step = ev.shiftKey
        ? snapRef.current
          ? Math.max(GRID, fine * 5)
          : fine * 5
        : fine;
      let dx = 0;
      let dy = 0;
      if (ev.key === "ArrowLeft") dx = -step;
      else if (ev.key === "ArrowRight") dx = step;
      else if (ev.key === "ArrowUp") dy = -step;
      else if (ev.key === "ArrowDown") dy = step;
      if (dx || dy) {
        ev.preventDefault();
        const ids = new Set(selectedRef.current);
        mutate({
          ...canvasRef.current,
          nodes: canvasRef.current.nodes.map((n) =>
            ids.has(n.id) ? { ...n, x: n.x + dx, y: n.y + dy } : n,
          ),
        });
      }
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [deleteSelected, mutate, duplicateSelection]);

  const selectedNode =
    selected.length === 1 ? (canvas.nodes.find((n) => n.id === selected[0]) ?? null) : null;
  const selectedEdgeObj = selectedEdge
    ? (canvas.edges.find((e) => e.id === selectedEdge) ?? null)
    : null;
  const selectedEnds = selectedEdgeObj ? edgeEnds(selectedEdgeObj) : null;

  // ── render ──
  if (status === "missing") {
    return (
      <div className={cn("flex h-full items-center justify-center text-muted-foreground", className)}>
        Canvas not found.
      </div>
    );
  }
  if (status === "error") {
    return (
      <div className={cn("flex h-full items-center justify-center text-destructive", className)}>
        Failed to load canvas.
      </div>
    );
  }

  return (
    <div
      ref={containerRef}
      className={cn("relative h-full w-full select-none overflow-hidden bg-background", className)}
      style={{
        backgroundImage:
          "radial-gradient(circle, color-mix(in srgb, var(--foreground) 12%, transparent) 1px, transparent 1px)",
        backgroundSize: `${GRID * view.scale}px ${GRID * view.scale}px`,
        backgroundPosition: `${view.x}px ${view.y}px`,
        cursor: spaceHeldRef.current ? "grab" : "default",
      }}
      onMouseDown={onBackgroundMouseDown}
      onWheel={onWheel}
    >
      {status === "loading" ? (
        <div className="absolute inset-0 flex items-center justify-center text-muted-foreground">
          Loading canvas…
        </div>
      ) : null}

      {/* Edge layer (SVG bezier paths) */}
      <svg className="pointer-events-none absolute inset-0 h-full w-full" aria-hidden>
        <defs>
          {/* End marker (points along the path toward the target). */}
          <marker
            id="wiki-canvas-arrow"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--muted-foreground)" />
          </marker>
          {/* Start marker: same geometry; `auto-start-reverse` flips it so it
              points back toward the source when used as markerStart. */}
          <marker
            id="wiki-canvas-arrow-start"
            viewBox="0 0 10 10"
            refX="9"
            refY="5"
            markerWidth="6"
            markerHeight="6"
            orient="auto-start-reverse"
          >
            <path d="M 0 0 L 10 5 L 0 10 z" fill="var(--muted-foreground)" />
          </marker>
        </defs>
        <g ref={svgGroupRef} transform={`translate(${view.x}, ${view.y}) scale(${view.scale})`}>
          {canvas.edges.map((e) => {
            const a = canvas.nodes.find((n) => n.id === e.fromNode);
            const b = canvas.nodes.find((n) => n.id === e.toNode);
            if (!a || !b) return null;
            const stroke = edgeStroke(e, resolvedColors);
            const mid = edgeMidpoint(a, b, e);
            const ends = edgeEnds(e);
            const isSel = selectedEdge === e.id;
            const d = edgePath(a, b, e);
            return (
              <g key={e.id}>
                {/* Wide transparent hit area so the thin edge is easy to click. */}
                <path
                  d={d}
                  fill="none"
                  stroke="transparent"
                  strokeWidth={14}
                  style={{ pointerEvents: "stroke", cursor: "pointer" }}
                  onMouseDown={(ev) => {
                    ev.stopPropagation();
                    setSelected([]);
                    setSelectedEdge(e.id);
                  }}
                  onDoubleClick={(ev) => {
                    ev.stopPropagation();
                    cycleEdgeDirection(e.id);
                  }}
                />
                <path
                  data-edge={e.id}
                  d={d}
                  fill="none"
                  stroke={isSel ? "var(--primary)" : stroke}
                  strokeWidth={isSel ? 2.5 : 1.5}
                  style={{ pointerEvents: "none" }}
                  markerStart={
                    ends.fromEnd === "arrow" ? "url(#wiki-canvas-arrow-start)" : undefined
                  }
                  markerEnd={ends.toEnd === "arrow" ? "url(#wiki-canvas-arrow)" : undefined}
                />
                {e.label ? (
                  <text
                    x={mid.x}
                    y={mid.y - 4}
                    textAnchor="middle"
                    fontSize={11}
                    fill="var(--muted-foreground)"
                    style={{ userSelect: "none" }}
                  >
                    {e.label}
                  </text>
                ) : null}
              </g>
            );
          })}
          {edgeDraftEnd && edgeDraftRef.current
            ? (() => {
                const src = canvas.nodes.find((n) => n.id === edgeDraftRef.current?.fromId);
                if (!src) return null;
                const p1 = sideAnchor(src, edgeDraftRef.current.fromSide);
                return (
                  <line
                    x1={p1.x}
                    y1={p1.y}
                    x2={edgeDraftEnd.x}
                    y2={edgeDraftEnd.y}
                    stroke="var(--primary)"
                    strokeWidth={1.5}
                    strokeDasharray="6 4"
                  />
                );
              })()
            : null}
        </g>
      </svg>

      {/* Node layer */}
      <div
        ref={worldRef}
        className="pointer-events-none absolute inset-0 origin-top-left"
        style={{ transform: `translate(${view.x}px, ${view.y}px) scale(${view.scale})` }}
      >
        {canvas.nodes.map((node) => (
          <CanvasNodeView
            key={node.id}
            node={node}
            selected={selected.includes(node.id)}
            editing={editingId === node.id}
            colors={resolvedColors}
            onMouseDown={(e) => onNodeMouseDown(e, node)}
            onResizeStart={(e) => onResizeStart(e, node)}
            onAnchorMouseDown={(e, side) => onAnchorMouseDown(e, node, side)}
            onTextCommit={(text) => {
              if (node.text !== text) updateNode(node.id, { text });
              setEditingId(null);
            }}
            onTextCancel={() => setEditingId(null)}
            onStartEdit={() => setEditingId(node.id)}
            onOpenPage={onOpenPage}
          />
        ))}
        {marquee ? (
          <div
            className="pointer-events-none absolute box-border border border-primary"
            style={{
              left: marquee.x,
              top: marquee.y,
              width: marquee.w,
              height: marquee.h,
              background: "color-mix(in srgb, var(--primary) 12%, transparent)",
            }}
          />
        ) : null}
      </div>

      {/* Toolbar */}
      <div
        className="absolute right-3 top-3 z-10 flex items-center gap-1 rounded-lg border border-border bg-card/95 p-1 shadow-sm backdrop-blur"
        onMouseDown={(e) => e.stopPropagation()}
      >
        <ToolButton label="Add text" onClick={() => addNode("text")}>
          <TypeIcon className="size-4" />
        </ToolButton>
        <ToolButton label="Add page card" onClick={() => addNode("page")}>
          <FileText className="size-4" />
        </ToolButton>
        <ToolButton label="Add link" onClick={() => addNode("link")}>
          <LinkIcon className="size-4" />
        </ToolButton>
        <ToolButton label="Add group" onClick={() => addNode("group")}>
          <Frame className="size-4" />
        </ToolButton>
        <div className="mx-0.5 h-5 w-px bg-border" />
        <ToolButton
          label={snapOn ? "Snap: on" : "Snap: off"}
          active={snapOn}
          onClick={() => setSnapOn((s) => !s)}
        >
          <Magnet className="size-4" />
        </ToolButton>
        <ToolButton
          label="Zoom in"
          onClick={() => {
            const v = viewRef.current;
            const nv = { ...v, scale: Math.min(SCALE_MAX, v.scale * 1.2) };
            setView(nv);
            applyViewTransform(nv);
          }}
        >
          <ZoomIn className="size-4" />
        </ToolButton>
        <ToolButton
          label="Zoom out"
          onClick={() => {
            const v = viewRef.current;
            const nv = { ...v, scale: Math.max(SCALE_MIN, v.scale * 0.83) };
            setView(nv);
            applyViewTransform(nv);
          }}
        >
          <ZoomOut className="size-4" />
        </ToolButton>
        <ToolButton label="Fit to content" onClick={() => fitToContent(canvasRef.current)}>
          <Maximize2 className="size-4" />
        </ToolButton>
        {selectedNode ? (
          <>
            <div className="mx-0.5 h-5 w-px bg-border" />
            <div className="flex items-center gap-1 px-1" aria-label="Node color">
              {COLOR_SWATCHES.map((c) => {
                const rgb = c ? (resolvedColors[c] ?? COLOR_MAP[c]) : null;
                const active = (selectedNode.color ?? null) === c;
                return (
                  <button
                    key={c ?? "none"}
                    type="button"
                    aria-label={c ? `Color ${c}` : "No color"}
                    onClick={() => setNodeColor(selectedNode.id, c)}
                    className={cn(
                      "size-4 rounded-full border",
                      active ? "ring-2 ring-primary ring-offset-1 ring-offset-card" : "border-border",
                    )}
                    style={{ background: rgb ? `rgb(${rgb})` : "var(--secondary)" }}
                  />
                );
              })}
            </div>
          </>
        ) : null}
        {selectedEdgeObj && selectedEnds ? (
          <>
            <div className="mx-0.5 h-5 w-px bg-border" />
            <ToolButton
              label={
                selectedEnds.fromEnd === "arrow" && selectedEnds.toEnd === "arrow"
                  ? "Arrows: both"
                  : selectedEnds.fromEnd === "arrow"
                    ? "Arrow: from"
                    : selectedEnds.toEnd === "arrow"
                      ? "Arrow: to"
                      : "Arrows: none"
              }
              onClick={() => cycleEdgeDirection(selectedEdgeObj.id)}
            >
              {selectedEnds.fromEnd === "arrow" && selectedEnds.toEnd === "arrow" ? (
                <MoveHorizontal className="size-4" />
              ) : selectedEnds.fromEnd === "arrow" ? (
                <ArrowLeft className="size-4" />
              ) : selectedEnds.toEnd === "arrow" ? (
                <ArrowRight className="size-4" />
              ) : (
                <Minus className="size-4" />
              )}
            </ToolButton>
            <ToolButton
              label="Delete edge"
              danger
              onClick={() => {
                mutate({
                  ...canvasRef.current,
                  edges: canvasRef.current.edges.filter((e) => e.id !== selectedEdgeObj.id),
                });
                setSelectedEdge(null);
              }}
            >
              <Trash2 className="size-4" />
            </ToolButton>
          </>
        ) : null}
        {selected.length > 0 ? (
          <>
            <div className="mx-0.5 h-5 w-px bg-border" />
            <ToolButton label="Delete selection" onClick={deleteSelected} danger>
              <Trash2 className="size-4" />
            </ToolButton>
          </>
        ) : null}
      </div>

      {/* Status line */}
      <div className="pointer-events-none absolute bottom-2 left-3 z-10 flex items-center gap-2 text-[11px] text-muted-foreground">
        <span>{title || "Canvas"}</span>
        <span>·</span>
        <span>{Math.round(view.scale * 100)}%</span>
        <span>·</span>
        <span>
          {canvas.nodes.length} {canvas.nodes.length === 1 ? "node" : "nodes"}
        </span>
        {canSave ? (
          <span className="opacity-70">
            · {saveState === "saving" ? "saving…" : saveState === "dirty" ? "unsaved" : "saved"}
          </span>
        ) : (
          <span className="opacity-70">· read-only</span>
        )}
      </div>

      {/* Minimap overview navigator (bottom-right) */}
      <CanvasMinimap nodes={canvas.nodes} view={view} containerRef={containerRef} onPanTo={panToWorld} />
    </div>
  );
}
