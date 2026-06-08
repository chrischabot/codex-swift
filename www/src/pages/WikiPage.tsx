import { useParams, useNavigate } from "react-router-dom";
import { useWikiPage, useWikiRecents } from "@/state/wiki";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Badge } from "@/components/ui/badge";
import { Markdown } from "@/components/chat/Markdown";

/**
 * Full-screen Memory Wiki view (lives inside AppShell's <Outlet/>). M0 ships the
 * read slice: an index when no page is selected, and a page's rendered markdown
 * body + a right rail of tags and entity connections. Editor (M4), graph (M2),
 * and richer panels mount into the marked slots in later milestones.
 */
export function WikiPage() {
  const { pageId } = useParams();
  const { page, loading } = useWikiPage(pageId);

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
              <article>
                <h1 className="text-[22px] font-semibold text-foreground">{page.title}</h1>
                {page.tags && page.tags.length > 0 && (
                  <div className="mt-2 flex flex-wrap gap-1.5">
                    {page.tags.map((t) => (
                      <Badge key={t} variant="outline" className="text-[11px]">#{t}</Badge>
                    ))}
                  </div>
                )}
                <div className="mt-4">
                  {page.content.trim() ? (
                    <Markdown content={page.content} />
                  ) : (
                    <div className="text-[13px] text-[color:var(--color-text-quaternary)]">(empty page)</div>
                  )}
                </div>
              </article>
            )}
          </div>
        </ScrollArea>
      </div>

      {/* RIGHT RAIL — connections (M2: graph panel mounts here) */}
      {pageId && page && (
        <aside className="hidden w-[300px] shrink-0 flex-col border-l border-[color:var(--border)] lg:flex">
          <ScrollArea className="flex-1">
            <div className="flex flex-col gap-6 px-4 py-6">
              <section>
                <h2 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
                  Connections
                </h2>
                {!page.connections || page.connections.length === 0 ? (
                  <div className="text-[12px] text-[color:var(--color-text-quaternary)]">No connections</div>
                ) : (
                  <ul className="flex flex-col gap-1">
                    {page.connections.map((c, i) => (
                      <li
                        key={`${c.entityId}-${i}`}
                        className="flex items-center justify-between rounded-md px-2 py-1 text-[13px]"
                      >
                        <span className="truncate text-foreground">{c.canonical}</span>
                        <span className="ml-2 shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                          {c.relation}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </section>
              {/* M2 MOUNT: <WikiGraphPanel pageId={pageId} /> */}
            </div>
          </ScrollArea>
        </aside>
      )}
    </div>
  );
}

/** M0 index: recent pages. M1 adds search + a tag cloud here. */
function WikiIndex() {
  const navigate = useNavigate();
  const { pages, loading } = useWikiRecents(50);
  return (
    <div className="pt-6">
      <h1 className="text-[22px] font-semibold text-foreground">Wiki</h1>
      <p className="mt-1 text-[13px] text-[color:var(--color-text-secondary)]">
        Your Memory Wiki — browse, explore, and enrich curated knowledge.
      </p>
      <div className="mt-6">
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
    </div>
  );
}
