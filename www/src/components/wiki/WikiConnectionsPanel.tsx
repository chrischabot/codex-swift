import { useMemo } from "react";
import type { WikiConnection, WikiPage } from "@/runtime/connector";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";

interface Props {
  page: WikiPage;
  onSelectEntity?: (entityId: string, canonical: string) => void;
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

export function WikiConnectionsPanel({ page, onSelectEntity }: Props) {
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
          {group.items.map((conn) => {
            const interactive = Boolean(onSelectEntity);
            return (
              <button
                key={`${group.relation}:${conn.entityId}`}
                type="button"
                disabled={!interactive}
                onClick={
                  interactive
                    ? () => onSelectEntity?.(conn.entityId, conn.canonical)
                    : undefined
                }
                title={conn.canonical}
                className={cn(
                  "group flex w-full items-center justify-between gap-2 px-3 py-1.5 text-left",
                  interactive &&
                    "cursor-pointer hover:bg-[color:var(--color-surface-hover)]",
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
            );
          })}
        </section>
      ))}
    </div>
  );
}
