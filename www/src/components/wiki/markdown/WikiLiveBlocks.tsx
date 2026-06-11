import * as React from "react";
import { ArrowDownLeft, ListFilter, FileText } from "lucide-react";
import { cn } from "@/lib/utils";
import { useWikiLive } from "./WikiLiveContext";
import { useWikiMetadataIndex } from "../useWikiMetadataIndex";
import { useWikiLinkIndex, backlinksOf, type Backlink } from "../useWikiLinkIndex";
import { parseWikiQuery, evalWikiQuery } from "./wikiQuery";
import type { WikiPageSummary } from "@/runtime/connector";

// M27 live blocks: ```backlinks``` and ```query``` fences that render dynamic,
// always-current results in the reading view (granite's dataview-lite). Both
// read the shared client indexes; they only fire when WikiLiveContext.liveBlocks
// is set (top-level reading view), otherwise WikiMarkdown renders the fence as
// plain code (so they don't run inside hover cards or embeds).

function BlockShell({
  icon,
  title,
  count,
  children,
}: {
  icon: React.ReactNode;
  title: string;
  count: number;
  children: React.ReactNode;
}) {
  return (
    <div className="my-3 rounded-md border border-[color:var(--border)] bg-[color:var(--code-surface)]">
      <div className="flex items-center gap-2 border-b border-[color:var(--border)] px-3 py-1.5 text-[12px] font-semibold uppercase tracking-[0.05em] text-[color:var(--color-text-tertiary)]">
        <span className="text-[color:var(--color-text-quaternary)]" aria-hidden>
          {icon}
        </span>
        <span className="flex-1">{title}</span>
        <span className="font-normal text-[color:var(--color-text-quaternary)]">{count}</span>
      </div>
      <div className="py-1">{children}</div>
    </div>
  );
}

function PageRow({
  title,
  source,
  onOpen,
}: {
  title: string;
  source?: string;
  onOpen?: () => void;
}) {
  return (
    <button
      type="button"
      onClick={onOpen}
      disabled={!onOpen}
      className={cn(
        "flex w-full items-center gap-2 px-3 py-1 text-left text-[13px] text-foreground",
        onOpen && "hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--text-link)]",
      )}
    >
      <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" aria-hidden />
      <span className="min-w-0 flex-1 truncate">{title}</span>
      {source ? (
        <span className="shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">{source}</span>
      ) : null}
    </button>
  );
}

function EmptyRow({ children }: { children: React.ReactNode }) {
  return <div className="px-3 py-1.5 text-[13px] text-[color:var(--color-text-quaternary)]">{children}</div>;
}

/** ```backlinks``` — the current page's exact backlinks (same source as the
 *  rail panel), inline in the body. */
export function WikiBacklinksBlock({ onOpen }: { onOpen?: (id: string) => void }) {
  const { currentPageId } = useWikiLive();
  const { resolve, byId } = useWikiMetadataIndex();
  const { entries, loading } = useWikiLinkIndex();

  const backlinks = React.useMemo<Backlink[]>(
    () => (currentPageId ? backlinksOf(entries, currentPageId, resolve) : []),
    [entries, currentPageId, resolve],
  );

  return (
    <BlockShell icon={<ArrowDownLeft className="size-3.5" />} title="Backlinks" count={backlinks.length}>
      {loading && backlinks.length === 0 ? (
        <EmptyRow>Loading…</EmptyRow>
      ) : backlinks.length === 0 ? (
        <EmptyRow>No backlinks</EmptyRow>
      ) : (
        backlinks.map((b) => (
          <PageRow
            key={b.id}
            title={b.title}
            source={byId.get(b.id)?.source}
            onOpen={onOpen ? () => onOpen(b.id) : undefined}
          />
        ))
      )}
    </BlockShell>
  );
}

/** ```query``` — a bounded filter over the vault (see wikiQuery.ts), inline. */
export function WikiQueryBlock({
  source,
  onOpen,
}: {
  source: string;
  onOpen?: (id: string) => void;
}) {
  const { pages } = useWikiMetadataIndex();
  const { byId, loading } = useWikiLinkIndex();

  const results = React.useMemo<WikiPageSummary[]>(() => {
    const q = parseWikiQuery(source);
    return evalWikiQuery(q, pages, byId);
  }, [source, pages, byId]);

  return (
    <BlockShell icon={<ListFilter className="size-3.5" />} title="Query" count={results.length}>
      {loading && results.length === 0 ? (
        <EmptyRow>Loading…</EmptyRow>
      ) : results.length === 0 ? (
        <EmptyRow>No matching pages</EmptyRow>
      ) : (
        results.map((p) => (
          <PageRow
            key={p.id}
            title={p.title || "Untitled"}
            source={p.source}
            onOpen={onOpen ? () => onOpen(p.id) : undefined}
          />
        ))
      )}
    </BlockShell>
  );
}
