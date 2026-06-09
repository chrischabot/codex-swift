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
  FileText,
  Frame,
  Link as LinkIcon,
  Magnet,
  Maximize2,
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
} from "./canvasSchema";
import { useCanvasDoc } from "./useCanvasDoc";

export interface WikiCanvasViewProps {
  pageId: string;
  /** Optional: open a wiki page (e.g. router push) on page-card double-click. */
  onOpenPage?: (pageId: string) => void;
  className?: string;
}

const GRID = 20;
const MIN_W = 80;
const MIN_H = 48;
const SCALE_MIN = 0.2;
const SCALE_MAX = 3;
const COLOR_SWATCHES: Array<string | null> = [null, "1", "2", "3", "4", "5", "6"];

// Swatch palette → rgb triplets (fallbacks; --color-*-rgb override if present).
const COLOR_MAP: Record<string, string> = {
  "1": "233, 49, 71",
  "2": "236, 117, 0",
  "3": "224, 172, 0",
  "4": "8, 185, 78",
  "5": "0, 191, 188",
  "6": "120, 82, 238",
};

interface View {
  x: number;
  y: number;
  scale: number;
}

// ── geometry helpers ────────────────────────────────────────────────────────

function snap(value: number, on: boolean): number {
  if (!Number.isFinite(value)) return 0;
  return on ? Math.round(value / GRID) * GRID : Math.round(value);
}

function sideAnchor(n: CanvasNode, side: EdgeSide | undefined): { x: number; y: number } {
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
function nearestSide(n: CanvasNode, px: number, py: number): EdgeSide {
  const cx = n.x + n.w / 2;
  const cy = n.y + n.h / 2;
  const dx = px - cx;
  const dy = py - cy;
  if (Math.abs(dx) * n.h > Math.abs(dy) * n.w) return dx >= 0 ? "right" : "left";
  return dy >= 0 ? "bottom" : "top";
}

function rectsIntersect(
  a: { x: number; y: number; w: number; h: number },
  b: { x: number; y: number; w: number; h: number },
): boolean {
  return a.x <= b.x + b.w && a.x + a.w >= b.x && a.y <= b.y + b.h && a.y + a.h >= b.y;
}

function colorRgb(c: string | undefined, resolved: Record<string, string>): string | null {
  if (!c) return null;
  if (c.startsWith("#")) return c;
  return resolved[c] ?? COLOR_MAP[c] ?? null;
}

// ── component ───────────────────────────────────────────────────────────────

export function WikiCanvasView({ pageId, onOpenPage, className }: WikiCanvasViewProps) {
  const { canvas, status, title, canSave, saveState, setCanvas } = useCanvasDoc(pageId);

  const [view, setView] = React.useState<View>({ x: 0, y: 0, scale: 1 });
  const [selected, setSelected] = React.useState<string[]>([]);
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
  const snapRef = React.useRef(snapOn);
  React.useEffect(() => void (canvasRef.current = canvas), [canvas]);
  React.useEffect(() => void (viewRef.current = view), [view]);
  React.useEffect(() => void (selectedRef.current = selected), [selected]);
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
      if (selectedRef.current.length === 0) return;
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
      const step = ev.shiftKey ? GRID : snapRef.current ? GRID : 1;
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
        </defs>
        <g ref={svgGroupRef} transform={`translate(${view.x}, ${view.y}) scale(${view.scale})`}>
          {canvas.edges.map((e) => {
            const a = canvas.nodes.find((n) => n.id === e.fromNode);
            const b = canvas.nodes.find((n) => n.id === e.toNode);
            if (!a || !b) return null;
            const stroke = edgeStroke(e, resolvedColors);
            const mid = edgeMidpoint(a, b, e);
            return (
              <g key={e.id}>
                <path
                  data-edge={e.id}
                  d={edgePath(a, b, e)}
                  fill="none"
                  stroke={stroke}
                  strokeWidth={1.5}
                  markerEnd="url(#wiki-canvas-arrow)"
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
    </div>
  );
}

// ── toolbar button ──────────────────────────────────────────────────────────

interface ToolButtonProps {
  label: string;
  onClick: () => void;
  active?: boolean;
  danger?: boolean;
  children: React.ReactNode;
}

function ToolButton({ label, onClick, active, danger, children }: ToolButtonProps) {
  return (
    <Button
      type="button"
      variant="ghost"
      size="icon"
      aria-label={label}
      aria-pressed={active}
      title={label}
      onClick={onClick}
      className={cn(
        "size-7",
        active && "bg-accent text-accent-foreground",
        danger && "text-destructive hover:text-destructive",
      )}
    >
      {children}
    </Button>
  );
}

// ── edge geometry ───────────────────────────────────────────────────────────

function edgePath(a: CanvasNode, b: CanvasNode, e: CanvasEdge): string {
  const fromSide = e.fromSide ?? nearestSide(a, b.x + b.w / 2, b.y + b.h / 2);
  const toSide = e.toSide ?? nearestSide(b, a.x + a.w / 2, a.y + a.h / 2);
  const p1 = sideAnchor(a, fromSide);
  const p2 = sideAnchor(b, toSide);
  const k = Math.max(40, Math.hypot(p2.x - p1.x, p2.y - p1.y) * 0.4);
  const c1 = controlOffset(p1, fromSide, k);
  const c2 = controlOffset(p2, toSide, k);
  return `M ${p1.x} ${p1.y} C ${c1.x} ${c1.y}, ${c2.x} ${c2.y}, ${p2.x} ${p2.y}`;
}

function controlOffset(p: { x: number; y: number }, side: EdgeSide, k: number) {
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

function edgeMidpoint(a: CanvasNode, b: CanvasNode, e: CanvasEdge) {
  const p1 = sideAnchor(a, e.fromSide ?? nearestSide(a, b.x + b.w / 2, b.y + b.h / 2));
  const p2 = sideAnchor(b, e.toSide ?? nearestSide(b, a.x + a.w / 2, a.y + a.h / 2));
  return { x: (p1.x + p2.x) / 2, y: (p1.y + p2.y) / 2 };
}

function edgeStroke(e: CanvasEdge, resolved: Record<string, string>): string {
  const rgb = colorRgb(e.color, resolved);
  if (!rgb) return "var(--muted-foreground)";
  if (rgb.startsWith("#")) return rgb;
  return `rgb(${rgb})`;
}

// ── node view ───────────────────────────────────────────────────────────────

interface CanvasNodeViewProps {
  node: CanvasNode;
  selected: boolean;
  editing: boolean;
  colors: Record<string, string>;
  onMouseDown: (e: React.MouseEvent) => void;
  onResizeStart: (e: React.MouseEvent) => void;
  onAnchorMouseDown: (e: React.MouseEvent, side: EdgeSide) => void;
  onTextCommit: (text: string) => void;
  onTextCancel: () => void;
  onStartEdit: () => void;
  onOpenPage?: (pageId: string) => void;
}

const CanvasNodeView = React.memo(function CanvasNodeView({
  node,
  selected,
  editing,
  colors,
  onMouseDown,
  onResizeStart,
  onAnchorMouseDown,
  onTextCommit,
  onTextCancel,
  onStartEdit,
  onOpenPage,
}: CanvasNodeViewProps) {
  const rgb = colorRgb(node.color, colors);
  const isGroup = node.type === "group";
  const bg = isGroup
    ? "transparent"
    : rgb && !rgb.startsWith("#")
      ? `rgba(${rgb}, 0.08)`
      : rgb
        ? rgb
        : "var(--card)";
  const borderColor = selected
    ? "var(--primary)"
    : rgb
      ? rgb.startsWith("#")
        ? rgb
        : `rgba(${rgb}, 0.5)`
      : "var(--border)";

  return (
    <>
      <div
        data-node={node.id}
        onMouseDown={onMouseDown}
        onDoubleClick={() => {
          if (node.type === "text") onStartEdit();
          else if (node.type === "page" && node.pageId) onOpenPage?.(node.pageId);
          else if (node.type === "link" && node.url) window.open(node.url, "_blank", "noopener");
        }}
        className="pointer-events-auto absolute box-border overflow-hidden rounded-lg text-card-foreground"
        style={{
          left: node.x,
          top: node.y,
          width: node.w,
          height: node.h,
          background: bg,
          border: `${selected ? 2 : 1}px ${isGroup ? "dashed" : "solid"} ${borderColor}`,
          boxShadow: selected ? "0 0 0 4px color-mix(in srgb, var(--primary) 18%, transparent)" : undefined,
          cursor: "move",
        }}
      >
        {node.type === "text" ? (
          editing ? (
            <TextEditor initial={node.text ?? ""} onCommit={onTextCommit} onCancel={onTextCancel} />
          ) : (
            <div className="h-full overflow-auto whitespace-pre-wrap p-2.5 text-sm">
              {node.text || <span className="text-muted-foreground italic">Double-click to edit</span>}
            </div>
          )
        ) : null}

        {node.type === "page" ? <PageCard node={node} /> : null}

        {node.type === "link" ? (
          <div className="flex h-full flex-col">
            <div className="flex items-center gap-1.5 border-b border-border bg-secondary px-2 py-1 text-[11px] text-muted-foreground">
              <LinkIcon className="size-3" /> Link
            </div>
            <div
              className="truncate p-2.5 text-sm"
              style={{ color: "var(--text-link, var(--primary))" }}
              title={node.url}
            >
              {node.url || "(no url)"}
            </div>
          </div>
        ) : null}

        {isGroup && node.label ? (
          <div className="absolute -top-2.5 left-3 bg-background px-1.5 text-[11px] font-medium text-muted-foreground">
            {node.label}
          </div>
        ) : null}
      </div>

      {selected ? (
        <>
          <NodeAnchors node={node} onMouseDown={onAnchorMouseDown} />
          <ResizeHandle node={node} onMouseDown={onResizeStart} />
        </>
      ) : null}
    </>
  );
});

// Page card resolves the referenced wiki page's title + excerpt via getWikiPage.
function PageCard({ node }: { node: CanvasNode }) {
  const { connector, status } = useRuntime();
  const [page, setPage] = React.useState<WikiPage | null>(null);
  const [loading, setLoading] = React.useState(false);

  React.useEffect(() => {
    if (!node.pageId || !connector.getWikiPage || status.kind !== "connected") return;
    let cancelled = false;
    setLoading(true);
    connector
      .getWikiPage(node.pageId)
      .then((p) => {
        if (!cancelled) setPage(p);
      })
      .catch(() => {})
      .finally(() => {
        if (!cancelled) setLoading(false);
      });
    return () => {
      cancelled = true;
    };
  }, [node.pageId, connector, status.kind]);

  const heading = page?.title || node.label || (node.pageId ? "Untitled page" : "(no page)");
  const excerpt = page?.excerpt ?? page?.content?.slice(0, 240);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-1.5 border-b border-border bg-secondary px-2 py-1 text-[11px] text-muted-foreground">
        <FileText className="size-3" />
        <span className="truncate">{heading}</span>
      </div>
      <div className="overflow-hidden p-2.5 text-xs text-muted-foreground">
        {loading ? "Loading…" : excerpt || "Double-click to open"}
      </div>
    </div>
  );
}

function NodeAnchors({
  node,
  onMouseDown,
}: {
  node: CanvasNode;
  onMouseDown: (e: React.MouseEvent, side: EdgeSide) => void;
}) {
  const r = 6;
  const sides: Array<{ side: EdgeSide; cx: number; cy: number }> = [
    { side: "top", cx: node.x + node.w / 2, cy: node.y },
    { side: "right", cx: node.x + node.w, cy: node.y + node.h / 2 },
    { side: "bottom", cx: node.x + node.w / 2, cy: node.y + node.h },
    { side: "left", cx: node.x, cy: node.y + node.h / 2 },
  ];
  return (
    <>
      {sides.map((s) => (
        <div
          key={s.side}
          data-anchor-node={node.id}
          data-anchor-side={s.side}
          onMouseDown={(e) => onMouseDown(e, s.side)}
          className="pointer-events-auto absolute z-20 rounded-full border-2 border-background bg-primary"
          style={{ left: s.cx - r, top: s.cy - r, width: r * 2, height: r * 2, cursor: "crosshair" }}
        />
      ))}
    </>
  );
}

function ResizeHandle({
  node,
  onMouseDown,
}: {
  node: CanvasNode;
  onMouseDown: (e: React.MouseEvent) => void;
}) {
  const size = 12;
  return (
    <div
      onMouseDown={onMouseDown}
      className="pointer-events-auto absolute z-20 rounded-sm bg-primary/70"
      style={{
        left: node.x + node.w - size,
        top: node.y + node.h - size,
        width: size,
        height: size,
        cursor: "nwse-resize",
      }}
    />
  );
}

function TextEditor({
  initial,
  onCommit,
  onCancel,
}: {
  initial: string;
  onCommit: (text: string) => void;
  onCancel: () => void;
}) {
  const [value, setValue] = React.useState(initial);
  const ref = React.useRef<HTMLTextAreaElement>(null);
  const cancelledRef = React.useRef(false);
  React.useEffect(() => {
    ref.current?.focus();
    ref.current?.select();
  }, []);
  return (
    <textarea
      ref={ref}
      value={value}
      onChange={(e) => setValue(e.currentTarget.value)}
      onMouseDown={(e) => e.stopPropagation()}
      onBlur={() => {
        if (!cancelledRef.current) onCommit(value);
      }}
      onKeyDown={(e) => {
        if (e.key === "Escape") {
          e.preventDefault();
          cancelledRef.current = true;
          onCancel();
        } else if (e.key === "Enter" && (e.metaKey || e.ctrlKey)) {
          e.preventDefault();
          onCommit(value);
        }
      }}
      className="size-full resize-none bg-card p-2.5 text-sm text-card-foreground outline-none"
      style={{ border: 0, cursor: "text" }}
    />
  );
}
