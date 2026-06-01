import * as React from "react";
import { ChevronRight, Folder } from "lucide-react";
import { cn } from "@/lib/utils";
import { Input } from "@/components/ui/input";
import { getFileIcon } from "./getFileIcon";

interface FileEntry {
  path: string;
  added: number;
  removed: number;
  /** Number of review comments on this file (renders a count badge). */
  comments?: number;
}

interface TreeNode {
  name: string;
  fullPath: string;
  children: Map<string, TreeNode>;
  file?: FileEntry;
}

interface Props {
  files: FileEntry[];
  activePath?: string;
  onSelect: (path: string) => void;
}

// localStorage key for the persisted rail width (matches the original
// review-file-tree side-pane width persistence).
const RAIL_WIDTH_KEY = "reviewFileTreeWidth";
const RAIL_MIN_WIDTH = 160;
const RAIL_MAX_WIDTH = 420;
const RAIL_DEFAULT_WIDTH = 200;

function clampWidth(w: number) {
  return Math.min(RAIL_MAX_WIDTH, Math.max(RAIL_MIN_WIDTH, w));
}

/**
 * A width-resizable wrapper for the changed-files rail. Renders its children in
 * a fixed-but-draggable-width column with a pointer-drag handle on the right
 * edge; the chosen width is persisted to localStorage so it survives reloads.
 *
 * This is additive: callers that don't need resizing keep using <FileTree />
 * directly. ResizableRail is exported so the diff panel can opt the rail in
 * without changing any existing public prop shapes.
 */
export function ResizableRail({
  children,
  className,
  storageKey = RAIL_WIDTH_KEY,
}: {
  children: React.ReactNode;
  className?: string;
  storageKey?: string;
}) {
  const [width, setWidth] = React.useState<number>(() => {
    try {
      const v = localStorage.getItem(storageKey);
      const n = v == null ? NaN : Number.parseInt(v, 10);
      return Number.isFinite(n) ? clampWidth(n) : RAIL_DEFAULT_WIDTH;
    } catch {
      return RAIL_DEFAULT_WIDTH;
    }
  });

  const railRef = React.useRef<HTMLDivElement>(null);
  const dragging = React.useRef(false);

  React.useEffect(() => {
    try {
      localStorage.setItem(storageKey, String(width));
    } catch {
      /* ignore */
    }
  }, [storageKey, width]);

  React.useEffect(() => {
    function onMove(e: PointerEvent) {
      if (!dragging.current || !railRef.current) return;
      const left = railRef.current.getBoundingClientRect().left;
      setWidth(clampWidth(e.clientX - left));
    }
    function onUp() {
      if (!dragging.current) return;
      dragging.current = false;
      document.body.style.cursor = "";
      document.body.style.userSelect = "";
    }
    window.addEventListener("pointermove", onMove);
    window.addEventListener("pointerup", onUp);
    return () => {
      window.removeEventListener("pointermove", onMove);
      window.removeEventListener("pointerup", onUp);
    };
  }, []);

  const startDrag = React.useCallback((e: React.PointerEvent) => {
    e.preventDefault();
    dragging.current = true;
    document.body.style.cursor = "col-resize";
    document.body.style.userSelect = "none";
  }, []);

  return (
    <div
      ref={railRef}
      className={cn("relative shrink-0", className)}
      style={{ width }}
    >
      {children}
      {/* Drag handle on the right edge. */}
      <div
        role="separator"
        aria-orientation="vertical"
        aria-label="Resize changed-files panel"
        onPointerDown={startDrag}
        onDoubleClick={() => setWidth(RAIL_DEFAULT_WIDTH)}
        className="absolute inset-y-0 right-0 z-10 w-1 cursor-col-resize bg-transparent hover:bg-[color:var(--color-divider)]"
      />
    </div>
  );
}

// Collapsible tree of changed files, grouped by directory. Mirrors the original
// review-file-tree-side-pane.js: a "Filter changed files" search input above the
// tree, language-aware file icons, per-file comment-count badges, ancestors of
// the active path kept expanded, and scroll-into-view on selection
// (data-review-path + scrollIntoView).
export function FileTree({ files, activePath, onSelect }: Props) {
  const [query, setQuery] = React.useState("");

  const filtered = React.useMemo(() => {
    if (!query.trim()) return files;
    const q = query.toLowerCase();
    return files.filter((f) => f.path.toLowerCase().includes(q));
  }, [files, query]);

  const root = React.useMemo(() => buildTree(filtered), [filtered]);

  // Directories that are ancestors of the active path — always kept expanded.
  const activeAncestors = React.useMemo(() => {
    const set = new Set<string>();
    if (!activePath) return set;
    const parts = activePath.split("/");
    let path = "";
    for (let i = 0; i < parts.length - 1; i++) {
      path = path ? `${path}/${parts[i]}` : parts[i];
      set.add(path);
    }
    return set;
  }, [activePath]);

  // Scroll the active file row into view when it changes.
  const containerRef = React.useRef<HTMLDivElement>(null);
  React.useEffect(() => {
    if (!activePath || !containerRef.current) return;
    const el = containerRef.current.querySelector<HTMLElement>(
      `[data-review-path="${CSS.escape(activePath)}"]`,
    );
    el?.scrollIntoView({ block: "nearest" });
  }, [activePath, filtered]);

  return (
    <div ref={containerRef} className="space-y-1">
      <Input
        value={query}
        onChange={(e) => setQuery(e.target.value)}
        placeholder="Filter changed files"
        aria-label="Filter changed files"
        className="h-7 text-[12px]"
      />
      <div className="space-y-px">
        {[...root.children.values()].map((node) => (
          <TreeRow
            key={node.fullPath}
            node={node}
            depth={0}
            activePath={activePath}
            activeAncestors={activeAncestors}
            onSelect={onSelect}
          />
        ))}
        {[...root.children.values()].length === 0 && (
          <div className="px-2 py-2 text-[11.5px] text-[color:var(--color-text-quaternary)]">
            No matching files
          </div>
        )}
      </div>
    </div>
  );
}

function TreeRow({
  node,
  depth,
  activePath,
  activeAncestors,
  onSelect,
}: {
  node: TreeNode;
  depth: number;
  activePath?: string;
  activeAncestors: Set<string>;
  onSelect: (path: string) => void;
}) {
  const isFile = !!node.file;
  // Default-expand all changed-file dirs; keep ancestors of the active path
  // expanded regardless of local toggle state.
  const [open, setOpen] = React.useState(true);
  const forceOpen = activeAncestors.has(node.fullPath);
  const expanded = open || forceOpen;
  const FileIconCmp = isFile ? getFileIcon(node.name) : null;

  return (
    <>
      <button
        type="button"
        data-review-path={isFile ? node.fullPath : undefined}
        onClick={() => {
          if (isFile) onSelect(node.fullPath);
          else setOpen((v) => !v);
        }}
        className={cn(
          "flex h-6 w-full items-center gap-1 rounded px-1 text-left text-[12px] hover:bg-[color:var(--color-surface-hover)]",
          activePath === node.fullPath && isFile && "bg-[color:var(--color-surface-active)] font-medium",
        )}
        style={{ paddingLeft: 4 + depth * 12 }}
      >
        {isFile ? (
          <>
            <span className="w-3" />
            {FileIconCmp && <FileIconCmp className="size-3 text-[color:var(--color-text-tertiary)]" />}
          </>
        ) : (
          <>
            <ChevronRight
              className={cn(
                "size-3 text-[color:var(--color-text-tertiary)] transition-transform",
                expanded && "rotate-90",
              )}
            />
            <Folder className="size-3 text-[color:var(--color-text-secondary)]" />
          </>
        )}
        <span className="flex-1 truncate font-mono">{node.name}</span>
        {isFile && node.file?.comments != null && node.file.comments > 0 && (
          <span className="shrink-0 rounded-full bg-[color:var(--color-surface-hover)] px-1.5 text-[10px] text-[color:var(--color-text-secondary)]">
            {node.file.comments}
          </span>
        )}
        {isFile && node.file && (
          <span className="shrink-0 font-mono text-[10.5px]">
            <span className="text-[color:var(--color-green-500)]">+{node.file.added}</span>{" "}
            <span className="text-[color:var(--color-red-500)]">-{node.file.removed}</span>
          </span>
        )}
      </button>
      {!isFile && expanded &&
        [...node.children.values()].map((child) => (
          <TreeRow
            key={child.fullPath}
            node={child}
            depth={depth + 1}
            activePath={activePath}
            activeAncestors={activeAncestors}
            onSelect={onSelect}
          />
        ))}
    </>
  );
}

function buildTree(files: FileEntry[]): TreeNode {
  const root: TreeNode = { name: "", fullPath: "", children: new Map() };
  for (const f of files) {
    const parts = f.path.split("/");
    let cur = root;
    let path = "";
    for (let i = 0; i < parts.length; i++) {
      const p = parts[i];
      path = path ? `${path}/${p}` : p;
      if (!cur.children.has(p)) {
        cur.children.set(p, { name: p, fullPath: path, children: new Map() });
      }
      cur = cur.children.get(p)!;
      if (i === parts.length - 1) cur.file = f;
    }
  }
  return root;
}
