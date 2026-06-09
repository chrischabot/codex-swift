import * as React from "react";
import { useParams, useNavigate, useSearchParams, useLocation } from "react-router-dom";
import { resolveWikilinkNav } from "@/components/wiki/markdown/wikiRemarkPlugins";
import { FilePlus2, Sparkles, LayoutGrid, Table2, FileStack, ChevronDown } from "lucide-react";
import {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
} from "@/components/ui/dropdown-menu";
import { BUILTIN_TEMPLATES, applyTemplate } from "@/components/wiki/templates/templates";
import { useWikiPage, useWikiRecents } from "@/state/wiki";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { toast } from "@/components/ui/sonner";
import { emptyCanvasBody } from "@/components/wiki/canvas/canvasSchema";
import { serializeBaseConfig, DEFAULT_BASE } from "@/components/wiki/bases/basesSchema";
import { Button } from "@/components/ui/button";
import { WikiEditor } from "@/components/wiki/editor/WikiEditor";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { WikiConnectionsPanel } from "@/components/wiki/WikiConnectionsPanel";
import { WikiPropertiesPanel } from "@/components/wiki/WikiPropertiesPanel";
import { WikiPropertiesEditor } from "@/components/wiki/panels/WikiPropertiesEditor";
import { WikiOutlinePanel } from "@/components/wiki/WikiOutlinePanel";
import { WikiTagsPanel } from "@/components/wiki/WikiTagsPanel";
import { WikiGraphView } from "@/components/wiki/graph/WikiGraphView";
import { WikiSearchView } from "@/components/wiki/WikiSearchView";
import { WikiQuickSwitcher } from "@/components/wiki/WikiQuickSwitcher";
import { useWikiSwitcherHotkey } from "@/components/wiki/useWikiSwitcherHotkey";
import { WikiBacklinksPanel } from "@/components/wiki/panels/WikiBacklinksPanel";
import { WikiBookmarksPanel } from "@/components/wiki/panels/WikiBookmarksPanel";
import { isCanvasDoc } from "@/components/wiki/canvas/canvasSchema";
import { isBaseBody } from "@/components/wiki/bases/basesSchema";
import { useWikiWorkspace } from "@/components/wiki/workspace/useWikiWorkspace";
import { WikiWorkspace } from "@/components/wiki/workspace/WikiWorkspaceView";
import { activePageId, isPristine, type Leaf, type TabGroupId } from "@/components/wiki/workspace/wikiWorkspace";
import { WikiLeafBody, type LeafBodyCallbacks } from "@/components/wiki/workspace/WikiLeafBody";
import { isPopoutWindow } from "@/components/wiki/workspace/popout";
import { useWikiCommands } from "@/components/wiki/commands/useWikiCommands";
import { WikiCommandPalette } from "@/components/wiki/commands/WikiCommandPalette";
import { WikiSettingsModal } from "@/components/wiki/settings/WikiSettingsModal";
import { Settings as SettingsIcon } from "lucide-react";

/**
 * Full-screen Memory Wiki view (inside AppShell's <Outlet/>). The page-viewing
 * surface is a multi-pane WORKSPACE (granite parity, M22): columns → groups →
 * panes, each pane its own tab strip + leaf body. The route `/wiki/:pageId`
 * mirrors the active pane's page (deep-links, back/forward, bookmarks all keep
 * working); the index / search / create surfaces render only when the workspace
 * is pristine. The right rail + section overlays are global, following the
 * active leaf.
 */
export function WikiPage() {
  // Pop-out windows render a single chrome-less page (no workspace / rail /
  // overlays / cross-window sync). The branch is stable per window load.
  if (isPopoutWindow()) return <WikiPopoutPage />;
  return <WikiWorkspacePage />;
}

/**
 * Chrome-less single-page view for a `?popout=1` window. Reuses the per-leaf
 * body (reading / canvas / base + inline edit); wikilinks navigate within the
 * pop-out (keeping it chrome-less). No multi-pane workspace, no right rail.
 */
function WikiPopoutPage() {
  const { pageId } = useParams();
  const navigate = useNavigate();
  const location = useLocation();
  const { connector, status } = useRuntime();
  const [idByTitle, setIdByTitle] = React.useState<Map<string, string>>(new Map());
  React.useEffect(() => {
    if (status.kind !== "connected" || !connector.listWikiPages) return;
    let alive = true;
    connector.listWikiPages({ limit: 1000 })
      .then((ps) => {
        if (!alive) return;
        const m = new Map<string, string>();
        for (const p of ps) m.set(p.title.toLowerCase(), p.id);
        setIdByTitle(m);
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [connector, status.kind]);
  const resolveWikiLink = React.useCallback(
    (title: string) => idByTitle.get(title.trim().toLowerCase()),
    [idByTitle],
  );
  // Keep popout=1 on every in-pop-out navigation so the window stays bare,
  // preserving any query (e.g. an unresolved link → /wiki?q=…) and hash.
  const popNav = (to: string) => {
    if (to.startsWith("#")) {
      navigate({ pathname: location.pathname, hash: to, search: "?popout=1" });
      return;
    }
    const u = new URL(to, window.location.origin);
    u.searchParams.set("popout", "1");
    navigate({ pathname: u.pathname, search: u.search, hash: u.hash });
  };
  const callbacks: LeafBodyCallbacks = {
    onWikiLink: (target) => popNav(resolveWikilinkNav(target, resolveWikiLink)),
    onTag: () => {},
    onJump: (slug) => document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" }),
    resolveWikiLink,
    onOpenSettings: () => {},
    onDeleted: () => window.close(),
    onPageSaved: () => {},
  };
  if (!pageId) return <div className="p-6 text-[13px] text-[color:var(--color-text-secondary)]">No page.</div>;
  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <WikiLeafBody
        key={`popout:${pageId}`}
        leaf={{ id: `popout:${pageId}`, state: { type: "page", pageId } }}
        isActive
        callbacks={callbacks}
      />
    </div>
  );
}

function WikiWorkspacePage() {
  const { pageId } = useParams();
  const navigate = useNavigate();
  const { connector, status } = useRuntime();
  const [searchParams, setSearchParams] = useSearchParams();
  const location = useLocation();
  const switcher = useWikiSwitcherHotkey(); // Cmd/Ctrl-O quick switcher (wiki-scoped)
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  // Bumped on any page save/delete so the live page list + the right rail's
  // active-page fetch both refresh.
  const [dataVersion, setDataVersion] = React.useState(0);

  const ws = useWikiWorkspace();
  const apid = activePageId(ws.state);
  const pristine = isPristine(ws.state);
  const creating = pageId === "new";
  const q = searchParams.get("q") ?? "";

  // ── id ⇄ title maps (live page list) ──────────────────────────────────────
  // titleById feeds the tab strips; idByTitle resolves wikilink targets.
  const [idByTitle, setIdByTitle] = React.useState<Map<string, string>>(new Map());
  const [titleById, setTitleById] = React.useState<Map<string, string>>(new Map());
  React.useEffect(() => {
    if (status.kind !== "connected" || !connector.listWikiPages) return;
    let alive = true;
    connector.listWikiPages({ limit: 1000 })
      .then((ps) => {
        if (!alive) return;
        const byTitle = new Map<string, string>();
        const byId = new Map<string, string>();
        for (const p of ps) {
          byTitle.set(p.title.toLowerCase(), p.id);
          byId.set(p.id, p.title);
        }
        setIdByTitle(byTitle);
        setTitleById(byId);
      })
      .catch(() => {});
    return () => { alive = false; };
  }, [connector, status.kind, dataVersion]);
  const resolveWikiLink = React.useCallback(
    (title: string) => idByTitle.get(title.trim().toLowerCase()),
    [idByTitle],
  );

  // ── route ⇄ workspace sync (single reconciler) ────────────────────────────
  // The URL (`urlId`) and the active pane's page (`wsId`) must stay equal, but
  // EITHER side can change first: a route change (deep-link, explorer/wikilink
  // click, back/forward) must drive the workspace; a workspace change (focus /
  // close / split / drag) must drive the URL. Two separate effects deadlock —
  // when the two disagree, each insists ITS value is authoritative and they
  // ping-pong the URL forever (100% CPU). So a SINGLE effect arbitrates using a
  // `lastSync` ref: whichever value diverged from the last reconciled point is
  // the one that changed, and therefore the authority. The other side follows;
  // next run both equal `lastSync` and it no-ops. `replace` since the URL
  // mirrors internal state, not a fresh navigation.
  const urlId = pageId && pageId !== "new" ? pageId : null;
  const wsId = apid;
  const lastSync = React.useRef<string | null | undefined>(undefined);
  React.useEffect(() => {
    if (creating) return; // /wiki/new owns the URL until it saves
    if (urlId !== lastSync.current) {
      lastSync.current = urlId;
      if (urlId) ws.openPage(urlId); // URL → workspace
    } else if (wsId !== lastSync.current) {
      lastSync.current = wsId;
      navigate(wsId ? `/wiki/${wsId}` : "/wiki", { replace: true }); // workspace → URL
    }
  }, [urlId, wsId, creating, navigate, ws.openPage]);

  // Wiki-scoped command palette (Cmd-P).
  const cmds = useWikiCommands({
    enabled: true,
    onOpenSwitcher: () => switcher.setOpen(true),
    onOpenSearch: () => navigate("/wiki?q="),
  });

  const setQ = (next: string) => setSearchParams(next ? { q: next } : {}, { replace: true });
  const onTag = React.useCallback(
    (tag: string) => navigate(`/wiki?q=${encodeURIComponent(`#${tag}`)}`),
    [navigate],
  );

  // Scroll to the URL hash fragment (heading slug or `block-<id>`) after render.
  React.useEffect(() => {
    if (!apid) return;
    const raw = location.hash.replace(/^#/, "");
    if (!raw) return;
    const id = decodeURIComponent(raw);
    const t = window.setTimeout(() => {
      document.getElementById(id)?.scrollIntoView({ behavior: "smooth", block: "start" });
    }, 60);
    return () => window.clearTimeout(t);
  }, [apid, location.hash]);

  // Per-pane body callbacks. Navigation focuses the pane first so the URL (and
  // the route→workspace effect) lands the new page in the right pane; delete
  // closes the pane's leaf rather than leaving the workspace.
  const buildCallbacks = React.useCallback(
    (leaf: Leaf, groupId: TabGroupId): LeafBodyCallbacks => ({
      onWikiLink: (target: string) => {
        const nav = resolveWikilinkNav(target, resolveWikiLink);
        if (!nav.startsWith("#")) ws.focusGroup(groupId);
        if (nav.startsWith("#")) navigate({ pathname: location.pathname, hash: nav });
        else navigate(nav);
      },
      onTag,
      onJump: (slug: string) =>
        document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" }),
      resolveWikiLink,
      onOpenSettings: () => setSettingsOpen(true),
      onDeleted: () => {
        ws.closeLeaf(leaf.id);
        setDataVersion((v) => v + 1);
      },
      onPageSaved: () => setDataVersion((v) => v + 1),
    }),
    [resolveWikiLink, ws, navigate, location.pathname, onTag],
  );

  // Section-global overlays (hotkeys work on every surface).
  const overlays = (
    <>
      <WikiQuickSwitcher open={switcher.open} onOpenChange={switcher.setOpen} />
      <WikiCommandPalette open={cmds.open} onOpenChange={cmds.setOpen} commands={cmds.commands} onRun={cmds.run} />
      <WikiSettingsModal open={settingsOpen} onOpenChange={setSettingsOpen} />
    </>
  );

  // ── render-surface selection ──────────────────────────────────────────────
  //  creating → editor; bare /wiki?q= → search; pristine /wiki → index;
  //  otherwise → the multi-pane workspace.
  if (creating) {
    return (
      <div className="flex min-h-0 flex-1 flex-col">
        {overlays}
        <WikiEditor onSaved={(id) => navigate(`/wiki/${id}`)} onCancel={() => navigate("/wiki")} />
      </div>
    );
  }
  if (!pageId && q && pristine) {
    return (
      <div className="flex min-h-0 flex-1 flex-col">
        {overlays}
        <WikiSearchView query={q} onQueryChange={setQ} />
      </div>
    );
  }
  if (!pageId && pristine) {
    return (
      <div className="flex min-h-0 flex-1 flex-col">
        {overlays}
        <ScrollArea className="flex-1">
          <div className="mx-auto w-full max-w-[820px] px-6 pb-16 pt-6">
            <WikiIndex onOpenSettings={() => setSettingsOpen(true)} />
          </div>
        </ScrollArea>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1">
      {overlays}
      <div className="flex min-w-0 flex-1 flex-col">
        <WikiWorkspace ws={ws} titleById={titleById} buildCallbacks={buildCallbacks} />
      </div>
      <WikiRightRail
        pageId={apid}
        dataVersion={dataVersion}
        onOpenPage={(id) => navigate(`/wiki/${id}`)}
        onWikiLink={(canonical) => {
          const nav = resolveWikilinkNav(canonical, resolveWikiLink);
          if (nav.startsWith("#")) navigate({ pathname: location.pathname, hash: nav });
          else navigate(nav);
        }}
        onTag={onTag}
        onSaved={() => setDataVersion((v) => v + 1)}
      />
    </div>
  );
}

/**
 * Global right rail — tabbed panels (Links / Graph / Tags / Outline / Saved /
 * Info) for the ACTIVE leaf's page. Hidden for the index, canvas, and base
 * surfaces (which carry no markdown rail).
 */
function WikiRightRail({
  pageId,
  dataVersion,
  onOpenPage,
  onWikiLink,
  onTag,
  onSaved,
}: {
  pageId: string | null;
  dataVersion: number;
  onOpenPage: (id: string) => void;
  onWikiLink: (canonical: string) => void;
  onTag: (tag: string) => void;
  onSaved: () => void;
}) {
  const { connector, status } = useRuntime();
  const { page } = useWikiPage(pageId ?? undefined, dataVersion);
  if (!pageId || !page) return null;
  // Canvas / base pages own their full surface — no markdown rail.
  if (isCanvasDoc(page.content) || isBaseBody(page.content)) return null;

  return (
    <aside className="hidden w-[320px] shrink-0 flex-col border-l border-[color:var(--border)] lg:flex">
      <Tabs defaultValue="connections" className="flex min-h-0 flex-1 flex-col gap-0">
        <TabsList className="shrink-0 justify-start rounded-none border-b border-[color:var(--border)] bg-transparent px-2">
          <TabsTrigger value="connections">Links</TabsTrigger>
          <TabsTrigger value="graph">Graph</TabsTrigger>
          <TabsTrigger value="tags">Tags</TabsTrigger>
          <TabsTrigger value="outline">Outline</TabsTrigger>
          <TabsTrigger value="bookmarks">Saved</TabsTrigger>
          <TabsTrigger value="properties">Info</TabsTrigger>
        </TabsList>
        {/* Graph tab fills the rail height (a canvas), so it sits OUTSIDE the
            scroll area; the other panels scroll. */}
        <TabsContent value="graph" className="mt-0 min-h-0 flex-1 p-3 data-[state=inactive]:hidden">
          {page.connections && page.connections.length > 0 ? (
            <WikiGraphView seedEntityId={page.connections[0].entityId} depth={2} className="h-full w-full" />
          ) : (
            <div className="text-[12px] text-[color:var(--color-text-quaternary)]">No graph for this page</div>
          )}
        </TabsContent>
        <ScrollArea className="min-h-0 flex-1">
          <div className="px-3 py-4">
            <TabsContent value="connections" className="mt-0">
              <WikiBacklinksPanel page={page} onOpenPage={onOpenPage} />
              <div className="mt-4 border-t border-[color:var(--border)] pt-3">
                <WikiConnectionsPanel page={page} onSelectEntity={(_id, canonical) => onWikiLink(canonical)} />
              </div>
            </TabsContent>
            <TabsContent value="bookmarks" className="mt-0">
              <WikiBookmarksPanel onSelect={onOpenPage} />
            </TabsContent>
            <TabsContent value="tags" className="mt-0">
              <WikiTagsPanel onSelectTag={onTag} />
            </TabsContent>
            <TabsContent value="outline" className="mt-0">
              <WikiOutlinePanel
                content={page.content}
                onJump={(slug) =>
                  document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" })
                }
              />
            </TabsContent>
            <TabsContent value="properties" className="mt-0">
              {status.kind === "connected" && typeof connector.saveWikiPage === "function" ? (
                <WikiPropertiesEditor
                  page={page}
                  onSave={async (newBody) => {
                    const res = await connector.saveWikiPage?.({ id: page.id, body: newBody });
                    if (!res) throw new Error("Save failed");
                    onSaved();
                  }}
                />
              ) : (
                <WikiPropertiesPanel page={page} />
              )}
            </TabsContent>
          </div>
        </ScrollArea>
      </Tabs>
    </aside>
  );
}

/** M1 index: recent pages + a tag cloud. M3 adds full search here. */
function WikiIndex({ onOpenSettings }: { onOpenSettings?: () => void }) {
  const navigate = useNavigate();
  const { connector, status } = useRuntime();
  const { pages, loading } = useWikiRecents(50);
  const canCreate = status.kind === "connected" && typeof connector.saveWikiPage === "function";
  const [creating, setCreating] = React.useState<null | "canvas" | "base">(null);

  // Create a page from a named template (placeholders resolved) then open it.
  const createFromTemplate = async (templateId: string) => {
    const tpl = BUILTIN_TEMPLATES.find((t) => t.id === templateId);
    if (!tpl || !connector.saveWikiPage || creating) return;
    setCreating("canvas"); // reuse the busy flag to disable the buttons
    try {
      const { title, body } = applyTemplate(tpl, { date: new Date() });
      const res = await connector.saveWikiPage({ title, body });
      if (res) navigate(`/wiki/${res.id}`);
      else toast.error("Failed to create page");
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Failed to create page");
    } finally {
      setCreating(null);
    }
  };

  // Create a typed doc (canvas/base) then route to it; WikiPage branches on the
  // wiki_type frontmatter and opens the dedicated view.
  const createTyped = async (kind: "canvas" | "base") => {
    if (!connector.saveWikiPage || creating) return;
    setCreating(kind);
    try {
      const body = kind === "canvas" ? emptyCanvasBody() : serializeBaseConfig(DEFAULT_BASE);
      const title = kind === "canvas" ? "Untitled canvas" : "Untitled base";
      const res = await connector.saveWikiPage({ title, body });
      if (res) navigate(`/wiki/${res.id}`);
      else toast.error(`Failed to create ${kind}`);
    } catch (err) {
      toast.error(err instanceof Error ? err.message : `Failed to create ${kind}`);
    } finally {
      setCreating(null);
    }
  };

  return (
    <div className="pt-6">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-semibold text-foreground">Wiki</h1>
          <p className="mt-1 text-[13px] text-[color:var(--color-text-secondary)]">
            Your Memory Wiki — browse, explore, and enrich curated knowledge.
          </p>
        </div>
        <div className="flex shrink-0 items-center gap-2">
          <Button variant="outline" size="xs" onClick={() => navigate("/wiki/new")}>
            <FilePlus2 className="mr-1 size-3" /> New page
          </Button>
          {canCreate && (
            <>
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" size="xs" disabled={!!creating}>
                    <FileStack className="mr-1 size-3" /> Template
                    <ChevronDown className="ml-1 size-3" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="end" className="w-56">
                  {BUILTIN_TEMPLATES.map((t) => (
                    <DropdownMenuItem key={t.id} onSelect={() => void createFromTemplate(t.id)} className="flex flex-col items-start gap-0.5">
                      <span className="text-[13px]">{t.name}</span>
                      <span className="text-[11px] text-[color:var(--color-text-tertiary)]">{t.description}</span>
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
              <Button variant="outline" size="xs" disabled={!!creating} onClick={() => void createTyped("canvas")}>
                <LayoutGrid className="mr-1 size-3" /> New canvas
              </Button>
              <Button variant="outline" size="xs" disabled={!!creating} onClick={() => void createTyped("base")}>
                <Table2 className="mr-1 size-3" /> New base
              </Button>
            </>
          )}
          <Button variant="outline" size="xs" onClick={() => navigate("/wiki/enrich")}>
            <Sparkles className="mr-1 size-3" /> Enrich
          </Button>
          <button
            type="button"
            onClick={() => navigate("/wiki/graph")}
            className="rounded-md border border-[color:var(--border)] px-3 py-1.5 text-[13px] text-foreground hover:bg-[color:var(--color-surface-hover)]"
          >
            Open graph
          </button>
          {onOpenSettings && (
            <Button variant="outline" size="xs" onClick={onOpenSettings} aria-label="Wiki settings">
              <SettingsIcon className="size-3" />
            </Button>
          )}
        </div>
      </div>
      <div className="mt-6 grid grid-cols-1 gap-8 lg:grid-cols-[1fr_240px]">
        <div>
          <h2 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
            Recent pages
          </h2>
          {loading ? (
            <div className="text-[13px] text-[color:var(--color-text-secondary)]">Loading…</div>
          ) : pages.length === 0 ? (
            <div className="text-[13px] text-[color:var(--color-text-quaternary)]">
              No wiki pages yet. Pages appear here as your Memory Wiki is populated.
            </div>
          ) : (
            <ul className="flex flex-col gap-0.5">
              {pages.map((p) => (
                <li key={p.id}>
                  <button
                    type="button"
                    onClick={() => navigate(`/wiki/${p.id}`)}
                    className="w-full rounded-md px-2 py-1.5 text-left hover:bg-[color:var(--color-surface-hover)]"
                  >
                    <div className="truncate text-[14px] text-foreground">{p.title}</div>
                    {p.excerpt && (
                      <div className="truncate text-[12px] text-[color:var(--color-text-tertiary)]">{p.excerpt}</div>
                    )}
                  </button>
                </li>
              ))}
            </ul>
          )}
        </div>
        <div>
          <h2 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
            Tags
          </h2>
          <WikiTagsPanel onSelectTag={(t) => navigate(`/wiki?q=${encodeURIComponent(`#${t}`)}`)} />
        </div>
      </div>
    </div>
  );
}
