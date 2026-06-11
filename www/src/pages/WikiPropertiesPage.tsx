import * as React from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, ChevronRight, FileText, Tags, Loader2, Search } from "lucide-react";
import { Button } from "@/components/ui/button";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible";
import { cn } from "@/lib/utils";
import { useWikiLinkIndex, propertyCatalog } from "@/components/wiki/useWikiLinkIndex";
import type { WikiIndexEntry } from "@/runtime/connector";

// M30 global properties view (route /wiki/properties). The vault-wide registry
// of frontmatter properties: every key, its distinct values with page counts,
// and the pages carrying each value (clickable). All derived from the shared
// wiki/index link+property index via propertyCatalog — no new RPC.

function norm(s: string): string {
  return s.trim().toLowerCase();
}

/** Pages carrying key=value, by title, from the link/property index entries. */
function pagesForValue(
  entries: ReadonlyArray<WikiIndexEntry>,
  key: string,
  value: string,
): Array<{ id: string; title: string }> {
  return entries
    .filter((e) => e.props[key] === value)
    .map((e) => ({ id: e.id, title: e.title || "Untitled" }))
    .sort((a, b) => a.title.localeCompare(b.title));
}

function ValueRow({
  value,
  count,
  pages,
  onOpen,
}: {
  value: string;
  count: number;
  pages: Array<{ id: string; title: string }>;
  onOpen: (id: string) => void;
}) {
  const [open, setOpen] = React.useState(false);
  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      <CollapsibleTrigger className="group flex w-full items-center gap-2 rounded-md px-2 py-1 text-left text-[13px] hover:bg-[color:var(--color-surface-hover)]">
        <ChevronRight className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)] transition-transform group-data-[state=open]:rotate-90" />
        <span className="min-w-0 flex-1 truncate text-foreground">{value}</span>
        <span className="shrink-0 text-[12px] text-[color:var(--color-text-quaternary)]">{count}</span>
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div className="ml-5 border-l border-[color:var(--border)] pl-2">
          {pages.map((p) => (
            <button
              key={p.id}
              type="button"
              onClick={() => onOpen(p.id)}
              className="flex w-full items-center gap-2 rounded-md px-2 py-1 text-left text-[13px] text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--text-link)]"
            >
              <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" />
              <span className="min-w-0 truncate">{p.title}</span>
            </button>
          ))}
        </div>
      </CollapsibleContent>
    </Collapsible>
  );
}

export function WikiPropertiesPage() {
  const navigate = useNavigate();
  const { entries, loading } = useWikiLinkIndex();
  const [query, setQuery] = React.useState("");

  const catalog = React.useMemo(() => propertyCatalog(entries), [entries]);
  const filtered = React.useMemo(() => {
    const q = norm(query);
    if (!q) return catalog;
    return catalog.filter(
      (k) => norm(k.key).includes(q) || k.values.some((v) => norm(v.value).includes(q)),
    );
  }, [catalog, query]);

  const open = (id: string) => navigate(`/wiki/${id}`);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex shrink-0 items-center gap-2 border-b border-[color:var(--border)] px-4 py-2">
        <Button variant="ghost" size="iconSm" onClick={() => navigate("/wiki")} aria-label="Back to wiki">
          <ArrowLeft />
        </Button>
        <Tags className="size-4 text-[color:var(--color-text-tertiary)]" />
        <span className="text-[13px] font-medium text-foreground">Properties</span>
        <span className="text-[12px] text-[color:var(--color-text-quaternary)]">
          {catalog.length} {catalog.length === 1 ? "key" : "keys"}
        </span>
        <div className="ml-auto flex items-center gap-1.5 rounded-md border border-[color:var(--border)] px-2">
          <Search className="size-3.5 text-[color:var(--color-text-quaternary)]" />
          <input
            value={query}
            onChange={(e) => setQuery(e.currentTarget.value)}
            placeholder="Filter properties…"
            className="h-7 w-44 bg-transparent text-[13px] text-foreground outline-none placeholder:text-[color:var(--color-text-quaternary)]"
          />
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto p-3">
        {loading && catalog.length === 0 ? (
          <div className="flex items-center justify-center gap-2 py-10 text-[13px] text-[color:var(--color-text-tertiary)]">
            <Loader2 className="size-4 animate-spin" /> Loading properties…
          </div>
        ) : catalog.length === 0 ? (
          <div className="py-10 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
            No frontmatter properties found in the vault.
          </div>
        ) : filtered.length === 0 ? (
          <div className="py-10 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
            No properties match “{query}”.
          </div>
        ) : (
          <div className="mx-auto max-w-[640px]">
            {filtered.map((k) => (
              <KeyGroup key={k.key} catalogKey={k} entries={entries} onOpen={open} />
            ))}
          </div>
        )}
      </div>
    </div>
  );
}

function KeyGroup({
  catalogKey,
  entries,
  onOpen,
}: {
  catalogKey: ReturnType<typeof propertyCatalog>[number];
  entries: ReadonlyArray<WikiIndexEntry>;
  onOpen: (id: string) => void;
}) {
  const [open, setOpen] = React.useState(false);
  return (
    <Collapsible
      open={open}
      onOpenChange={setOpen}
      className="mb-1 rounded-md border border-[color:var(--border)]"
    >
      <CollapsibleTrigger
        className={cn(
          "group flex w-full items-center gap-2 px-3 py-2 text-left",
          "text-[13px] font-semibold text-foreground",
        )}
      >
        <ChevronRight className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)] transition-transform group-data-[state=open]:rotate-90" />
        <span className="min-w-0 flex-1 truncate">{catalogKey.key}</span>
        <span className="shrink-0 text-[12px] font-normal text-[color:var(--color-text-quaternary)]">
          {catalogKey.values.length} {catalogKey.values.length === 1 ? "value" : "values"} ·{" "}
          {catalogKey.pageCount} {catalogKey.pageCount === 1 ? "page" : "pages"}
        </span>
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div className="border-t border-[color:var(--border)] p-1.5">
          {catalogKey.values.map((v) => (
            <ValueRow
              key={v.value}
              value={v.value}
              count={v.count}
              pages={pagesForValue(entries, catalogKey.key, v.value)}
              onOpen={onOpen}
            />
          ))}
        </div>
      </CollapsibleContent>
    </Collapsible>
  );
}
