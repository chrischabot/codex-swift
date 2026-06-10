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
  ArrowDownUp,
  Check,
} from "lucide-react";
import type { WikiPageSummary } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Input } from "@/components/ui/input";
import { Button } from "@/components/ui/button";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Collapsible, CollapsibleContent, CollapsibleTrigger } from "@/components/ui/collapsible";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { toast } from "@/components/ui/sonner";
import { renameTabInStorage } from "@/components/wiki/tabs/useWikiTabs";
import { cn } from "@/lib/utils";
import {
  SORT_MODES,
  SORT_LABELS,
  useSortMode,
  compareNodes,
  type SortMode,
} from "./sort";
import { recordWikiRecent } from "./useWikiRecents";

// Context for the row-level actions (rename/delete/open) so the deeply-nested
// FileRow can reach them without prop-drilling through TreeRow/FolderRow.
interface ExplorerActions {
  canEdit: boolean;
  onOpen: (id: string) => void;
  /** Open the rename MODAL (context-menu "Rename…"). */
  onRename: (node: FileNode) => void;
  onDelete: (node: FileNode) => void;
  /** Begin INLINE (edit-in-place) rename on a row; null clears it. The id is
   *  the file node's page id (matches FileNode.id). */
  inlineRenameId: string | null;
  beginInlineRename: (id: string | null) => void;
  /** Commit an inline rename via the same connector path as the modal. Returns
   *  a promise that resolves once the row should exit edit mode. */
  commitInlineRename: (node: FileNode, nextTitle: string) => Promise<void>;
}
const ExplorerActionsContext = React.createContext<ExplorerActions | null>(null);
function useExplorerActions(): ExplorerActions {
  const ctx = React.useContext(ExplorerActionsContext);
  if (!ctx) throw new Error("ExplorerActionsContext missing");
  return ctx;
}

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

function sortNodes(nodes: TreeNode[], mode: SortMode): TreeNode[] {
  // Folders first, then files; ordering within each kind honours the sort mode
  // (folders always fall back to label order — they carry no date). Delegated to
  // the pure `compareNodes` so the ordering is independently unit-tested.
  return [...nodes].sort((a, b) => compareNodes(a, b, mode));
}

/** Build the source → title-path tree from a flat page list. */
function buildTree(pages: WikiPageSummary[], mode: SortMode): FolderNode[] {
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
    children: sortNodes(n.children, mode).map((c) => (c.type === "folder" ? sortRec(c) : c)),
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
function useExplorerPages(limit = 200): { pages: WikiPageSummary[]; loading: boolean; reload: () => void } {
  const { connector, status } = useRuntime();
  const [pages, setPages] = React.useState<WikiPageSummary[]>([]);
  const [loading, setLoading] = React.useState(false);
  const [tick, setTick] = React.useState(0);
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
  }, [connector, status.kind, limit, tick]);
  const reload = React.useCallback(() => setTick((t) => t + 1), []);
  return { pages, loading, reload };
}

export function WikiExplorer({ activePageId, onOpenPage }: Props) {
  const { connector, status } = useRuntime();
  const { pages, loading, reload } = useExplorerPages();
  const canEdit =
    status.kind === "connected" &&
    typeof connector.renameWikiPage === "function" &&
    typeof connector.deleteWikiPage === "function";
  const [renameTarget, setRenameTarget] = React.useState<FileNode | null>(null);
  const [deleteTarget, setDeleteTarget] = React.useState<FileNode | null>(null);
  const [inlineRenameId, setInlineRenameId] = React.useState<string | null>(null);

  // Record opens into the recently-opened MRU (granite RecentsView semantics).
  const openPage = React.useCallback(
    (id: string) => {
      const p = pages.find((pg) => pg.id === id);
      recordWikiRecent(id, p?.title);
      onOpenPage(id);
    },
    [pages, onOpenPage],
  );

  // Shared inline-rename commit — reuses the SAME connector path as the modal
  // (renameWikiPage + tab-title sync + reload), so the two entry points stay
  // behaviourally identical. Throws on failure so the row can surface it.
  const commitInlineRename = React.useCallback(
    async (node: FileNode, nextTitle: string) => {
      const next = nextTitle.trim();
      if (!connector.renameWikiPage || !next) return;
      const res = await connector.renameWikiPage(node.id, next);
      if (res === null) throw new Error("Rename failed");
      if (!res.renamed) throw new Error("Page not found or empty title");
      renameTabInStorage(node.id, next);
      toast.success("Page renamed");
      reload();
    },
    [connector, reload],
  );

  const actions = React.useMemo<ExplorerActions>(
    () => ({
      canEdit,
      onOpen: openPage,
      onRename: (node) => setRenameTarget(node),
      onDelete: (node) => setDeleteTarget(node),
      inlineRenameId,
      beginInlineRename: setInlineRenameId,
      commitInlineRename,
    }),
    [canEdit, openPage, inlineRenameId, commitInlineRename],
  );
  const [sortMode, setSortMode] = useSortMode();
  const [query, setQuery] = React.useState("");
  // Folders are EXPANDED by default; this set holds the explicitly-collapsed
  // paths (matches granite's `collapsed` semantics — empty = everything open).
  const [collapsed, setCollapsed] = React.useState<ReadonlySet<string>>(new Set());

  const filtered = React.useMemo(() => filterPages(pages, query), [pages, query]);
  const tree = React.useMemo(() => buildTree(filtered, sortMode), [filtered, sortMode]);

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
    <ExplorerActionsContext.Provider value={actions}>
    <div className="flex min-h-0 flex-col">
      {renameTarget && (
        <RenamePageDialog
          node={renameTarget}
          onClose={() => setRenameTarget(null)}
          onDone={reload}
        />
      )}
      {deleteTarget && (
        <DeletePageDialog
          node={deleteTarget}
          onClose={() => setDeleteTarget(null)}
          onDone={reload}
        />
      )}
      {/* SEARCH / FILTER BOX + SORT MENU */}
      <div className="flex items-center gap-1 px-1 pb-2">
        <div className="relative min-w-0 flex-1">
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
        <SortMenu mode={sortMode} onChange={setSortMode} />
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
                onOpenPage={openPage}
                isOpen={isOpen}
                onToggle={toggle}
              />
            ))
          )}
        </nav>
      </ScrollArea>
    </div>
    </ExplorerActionsContext.Provider>
  );
}

// ── Sort menu ────────────────────────────────────────────────────────────────

function SortMenu({ mode, onChange }: { mode: SortMode; onChange: (m: SortMode) => void }) {
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="iconSm"
          aria-label="Change sort order"
          title="Sort"
          className="size-8 shrink-0 text-[color:var(--color-text-tertiary)]"
        >
          <ArrowDownUp className="size-3.5" aria-hidden />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end" className="w-52">
        <DropdownMenuLabel>Sort order</DropdownMenuLabel>
        <DropdownMenuSeparator />
        {SORT_MODES.map((m) => (
          <DropdownMenuItem
            key={m}
            onSelect={() => onChange(m)}
            className="justify-between"
          >
            <span>{SORT_LABELS[m]}</span>
            {m === mode && <Check className="size-3.5" aria-hidden />}
          </DropdownMenuItem>
        ))}
      </DropdownMenuContent>
    </DropdownMenu>
  );
}

// ── Rename / Delete dialogs ──────────────────────────────────────────────────

function RenamePageDialog({ node, onClose, onDone }: { node: FileNode; onClose: () => void; onDone: () => void }) {
  const { connector } = useRuntime();
  const [title, setTitle] = React.useState(node.page.title ?? node.label);
  const [busy, setBusy] = React.useState(false);
  const aliveRef = React.useRef(true);
  React.useEffect(() => () => { aliveRef.current = false; }, []);
  const submit = async () => {
    const next = title.trim();
    // Only block on empty / in-flight. We intentionally do NOT short-circuit on
    // `next === node.page.title`: that's the DISPLAYED title (a NULL-titled page
    // shows "Untitled"/its sourceURI), so comparing against it would silently
    // skip a legit rename. The backend no-ops a true identical title cheaply.
    if (!connector.renameWikiPage || busy || !next) return;
    setBusy(true);
    try {
      const res = await connector.renameWikiPage(node.id, next);
      if (res === null) { toast.error("Rename failed"); return; }
      if (!res.renamed) { toast.error("Page not found or empty title"); return; }
      renameTabInStorage(node.id, next); // keep any open tab's title fresh
      toast.success("Page renamed");
      onDone();
      onClose();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Rename failed");
    } finally {
      if (aliveRef.current) setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(o) => !busy && !o && onClose()}>
      <DialogContent className="sm:max-w-[420px]">
        <DialogHeader>
          <DialogTitle>Rename page</DialogTitle>
          <DialogDescription>Change the title of this wiki page.</DialogDescription>
        </DialogHeader>
        <Input
          autoFocus
          value={title}
          onChange={(e) => setTitle(e.currentTarget.value)}
          onKeyDown={(e) => { if (e.key === "Enter") void submit(); }}
          aria-label="New page title"
        />
        <DialogFooter>
          <Button variant="ghost" size="sm" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button variant="default" size="sm" loading={busy} disabled={!title.trim()} onClick={() => void submit()}>
            Rename
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}

function DeletePageDialog({ node, onClose, onDone }: { node: FileNode; onClose: () => void; onDone: () => void }) {
  const { connector } = useRuntime();
  const [busy, setBusy] = React.useState(false);
  const aliveRef = React.useRef(true);
  React.useEffect(() => () => { aliveRef.current = false; }, []);
  const submit = async () => {
    if (!connector.deleteWikiPage || busy) return;
    setBusy(true);
    try {
      const res = await connector.deleteWikiPage(node.id);
      if (res === null) { toast.error("Delete failed"); return; }
      toast.success(res.deleted ? "Page deleted" : "Page was already gone");
      onDone();
      onClose();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Delete failed");
    } finally {
      if (aliveRef.current) setBusy(false);
    }
  };
  return (
    <Dialog open onOpenChange={(o) => !busy && !o && onClose()}>
      <DialogContent className="sm:max-w-[420px]">
        <DialogHeader>
          <DialogTitle>Delete page?</DialogTitle>
          <DialogDescription>
            “{node.page.title ?? node.label}” and its search-index entries will be permanently
            removed. This can’t be undone.
          </DialogDescription>
        </DialogHeader>
        <DialogFooter>
          <Button variant="ghost" size="sm" disabled={busy} onClick={onClose}>Cancel</Button>
          <Button variant="destructive" size="sm" loading={busy} onClick={() => void submit()}>Delete</Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
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
  const actions = useExplorerActions();
  const ref = React.useRef<HTMLButtonElement>(null);
  const editing = actions.canEdit && actions.inlineRenameId === node.id;
  // Reveal the active page when it changes (e.g. opened from search/links).
  React.useEffect(() => {
    if (active) ref.current?.scrollIntoView({ block: "nearest" });
  }, [active]);

  // Keyboard shortcuts on the focused row (granite parity): F2 = inline rename,
  // Delete / Cmd-Backspace = delete. Enter/Space open (native button behaviour).
  const onKeyDown = (e: React.KeyboardEvent) => {
    if (!actions.canEdit) return;
    if (e.key === "F2") {
      e.preventDefault();
      actions.beginInlineRename(node.id);
    } else if (e.key === "Delete" || (e.key === "Backspace" && (e.metaKey || e.ctrlKey))) {
      e.preventDefault();
      actions.onDelete(node);
    }
  };

  // INLINE RENAME — replaces the row with an edit-in-place input. Commit on
  // Enter via the shared connector path; cancel on Esc/blur. Disabled while the
  // save is in flight so a second Enter can't double-fire.
  if (editing) {
    return (
      <InlineRenameRow
        node={node}
        depth={depth}
        onCommit={(next) => actions.commitInlineRename(node, next)}
        onClose={() => actions.beginInlineRename(null)}
      />
    );
  }

  const rowButton = (
    <button
      ref={ref}
      type="button"
      title={node.label}
      aria-current={active ? "page" : undefined}
      onClick={() => onOpenPage(node.id)}
      onKeyDown={onKeyDown}
      style={{ paddingInlineStart: 8 + depth * INDENT }}
      className={cn(
        "group flex h-7 w-full items-center gap-1.5 rounded-sm pr-2 text-left",
        "text-[13px] leading-none",
        "text-[color:var(--color-text-secondary)]",
        "transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-inset focus-visible:ring-[color:var(--color-text-link)]",
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

  // No edit capability (mock connector / disconnected) → plain row, no menu.
  if (!actions.canEdit) return rowButton;

  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{rowButton}</ContextMenuTrigger>
      <ContextMenuContent className="w-44">
        <ContextMenuItem onSelect={() => actions.onOpen(node.id)}>Open</ContextMenuItem>
        <ContextMenuItem onSelect={() => actions.beginInlineRename(node.id)}>
          Rename
          <span className="ml-auto pl-3 text-[11px] tabular-nums text-[color:var(--color-text-quaternary)]">F2</span>
        </ContextMenuItem>
        <ContextMenuItem onSelect={() => actions.onRename(node)}>Rename…</ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() => actions.onDelete(node)}
          className="text-[color:var(--color-red-500,#ef4444)] focus:text-[color:var(--color-red-500,#ef4444)]"
        >
          Delete…
          <span className="ml-auto pl-3 text-[11px] tabular-nums text-[color:var(--color-text-quaternary)]">⌫</span>
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}

// ── Inline (edit-in-place) rename row ────────────────────────────────────────
// Replaces a file row with a text input. Commit on Enter (via the shared
// connector path), cancel on Esc; blur also commits unless the value is
// unchanged/empty. Matches the explorer's row metrics so the tree doesn't jump.
function InlineRenameRow({
  node,
  depth,
  onCommit,
  onClose,
}: {
  node: FileNode;
  depth: number;
  onCommit: (next: string) => Promise<void>;
  onClose: () => void;
}) {
  const [value, setValue] = React.useState(node.page.title ?? node.label);
  const [busy, setBusy] = React.useState(false);
  // Guards against a blur-after-Enter (or Esc) firing a second commit/close.
  const doneRef = React.useRef(false);
  const aliveRef = React.useRef(true);
  React.useEffect(() => () => { aliveRef.current = false; }, []);

  const cancel = () => {
    if (doneRef.current) return;
    doneRef.current = true;
    onClose();
  };

  const commit = async () => {
    if (doneRef.current || busy) return;
    const next = value.trim();
    // Empty or unchanged → treat as a cancel (no needless RPC / toast).
    if (!next || next === (node.page.title ?? node.label)) {
      cancel();
      return;
    }
    doneRef.current = true;
    setBusy(true);
    try {
      await onCommit(next);
      onClose();
    } catch (err) {
      // Re-open the editor so the user can retry / correct.
      doneRef.current = false;
      toast.error(err instanceof Error ? err.message : "Rename failed");
    } finally {
      if (aliveRef.current) setBusy(false);
    }
  };

  return (
    <div
      style={{ paddingInlineStart: 8 + depth * INDENT }}
      className="flex h-7 w-full items-center gap-1.5 rounded-sm pr-2"
    >
      <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" aria-hidden />
      <input
        autoFocus
        disabled={busy}
        value={value}
        aria-label={`Rename ${node.label}`}
        onChange={(e) => setValue(e.currentTarget.value)}
        onFocus={(e) => e.currentTarget.select()}
        onKeyDown={(e) => {
          if (e.key === "Enter") {
            e.preventDefault();
            void commit();
          } else if (e.key === "Escape") {
            e.preventDefault();
            cancel();
          }
          // Stop Delete/F2 etc. from bubbling to the tree's row handlers.
          e.stopPropagation();
        }}
        onBlur={() => void commit()}
        className={cn(
          "h-6 min-w-0 flex-1 rounded-sm bg-[color:var(--color-surface)] px-1.5 text-[13px] leading-none text-foreground",
          "outline-none ring-1 ring-[color:var(--color-text-link)]",
        )}
      />
    </div>
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
