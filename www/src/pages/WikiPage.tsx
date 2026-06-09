import * as React from "react";
import { useParams, useNavigate, useSearchParams } from "react-router-dom";
import { Pencil, FilePlus2, Sparkles, LayoutGrid, Table2 } from "lucide-react";
import { useWikiPage, useWikiRecents } from "@/state/wiki";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { toast } from "@/components/ui/sonner";
import { emptyCanvasBody } from "@/components/wiki/canvas/canvasSchema";
import { serializeBaseConfig, DEFAULT_BASE } from "@/components/wiki/bases/basesSchema";
import { Button } from "@/components/ui/button";
import { WikiEditor } from "@/components/wiki/editor/WikiEditor";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { WikiReadingView } from "@/components/wiki/WikiReadingView";
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
import { BookmarkButton } from "@/components/wiki/panels/BookmarkButton";
import { WikiCanvasView } from "@/components/wiki/canvas/WikiCanvasView";
import { isCanvasDoc } from "@/components/wiki/canvas/canvasSchema";
import { WikiBaseView } from "@/components/wiki/bases/WikiBaseView";
import { isBaseBody } from "@/components/wiki/bases/basesSchema";
import { useWikiCommands } from "@/components/wiki/commands/useWikiCommands";
import { WikiCommandPalette } from "@/components/wiki/commands/WikiCommandPalette";
import { WikiSettingsModal } from "@/components/wiki/settings/WikiSettingsModal";
import { Settings as SettingsIcon } from "lucide-react";

/**
 * Full-screen Memory Wiki view (inside AppShell's <Outlet/>). M1: granite read
 * surface — reading view (markdown + Obsidian extensions) in the main pane, and
 * a right rail of tabbed panels (Connections / Tags / Outline / Properties).
 * Graph (M2) and editor (M4) mount into the marked slots later.
 */
export function WikiPage() {
  const { pageId } = useParams();
  const navigate = useNavigate();
  const { connector, status } = useRuntime();
  const [searchParams, setSearchParams] = useSearchParams();
  const [reloadKey, setReloadKey] = React.useState(0);
  const [editing, setEditing] = React.useState(false);
  const { page, loading } = useWikiPage(pageId, reloadKey);
  const switcher = useWikiSwitcherHotkey(); // Cmd/Ctrl-O quick switcher (wiki-scoped)

  // Title→id resolver for wikilink hover previews + resolved-link styling.
  // Built once from the page list; dangling links resolve to undefined (no card).
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

  // Wiki-scoped command palette (Cmd-P). The wiki settings modal is opened via
  // the gear button (Cmd-, is owned by the app shell's global settings).
  const [settingsOpen, setSettingsOpen] = React.useState(false);
  const cmds = useWikiCommands({
    enabled: true,
    onOpenSwitcher: () => switcher.setOpen(true),
    onOpenSearch: () => navigate("/wiki?q="),
  });

  const q = searchParams.get("q") ?? "";
  const setQ = (next: string) => setSearchParams(next ? { q: next } : {}, { replace: true });
  // Leave edit mode whenever the route changes (new page / back to index).
  React.useEffect(() => { setEditing(false); }, [pageId]);
  // `/wiki/new` is the create surface (no pageId, not a real page).
  const creating = pageId === "new";

  // Wikilinks + tags route to a search query; the outline jumps to in-page
  // heading anchors (ids added by rehypeHeadingIds).
  const onWikiLink = (target: string) => navigate(`/wiki?q=${encodeURIComponent(target)}`);
  const onTag = (tag: string) => navigate(`/wiki?q=${encodeURIComponent(`#${tag}`)}`);
  const onJump = (slug: string) =>
    document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" });

  // A canvas / base is a wiki document whose body carries a `wiki_type`
  // frontmatter key. When such a page opens (from explorer, recents, or a
  // deep-link) it gets its dedicated full-bleed view instead of the reading
  // surface + right rail. Editing those raw bodies is intentionally not exposed
  // (the visual editors own them); the Edit button is hidden below.
  const docKind: "canvas" | "base" | "page" =
    page && pageId && !creating
      ? isCanvasDoc(page.content)
        ? "canvas"
        : isBaseBody(page.content)
          ? "base"
          : "page"
      : "page";

  // Section-global overlays (switcher + command palette + settings) — mounted in
  // every branch so the hotkeys work on canvas / base / page routes alike.
  const overlays = (
    <>
      <WikiQuickSwitcher open={switcher.open} onOpenChange={switcher.setOpen} />
      <WikiCommandPalette open={cmds.open} onOpenChange={cmds.setOpen} commands={cmds.commands} onRun={cmds.run} />
      <WikiSettingsModal open={settingsOpen} onOpenChange={setSettingsOpen} />
    </>
  );

  if (docKind === "canvas" && pageId) {
    return (
      <div className="flex min-h-0 flex-1">
        {overlays}
        <WikiCanvasView pageId={pageId} onOpenPage={(id) => navigate(`/wiki/${id}`)} className="flex-1" />
      </div>
    );
  }
  if (docKind === "base" && pageId) {
    return (
      <div className="flex min-h-0 flex-1">
        {overlays}
        <WikiBaseView pageId={pageId} />
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1">
      {overlays}
      {/* MAIN PANE — editor / search / index / reading view */}
      <div className="flex min-w-0 flex-1 flex-col">
        {creating || (pageId && editing) ? (
          // Editor owns full height (its own internal scroll).
          <WikiEditor
            pageId={creating ? undefined : pageId}
            onSaved={(id) => {
              setEditing(false);
              if (creating || id !== pageId) navigate(`/wiki/${id}`);
              else setReloadKey((k) => k + 1); // same page → force a refetch
            }}
            onCancel={() => (creating ? navigate("/wiki") : setEditing(false))}
          />
        ) : !pageId && q ? (
          <WikiSearchView query={q} onQueryChange={setQ} />
        ) : (
          <ScrollArea className="flex-1">
            <div className="mx-auto w-full max-w-[820px] px-6 pb-16 pt-6">
              {!pageId ? (
                <WikiIndex onOpenSettings={() => setSettingsOpen(true)} />
              ) : loading ? (
                <div className="text-[13px] text-[color:var(--color-text-secondary)]">Loading…</div>
              ) : !page ? (
                <div className="text-[13px] text-[color:var(--color-text-secondary)]">Page not found.</div>
              ) : (
                <div>
                  <div className="mb-2 flex justify-end gap-1.5">
                    <BookmarkButton pageId={page.id} title={page.title} />
                    <Button variant="outline" size="xs" onClick={() => setEditing(true)}>
                      <Pencil className="mr-1 size-3" /> Edit
                    </Button>
                    <Button variant="outline" size="xs" onClick={() => setSettingsOpen(true)} aria-label="Wiki settings">
                      <SettingsIcon className="size-3" />
                    </Button>
                  </div>
                  <WikiReadingView page={page} onWikiLink={onWikiLink} onTag={onTag} resolveWikiLink={resolveWikiLink} />
                </div>
              )}
            </div>
          </ScrollArea>
        )}
      </div>

      {/* RIGHT RAIL — tabbed panels (M2: a Graph tab mounts here) */}
      {pageId && page && !editing && (
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
                  <WikiBacklinksPanel page={page} onOpenPage={(id) => navigate(`/wiki/${id}`)} />
                  <div className="mt-4 border-t border-[color:var(--border)] pt-3">
                    <WikiConnectionsPanel
                      page={page}
                      onSelectEntity={(_id, canonical) => onWikiLink(canonical)}
                    />
                  </div>
                </TabsContent>
                <TabsContent value="bookmarks" className="mt-0">
                  <WikiBookmarksPanel onSelect={(id) => navigate(`/wiki/${id}`)} />
                </TabsContent>
                <TabsContent value="tags" className="mt-0">
                  <WikiTagsPanel onSelectTag={onTag} />
                </TabsContent>
                <TabsContent value="outline" className="mt-0">
                  <WikiOutlinePanel content={page.content} onJump={onJump} />
                </TabsContent>
                <TabsContent value="properties" className="mt-0">
                  {status.kind === "connected" && typeof connector.saveWikiPage === "function" ? (
                    <WikiPropertiesEditor
                      page={page}
                      onSave={async (newBody) => {
                        const res = await connector.saveWikiPage?.({ id: page.id, body: newBody });
                        if (!res) throw new Error("Save failed");
                        setReloadKey((k) => k + 1);
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
      )}
    </div>
  );
}

/** M1 index: recent pages + a tag cloud. M3 adds full search here. */
function WikiIndex({ onOpenSettings }: { onOpenSettings?: () => void }) {
  const navigate = useNavigate();
  const { connector, status } = useRuntime();
  const { pages, loading } = useWikiRecents(50);
  const canCreate = status.kind === "connected" && typeof connector.saveWikiPage === "function";
  const [creating, setCreating] = React.useState<null | "canvas" | "base">(null);

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
