import * as React from "react";
import {
  ChevronRight,
  FileText,
  Folder,
  FolderOpen,
  Globe,
  Github,
  Rss,
  FileCode2,
  PencilLine,
  Search,
  Loader2,
} from "lucide-react";
import type { WikiPageSummary } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import { cn } from "@/lib/utils";

interface Props {
  /** Currently-open page; its row gets the active highlight + auto-reveal. */
  activePageId?: string;
  /** Open a page in the reading view. */
  onOpenPage: (id: string) => void;
}

// ── Tree model ───────────────────────────────────────────────────────────────
// Wiki pages are FLAT documents, so granite's real filesystem tree is synthesized
// here: pages are bucketed by their `source` (rss / arxiv / github / manual / web
// / …), and within a source by the leading "/"-segments of their title (e.g.
// "Papers/Transformers/Attention" → folders Papers › Transformers, leaf
// "Attention"). A page with no slashes in its title lands directly under its
// source group. The result renders with the same indented-chevron Obsidian look.

interface FileNode {
  type: "file";
  id: string;
  label: string;
  page: WikiPageSummary;
}
interface FolderNode {
  type: "folder";
  /** Stable key — the full path from the root (e.g. "github/owner/repo"). */
  path: string;
  label: string;
  children: TreeNode[];
}
type TreeNode = FolderNode | FileNode;

/** A page's title split into [...folderSegments, leafLabel]. Falls back to the
 *  id when a title is missing, and collapses empty/whitespace segments. */
function titleSegments(p: WikiPageSummary): string[] {
  const raw = (p.title ?? "").trim() || p.id;
  const parts = raw
    .split("/")
    .map((s) => s.trim())
    .filter(Boolean);
  return parts.length > 0 ? parts : [raw];
}

/** Normalize a source into a stable, lowercased group key. Pages with no source
 *  collect under an "ungrouped" bucket rendered last. */
function sourceKey(p: WikiPageSummary): string {
  const s = (p.source ?? "").trim().toLowerCase();
  return s || "ungrouped";
}

function sortNodes(nodes: TreeNode[]): TreeNode[] {
  // Folders first, then files; each alphabetical (locale-aware, case-insensitive).
  return [...nodes].sort((a, b) => {
    if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
    return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
  });
}

/** Build the source → title-path tree from a flat page list. */
function buildTree(pages: WikiPageSummary[]): FolderNode[] {
  const roots = new Map<string, FolderNode>();

  for (const page of pages) {
    const group = sourceKey(page);
    let root = roots.get(group);
    if (!root) {
      root = { type: "folder", path: group, label: group, children: [] };
      roots.set(group, root);
    }

    const segs = titleSegments(page);
    const folders = segs.slice(0, -1);
    const leaf = segs[segs.length - 1];

    let cursor = root;
    let pathAcc = group;
    for (const seg of folders) {
      pathAcc = `${pathAcc}/${seg}`;
      let child = cursor.children.find(
        (c): c is FolderNode => c.type === "folder" && c.label === seg,
      );
      if (!child) {
        child = { type: "folder", path: pathAcc, label: seg, children: [] };
        cursor.children.push(child);
      }
      cursor = child;
    }
    cursor.children.push({ type: "file", id: page.id, label: leaf, page });
  }

  // Recursive sort, then order groups: real sources alphabetical, "ungrouped" last.
  const sortRec = (n: FolderNode): FolderNode => ({
    ...n,
    children: sortNodes(n.children).map((c) => (c.type === "folder" ? sortRec(c) : c)),
  });
  return [...roots.values()]
    .map(sortRec)
    .sort((a, b) => {
      if (a.label === "ungrouped") return 1;
      if (b.label === "ungrouped") return -1;
      return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
    });
}

/** Count the leaf files under a folder (drives the per-folder count badge). */
function countFiles(n: FolderNode): number {
  let total = 0;
  for (const c of n.children) {
    if (c.type === "file") total += 1;
    else total += countFiles(c);
  }
  return total;
}

/** Filter the page list by a free-text query against title + source. Kept on the
 *  raw list (then re-bucketed) so matches in nested folders still surface, with
 *  their ancestor folders preserved. */
function filterPages(pages: WikiPageSummary[], query: string): WikiPageSummary[] {
  const q = query.trim().toLowerCase();
  if (!q) return pages;
  return pages.filter((p) => {
    const hay = `${p.title ?? ""} ${p.source ?? ""} ${p.id}`.toLowerCase();
    return hay.includes(q);
  });
}

// ── Source icon — small visual cue per known source group ────────────────────
function sourceIcon(group: string): React.ReactNode {
  const cls = "size-3.5 shrink-0";
  switch (group) {
    case "rss":
    case "arxiv":
      return <Rss className={cls} aria-hidden />;
    case "github":
      return <Github className={cls} aria-hidden />;
    case "web":
      return <Globe className={cls} aria-hidden />;
    case "manual":
      return <PencilLine className={cls} aria-hidden />;
    case "code":
      return <FileCode2 className={cls} aria-hidden />;
    default:
      return null; // folder chevron + folder icon handle the generic case
  }
}

/** Recents loader (local; mirrors state/wiki.ts so the integrator mounts this
 *  without touching shared state). Gates on the WS handshake + optional method. */
function useExplorerPages(limit = 200): { pages: WikiPageSummary[]; loading: boolean } {
  const { connector, status } = useRuntime();
  const [pages, setPages] = React.useState<WikiPageSummary[]>([]);
  const [loading, setLoading] = React.useState(false);
  React.useEffect(() => {
    if (!connector.listWikiPages || status.kind !== "connected") return;
    let alive = true;
    setLoading(true);
    connector
      .listWikiPages({ limit })
      .then((p) => alive && setPages(p))
      .catch(() => alive && setPages([]))
      .finally(() => alive && setLoading(false));
    return () => {
      alive = false;
    };
  }, [connector, status.kind, limit]);
  return { pages, loading };
}

export function WikiExplorer({ activePageId, onOpenPage }: Props) {
  const { pages, loading } = useExplorerPages();
  const [query, setQuery] = React.useState("");
  // Folders are EXPANDED by default; this set holds the explicitly-collapsed
  // paths (matches granite's `collapsed` semantics — empty = everything open).
  const [collapsed, setCollapsed] = React.useState<ReadonlySet<string>>(new Set());

  const filtered = React.useMemo(() => filterPages(pages, query), [pages, query]);
  const tree = React.useMemo(() => buildTree(filtered), [filtered]);

  // While filtering, force every folder open so matches deep in the tree are
  // visible; restore the user's collapse state when the query clears.
  const searching = query.trim().length > 0;

  const toggle = React.useCallback((path: string) => {
    setCollapsed((prev) => {
      const next = new Set(prev);
      if (next.has(path)) next.delete(path);
      else next.add(path);
      return next;
    });
  }, []);

  const isOpen = React.useCallback(
    (path: string) => searching || !collapsed.has(path),
    [searching, collapsed],
  );

  return (
    <div className="flex min-h-0 flex-col">
      {/* SEARCH / FILTER BOX */}
      <div className="relative px-1 pb-2">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 size-3.5 -translate-y-1/2 text-[color:var(--color-text-tertiary)]"
          aria-hidden
        />
        {loading && (
          <Loader2
            className="absolute right-3 top-1/2 size-3.5 -translate-y-1/2 animate-spin text-[color:var(--color-text-tertiary)]"
            aria-hidden
          />
        )}
        <Input
          type="search"
          value={query}
          onChange={(e) => setQuery(e.currentTarget.value)}
          placeholder="Filter pages…"
          aria-label="Filter wiki pages"
          className="h-8 pl-8 pr-8 text-[13px]"
        />
      </div>

      {/* TREE */}
      <ScrollArea className="min-h-0 flex-1">
        <nav className="flex flex-col px-1 pb-4" aria-label="Wiki file explorer">
          {tree.length === 0 ? (
            <div className="px-2 py-10 text-center text-[13px] text-[color:var(--color-text-quaternary)]">
              {loading
                ? "Loading pages…"
                : searching
                  ? "No pages match your filter."
                  : "No wiki pages yet."}
            </div>
          ) : (
            tree.map((node) => (
              <TreeRow
                key={node.path}
                node={node}
                depth={0}
                activePageId={activePageId}
                onOpenPage={onOpenPage}
                isOpen={isOpen}
                onToggle={toggle}
              />
            ))
          )}
        </nav>
      </ScrollArea>
    </div>
  );
}

interface RowProps {
  node: TreeNode;
  depth: number;
  activePageId?: string;
  onOpenPage: (id: string) => void;
  isOpen: (path: string) => boolean;
  onToggle: (path: string) => void;
}

// Indent step (px) per tree level — the chevron/icon column is fixed, so this
// shifts the whole row, giving the Obsidian "guide line" feel without a gutter.
const INDENT = 12;

// Split file vs. folder into distinct components so React's hook order stays
// stable (the file row uses useRef/useEffect for active-row reveal; the folder
// row does not — a single conditional component would break the Rules of Hooks).
function TreeRow({ node, depth, activePageId, onOpenPage, isOpen, onToggle }: RowProps) {
  if (node.type === "file") {
    return (
      <FileRow node={node} depth={depth} activePageId={activePageId} onOpenPage={onOpenPage} />
    );
  }
  return (
    <FolderRow
      node={node}
      depth={depth}
      activePageId={activePageId}
      onOpenPage={onOpenPage}
      isOpen={isOpen}
      onToggle={onToggle}
    />
  );
}

interface FileRowProps {
  node: FileNode;
  depth: number;
  activePageId?: string;
  onOpenPage: (id: string) => void;
}

function FileRow({ node, depth, activePageId, onOpenPage }: FileRowProps) {
  const active = node.id === activePageId;
  const ref = React.useRef<HTMLButtonElement>(null);
  // Reveal the active page when it changes (e.g. opened from search/links).
  React.useEffect(() => {
    if (active) ref.current?.scrollIntoView({ block: "nearest" });
  }, [active]);
  return (
    <button
      ref={ref}
      type="button"
      title={node.label}
      aria-current={active ? "page" : undefined}
      onClick={() => onOpenPage(node.id)}
      style={{ paddingInlineStart: 8 + depth * INDENT }}
      className={cn(
        "group flex h-7 w-full items-center gap-1.5 rounded-sm pr-2 text-left",
        "text-[13px] leading-none",
        "text-[color:var(--color-text-secondary)]",
        "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        active && "bg-[color:var(--color-surface-hover)] font-medium text-foreground",
      )}
    >
      <FileText
        className={cn(
          "size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]",
          active && "text-foreground",
        )}
        aria-hidden
      />
      <span className="truncate">{node.label}</span>
    </button>
  );
}

interface FolderRowProps {
  node: FolderNode;
  depth: number;
  activePageId?: string;
  onOpenPage: (id: string) => void;
  isOpen: (path: string) => boolean;
  onToggle: (path: string) => void;
}

function FolderRow({ node, depth, activePageId, onOpenPage, isOpen, onToggle }: FolderRowProps) {
  const open = isOpen(node.path);
  const count = countFiles(node);
  const icon = sourceIcon(node.label);

  return (
    <Collapsible open={open} onOpenChange={() => onToggle(node.path)}>
      <CollapsibleTrigger asChild>
        <button
          type="button"
          title={node.label}
          style={{ paddingInlineStart: 4 + depth * INDENT }}
          className={cn(
            "group flex h-7 w-full items-center gap-1 rounded-sm pr-2 text-left",
            "text-[13px] leading-none",
            "text-[color:var(--color-text-secondary)]",
            "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
          )}
        >
          <ChevronRight
            className={cn(
              "size-3.5 shrink-0 text-[color:var(--color-text-tertiary)] transition-transform",
              open && "rotate-90",
            )}
            aria-hidden
          />
          {icon ?? (
            open ? (
              <FolderOpen className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" aria-hidden />
            ) : (
              <Folder className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" aria-hidden />
            )
          )}
          <span className="truncate font-medium">{node.label}</span>
          <span className="ml-auto pl-2 text-[11px] tabular-nums text-[color:var(--color-text-quaternary)]">
            {count}
          </span>
        </button>
      </CollapsibleTrigger>
      <CollapsibleContent>
        {node.children.map((child) => (
          <TreeRow
            key={child.type === "folder" ? child.path : child.id}
            node={child}
            depth={depth + 1}
            activePageId={activePageId}
            onOpenPage={onOpenPage}
            isOpen={isOpen}
            onToggle={onToggle}
          />
        ))}
      </CollapsibleContent>
    </Collapsible>
  );
}
