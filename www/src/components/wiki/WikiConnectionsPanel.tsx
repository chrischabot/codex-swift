import * as React from "react";
import { useMemo } from "react";
import { ChevronRight, FileText, Loader2 } from "lucide-react";
import type { WikiConnection, WikiPage, WikiPageSummary } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

interface Props {
  page: WikiPage;
  onSelectEntity?: (entityId: string, canonical: string) => void;
  /** Open a page by id — wires the "pages mentioning this entity" sub-list. */
  onOpenPage?: (id: string) => void;
}

interface RelationGroup {
  relation: string;
  items: WikiConnection[];
}

/** Group connections by relation, sorted by descending size then name; within a
 *  group, sort by descending weight then canonical name. */
function groupByRelation(connections: WikiConnection[]): RelationGroup[] {
  const map = new Map<string, WikiConnection[]>();
  for (const c of connections) {
    const rel = c.relation?.trim() || "related";
    const bucket = map.get(rel);
    if (bucket) bucket.push(c);
    else map.set(rel, [c]);
  }
  const groups: RelationGroup[] = [];
  for (const [relation, items] of map) {
    items.sort((a, b) => {
      const w = (b.weight ?? 0) - (a.weight ?? 0);
      if (w !== 0) return w;
      return a.canonical.localeCompare(b.canonical);
    });
    groups.push({ relation, items });
  }
  groups.sort((a, b) => {
    if (b.items.length !== a.items.length) return b.items.length - a.items.length;
    return a.relation.localeCompare(b.relation);
  });
  return groups;
}

function humanizeRelation(relation: string): string {
  const spaced = relation.replace(/[_-]+/g, " ");
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/** One entity row: clicking the name explores the entity graph; the chevron
 *  lazily loads + lists the PAGES that mention this entity (entity backlinks). */
function EntityRow({
  conn,
  onSelectEntity,
  onOpenPage,
}: {
  conn: WikiConnection;
  onSelectEntity?: (entityId: string, canonical: string) => void;
  onOpenPage?: (id: string) => void;
}) {
  const { connector, status } = useRuntime();
  const [open, setOpen] = React.useState(false);
  const [pages, setPages] = React.useState<WikiPageSummary[] | null>(null);
  const [loading, setLoading] = React.useState(false);
  const interactive = Boolean(onSelectEntity);
  const canExpand =
    Boolean(onOpenPage) && status.kind === "connected" && typeof connector.getWikiEntityBacklinks === "function";

  const toggle = () => {
    const next = !open;
    setOpen(next);
    if (next && pages === null && canExpand) {
      setLoading(true);
      connector
        .getWikiEntityBacklinks!(conn.entityId)
        .then((p) => setPages(p))
        .catch(() => setPages([]))
        .finally(() => setLoading(false));
    }
  };

  return (
    <div className="flex flex-col">
      <div className="group flex w-full items-center gap-1 px-3 py-1.5">
        {canExpand ? (
          <button
            type="button"
            onClick={toggle}
            aria-label={open ? "Hide pages" : "Show pages mentioning this entity"}
            className="shrink-0 text-[color:var(--color-text-quaternary)] hover:text-foreground"
          >
            <ChevronRight className={cn("size-3.5 transition-transform", open && "rotate-90")} />
          </button>
        ) : (
          <span className="w-3.5 shrink-0" />
        )}
        <button
          type="button"
          disabled={!interactive}
          onClick={interactive ? () => onSelectEntity?.(conn.entityId, conn.canonical) : undefined}
          title={conn.canonical}
          className={cn(
            "flex min-w-0 flex-1 items-center justify-between gap-2 text-left",
            interactive && "cursor-pointer",
          )}
        >
          <span
            className={cn(
              "min-w-0 truncate text-md text-foreground",
              interactive && "group-hover:text-[color:var(--text-link)]",
            )}
          >
            {conn.canonical}
          </span>
          {conn.kind ? (
            <Badge variant="outline" className="shrink-0 px-1.5 py-0.5 text-sm">
              {conn.kind}
            </Badge>
          ) : null}
        </button>
      </div>
      {open ? (
        <div className="ml-6 border-l border-[color:var(--border)] pl-2">
          {loading ? (
            <div className="flex items-center gap-1.5 px-2 py-1 text-sm text-[color:var(--color-text-tertiary)]">
              <Loader2 className="size-3.5 animate-spin" /> Loading…
            </div>
          ) : !pages || pages.length === 0 ? (
            <div className="px-2 py-1 text-sm text-[color:var(--color-text-quaternary)]">No pages</div>
          ) : (
            pages.map((p) => (
              <button
                key={p.id}
                type="button"
                onClick={() => onOpenPage?.(p.id)}
                title={p.title}
                className="flex w-full items-center gap-1.5 rounded-sm px-2 py-1 text-left text-sm text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--text-link)]"
              >
                <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" />
                <span className="min-w-0 truncate">{p.title || "Untitled"}</span>
              </button>
            ))
          )}
        </div>
      ) : null}
    </div>
  );
}

export function WikiConnectionsPanel({ page, onSelectEntity, onOpenPage }: Props) {
  const groups = useMemo(() => groupByRelation(page.connections ?? []), [page.connections]);

  if (groups.length === 0) {
    return (
      <div className="px-3 py-4 text-sm text-[color:var(--color-text-quaternary)]">
        No connections
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {groups.map((group) => (
        <section key={group.relation} className="flex flex-col">
          <div className="flex items-center justify-between px-3 pb-1 pt-3 text-sm font-semibold uppercase tracking-[0.05em] text-[color:var(--color-text-tertiary)]">
            <span>{humanizeRelation(group.relation)}</span>
            <span className="text-[color:var(--color-text-quaternary)]">{group.items.length}</span>
          </div>
          {group.items.map((conn) => (
            <EntityRow
              key={`${group.relation}:${conn.entityId}`}
              conn={conn}
              onSelectEntity={onSelectEntity}
              onOpenPage={onOpenPage}
            />
          ))}
        </section>
      ))}
    </div>
  );
}
