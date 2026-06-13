// Presentational sub-components for the canvas whiteboard, extracted from
// WikiCanvasView so the god-file shrinks to its interaction/state core. Every
// component here is module-level and fully props-driven (no parent closure) —
// the main view passes geometry + callbacks in, these render DOM/SVG out.
//
//   ToolButton      — a toolbar icon button (ghost, active/danger variants)
//   CanvasNodeView  — one node (text / page / link / group), memoized
//   CanvasMinimap   — corner overview navigator (click/drag to recenter)
//   PageCard        — page-node body: resolves the wiki page + renders a slice
//   NodeAnchors     — the four edge-drawing handles on a selected node
//   ResizeHandle    — the bottom-right resize grip on a selected node
//   TextEditor      — the inline textarea for editing a text node

import * as React from "react";
import { FileText, Link as LinkIcon } from "lucide-react";
import { cn } from "@/lib/utils";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage } from "@/runtime/connector";
import { Button } from "@/components/ui/button";
import type { CanvasNode, EdgeSide } from "./canvasSchema";
import { colorRgb } from "./canvasGeometry";
import { WikiMarkdown } from "../WikiMarkdown";
import { sliceForFragment } from "../markdown/transclude";

/** The world→screen transform shared between the canvas and its minimap. */
export interface View {
  x: number;
  y: number;
  scale: number;
}

// ── toolbar button ──────────────────────────────────────────────────────────

interface ToolButtonProps {
  label: string;
  onClick: () => void;
  active?: boolean;
  danger?: boolean;
  children: React.ReactNode;
}

export function ToolButton({ label, onClick, active, danger, children }: ToolButtonProps) {
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
  onOpenPage?: (pageId: string, subpath?: string) => void;
}

export const CanvasNodeView = React.memo(function CanvasNodeView({
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
  // Group background: an explicit `backgroundColor` (swatch id or hex) fills the
  // group faintly; otherwise it stays transparent so nested nodes show through.
  const groupBgRgb = isGroup ? colorRgb(node.backgroundColor, colors) : null;
  const bg = isGroup
    ? groupBgRgb
      ? groupBgRgb.startsWith("#")
        ? groupBgRgb
        : `rgba(${groupBgRgb}, 0.10)`
      : "transparent"
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
          else if (node.type === "page" && node.pageId) onOpenPage?.(node.pageId, node.subpath);
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
          ) : node.text ? (
            // Read-only rendered markdown. `pointer-events-none` makes the whole
            // rendered surface transparent to the pointer so a drag that starts
            // inside the node still drags the node, and a double-click bubbles to
            // the node's onDoubleClick → switches to raw edit (parity with the
            // plain-text view it replaces). The renderer is reused as-is — no
            // link callbacks, since nothing here is interactive.
            <div className="pointer-events-none h-full overflow-auto p-2.5 text-card-foreground [&_.wiki-markdown]:text-[13px]">
              <WikiMarkdown content={node.text} />
            </div>
          ) : (
            <div className="h-full overflow-auto whitespace-pre-wrap p-2.5 text-sm">
              <span className="text-muted-foreground italic">Double-click to edit</span>
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

// ── Minimap overview navigator ───────────────────────────────────────────────

const MINIMAP_W = 170;
const MINIMAP_H = 120;
const MINIMAP_PAD = 6;

/**
 * A small overview of the whole canvas in the corner: every node drawn to scale
 * plus the current viewport rectangle. Click (or drag) re-centers the canvas on
 * that point. Reads the live container size on each render (it re-renders when
 * `view` changes). Hidden on an empty canvas.
 */
export function CanvasMinimap({
  nodes,
  view,
  containerRef,
  onPanTo,
}: {
  nodes: ReadonlyArray<CanvasNode>;
  view: View;
  containerRef: React.RefObject<HTMLDivElement | null>;
  onPanTo: (wx: number, wy: number) => void;
}) {
  const svgRef = React.useRef<SVGSVGElement>(null);
  const draggingRef = React.useRef(false);

  const bounds = React.useMemo(() => {
    if (nodes.length === 0) return null;
    let minX = Infinity, minY = Infinity, maxX = -Infinity, maxY = -Infinity;
    for (const n of nodes) {
      minX = Math.min(minX, n.x);
      minY = Math.min(minY, n.y);
      maxX = Math.max(maxX, n.x + n.w);
      maxY = Math.max(maxY, n.y + n.h);
    }
    return { minX, minY, w: Math.max(1, maxX - minX), h: Math.max(1, maxY - minY) };
  }, [nodes]);

  if (!bounds) return null;

  const innerW = MINIMAP_W - MINIMAP_PAD * 2;
  const innerH = MINIMAP_H - MINIMAP_PAD * 2;
  const s = Math.min(innerW / bounds.w, innerH / bounds.h);
  // World → minimap px (centered within the inner box).
  const offX = MINIMAP_PAD + (innerW - bounds.w * s) / 2;
  const offY = MINIMAP_PAD + (innerH - bounds.h * s) / 2;
  const toMx = (x: number) => offX + (x - bounds.minX) * s;
  const toMy = (y: number) => offY + (y - bounds.minY) * s;

  // Current viewport in world coords (from the view transform + container size).
  const rect = containerRef.current?.getBoundingClientRect();
  const vp = rect
    ? {
        x: toMx(-view.x / view.scale),
        y: toMy(-view.y / view.scale),
        w: (rect.width / view.scale) * s,
        h: (rect.height / view.scale) * s,
      }
    : null;

  // Minimap px → world coords, then center the viewport there.
  const panFromEvent = (e: React.MouseEvent) => {
    const r = svgRef.current?.getBoundingClientRect();
    if (!r) return;
    const mx = e.clientX - r.left;
    const my = e.clientY - r.top;
    const wx = (mx - offX) / s + bounds.minX;
    const wy = (my - offY) / s + bounds.minY;
    onPanTo(wx, wy);
  };

  return (
    <div className="absolute bottom-2 right-2 z-10 overflow-hidden rounded-md border border-border bg-card/95 shadow-sm backdrop-blur">
      <svg
        ref={svgRef}
        width={MINIMAP_W}
        height={MINIMAP_H}
        className="block cursor-pointer"
        onMouseDown={(e) => {
          draggingRef.current = true;
          panFromEvent(e);
        }}
        onMouseMove={(e) => {
          if (draggingRef.current) panFromEvent(e);
        }}
        onMouseUp={() => (draggingRef.current = false)}
        onMouseLeave={() => (draggingRef.current = false)}
        aria-label="Canvas minimap"
      >
        {nodes.map((n) => (
          <rect
            key={n.id}
            x={toMx(n.x)}
            y={toMy(n.y)}
            width={Math.max(1, n.w * s)}
            height={Math.max(1, n.h * s)}
            rx={1}
            className={n.type === "group" ? "fill-muted-foreground/20 stroke-muted-foreground/40" : "fill-primary/40 stroke-primary/60"}
            strokeWidth={0.5}
          />
        ))}
        {vp && (
          <rect
            x={vp.x}
            y={vp.y}
            width={vp.w}
            height={vp.h}
            className="fill-primary/10 stroke-primary"
            strokeWidth={1}
            pointerEvents="none"
          />
        )}
      </svg>
    </div>
  );
}

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

  // The embedded slice: the whole body, or just the #heading / #^block section
  // named by the node's subpath (reusing the M27 transclusion slicer). Rendered
  // with the full markdown pipeline (standalone → live blocks off, no nested
  // transclusion fetch storm), scrollable inside the fixed-size card.
  const body = page?.content ?? "";
  const sliced = React.useMemo(() => {
    if (!body) return "";
    if (!node.subpath) return body;
    const frag = node.subpath.replace(/^#/, "");
    const pf = frag.startsWith("^")
      ? { title: "", block: frag.slice(1) }
      : { title: "", heading: frag };
    return sliceForFragment(body, pf) ?? body;
  }, [body, node.subpath]);

  return (
    <div className="flex h-full flex-col">
      <div className="flex items-center gap-1.5 border-b border-border bg-secondary px-2 py-1 text-[11px] text-muted-foreground">
        <FileText className="size-3 shrink-0" />
        <span className="truncate">{heading}</span>
        {node.subpath ? (
          <span className="truncate opacity-70" title={node.subpath}>
            {node.subpath}
          </span>
        ) : null}
      </div>
      <div className="wiki-canvas-embed min-h-0 flex-1 overflow-auto p-2.5 text-xs">
        {loading ? (
          <span className="text-muted-foreground">Loading…</span>
        ) : sliced ? (
          <WikiMarkdown content={sliced} />
        ) : (
          <span className="text-muted-foreground">Double-click to open</span>
        )}
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
