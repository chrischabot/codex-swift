import { useParams, useNavigate } from "react-router-dom";
import { useWikiPage, useWikiRecents } from "@/state/wiki";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { WikiReadingView } from "@/components/wiki/WikiReadingView";
import { WikiConnectionsPanel } from "@/components/wiki/WikiConnectionsPanel";
import { WikiPropertiesPanel } from "@/components/wiki/WikiPropertiesPanel";
import { WikiOutlinePanel } from "@/components/wiki/WikiOutlinePanel";
import { WikiTagsPanel } from "@/components/wiki/WikiTagsPanel";
import { WikiGraphView } from "@/components/wiki/graph/WikiGraphView";

/**
 * Full-screen Memory Wiki view (inside AppShell's <Outlet/>). M1: granite read
 * surface — reading view (markdown + Obsidian extensions) in the main pane, and
 * a right rail of tabbed panels (Connections / Tags / Outline / Properties).
 * Graph (M2) and editor (M4) mount into the marked slots later.
 */
export function WikiPage() {
  const { pageId } = useParams();
  const navigate = useNavigate();
  const { page, loading } = useWikiPage(pageId);

  // M1: wikilinks + tags route to a search query (full search lands in M3). The
  // outline jumps to in-page heading anchors (ids added by rehypeHeadingIds).
  const onWikiLink = (target: string) => navigate(`/wiki?q=${encodeURIComponent(target)}`);
  const onTag = (tag: string) => navigate(`/wiki?q=${encodeURIComponent(`#${tag}`)}`);
  const onJump = (slug: string) =>
    document.getElementById(slug)?.scrollIntoView({ behavior: "smooth", block: "start" });

  return (
    <div className="flex min-h-0 flex-1">
      {/* MAIN PANE — reading view */}
      <div className="flex min-w-0 flex-1 flex-col">
        <ScrollArea className="flex-1">
          <div className="mx-auto w-full max-w-[820px] px-6 pb-16 pt-6">
            {!pageId ? (
              <WikiIndex />
            ) : loading ? (
              <div className="text-[13px] text-[color:var(--color-text-secondary)]">Loading…</div>
            ) : !page ? (
              <div className="text-[13px] text-[color:var(--color-text-secondary)]">Page not found.</div>
            ) : (
              <WikiReadingView page={page} onWikiLink={onWikiLink} onTag={onTag} />
            )}
          </div>
        </ScrollArea>
      </div>

      {/* RIGHT RAIL — tabbed panels (M2: a Graph tab mounts here) */}
      {pageId && page && (
        <aside className="hidden w-[320px] shrink-0 flex-col border-l border-[color:var(--border)] lg:flex">
          <Tabs defaultValue="connections" className="flex min-h-0 flex-1 flex-col gap-0">
            <TabsList className="shrink-0 justify-start rounded-none border-b border-[color:var(--border)] bg-transparent px-2">
              <TabsTrigger value="connections">Links</TabsTrigger>
              <TabsTrigger value="graph">Graph</TabsTrigger>
              <TabsTrigger value="tags">Tags</TabsTrigger>
              <TabsTrigger value="outline">Outline</TabsTrigger>
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
                  <WikiConnectionsPanel
                    page={page}
                    onSelectEntity={(_id, canonical) => onWikiLink(canonical)}
                  />
                </TabsContent>
                <TabsContent value="tags" className="mt-0">
                  <WikiTagsPanel onSelectTag={onTag} />
                </TabsContent>
                <TabsContent value="outline" className="mt-0">
                  <WikiOutlinePanel content={page.content} onJump={onJump} />
                </TabsContent>
                <TabsContent value="properties" className="mt-0">
                  <WikiPropertiesPanel page={page} />
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
function WikiIndex() {
  const navigate = useNavigate();
  const { pages, loading } = useWikiRecents(50);
  return (
    <div className="pt-6">
      <div className="flex items-start justify-between gap-3">
        <div>
          <h1 className="text-[22px] font-semibold text-foreground">Wiki</h1>
          <p className="mt-1 text-[13px] text-[color:var(--color-text-secondary)]">
            Your Memory Wiki — browse, explore, and enrich curated knowledge.
          </p>
        </div>
        <button
          type="button"
          onClick={() => navigate("/wiki/graph")}
          className="shrink-0 rounded-md border border-[color:var(--border)] px-3 py-1.5 text-[13px] text-foreground hover:bg-[color:var(--color-surface-hover)]"
        >
          Open graph
        </button>
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
