import { useCallback, useEffect, useMemo, useRef, useState } from "react";
import { Plus } from "lucide-react";
import type { WikiPage } from "@/runtime/connector";
import { Button } from "@/components/ui/button";
import {
  type PropertyRowState,
  type Segment,
  formatTimestamp,
  parseSegments,
  rid,
  serialize,
  splitFrontmatter,
} from "./frontmatterModel";
import { PropertyRow } from "./FrontmatterSegmentEditor";

interface Props {
  page: WikiPage;
  onSave: (newBody: string) => Promise<void>;
}

// Frontmatter (YAML-subset) editor with TRUE verbatim round-trip. The pure
// parse/serialize core lives in `frontmatterModel.ts`; the per-row editors in
// `FrontmatterSegmentEditor.tsx`. This component owns the editor STATE: it
// holds the ordered segments, commits edits back through `onSave` (with a
// sequence guard against out-of-order saves), and renders the read-only system
// metadata footer.

const HTTP_RE = /^https?:\/\//i;

interface SystemRow {
  label: string;
  node: React.ReactNode;
}

function buildSystemRows(page: WikiPage): SystemRow[] {
  const rows: SystemRow[] = [];
  const record = page as unknown as Record<string, unknown>;
  const source = page.source ?? (record.source as string | undefined);
  if (typeof source === "string" && source.trim()) {
    rows.push({ label: "Source", node: source.trim() });
  }
  const sourceURI = record.sourceURI ?? record.sourceUri ?? record.source_uri;
  if (typeof sourceURI === "string" && sourceURI.trim()) {
    const uri = sourceURI.trim();
    rows.push({
      label: "Source URI",
      node: HTTP_RE.test(uri) ? (
        <a
          href={uri}
          target="_blank"
          rel="noreferrer"
          className="break-all text-[color:var(--text-link)] hover:underline"
        >
          {uri}
        </a>
      ) : (
        <span className="break-all font-mono text-sm">{uri}</span>
      ),
    });
  }
  const updated = formatTimestamp(page.updatedAt);
  if (updated) rows.push({ label: "Updated", node: updated });
  return rows;
}

export function WikiPropertiesEditor({ page, onSave }: Props) {
  const split = useMemo(() => splitFrontmatter(page.content), [page.content]);
  const parsed = useMemo(() => parseSegments(split.yamlText), [split.yamlText]);

  const [segments, setSegments] = useState<Segment[]>(parsed.segments);
  const [saving, setSaving] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // Sequence guard: each commit gets a monotonically increasing ticket. Only
  // the most recently issued commit may apply its result; an out-of-order
  // onSave resolving late can NEVER persist a stale body / clear a fresh error.
  const commitSeq = useRef(0);
  const lastApplied = useRef(0);

  // Re-seed editor state when the underlying page changes (navigation, or a
  // save round-trips through the host into a fresh `page`).
  useEffect(() => {
    setSegments(parsed.segments);
    setError(null);
    // Treat the re-seed as the newest known state so any in-flight stale
    // commit is ignored once it resolves.
    commitSeq.current += 1;
    lastApplied.current = commitSeq.current;
  }, [parsed.segments]);

  const systemRows = useMemo(() => buildSystemRows(page), [page]);

  const commit = useCallback(
    async (nextSegments: Segment[]) => {
      const ticket = (commitSeq.current += 1);
      setSaving(true);
      setError(null);
      try {
        const nextBody = serialize(nextSegments, split.body, split.newline, split.endFence);
        await onSave(nextBody);
        // Only the latest commit may be considered authoritative.
        if (ticket >= lastApplied.current) lastApplied.current = ticket;
      } catch (err) {
        // A stale (superseded) commit must not surface its error over newer state.
        if (ticket >= lastApplied.current) {
          setError(err instanceof Error ? err.message : "Failed to save properties");
        }
      } finally {
        // Clear the saving flag only when the LATEST commit settles.
        if (ticket >= commitSeq.current) setSaving(false);
      }
    },
    [onSave, split.body, split.newline, split.endFence],
  );

  const patchRow = useCallback((id: string, patch: Partial<PropertyRowState>) => {
    setSegments((prev) =>
      prev.map((s) => (s.kind === "row" && s.id === id ? { ...s, ...patch } : s)),
    );
  }, []);

  const removeRow = useCallback(
    (id: string) => {
      setSegments((prev) => {
        const next = prev.filter((s) => !(s.kind === "row" && s.id === id));
        void commit(next);
        return next;
      });
    },
    [commit],
  );

  const addRow = useCallback(() => {
    setSegments((prev) => [
      ...prev,
      {
        kind: "row",
        id: rid(),
        key: "",
        type: "text",
        raw: "",
        bool: false,
        list: [],
        originalLines: [],
        readOnly: false,
      },
    ]);
  }, []);

  // Commit-on-blur helper: pull current segments from state and persist.
  const commitCurrent = useCallback(() => {
    setSegments((prev) => {
      void commit(prev);
      return prev;
    });
  }, [commit]);

  const rows = segments.filter((s): s is PropertyRowState => s.kind === "row");

  return (
    <div className="flex flex-col gap-3">
      <div className="flex flex-col">
        {rows.length === 0 ? (
          <div className="px-3 py-3 text-sm text-[color:var(--color-text-quaternary)]">
            No properties. Add one below.
          </div>
        ) : (
          rows.map((row) => (
            <PropertyRow
              key={row.id}
              row={row}
              disabled={saving}
              onPatch={(patch) => patchRow(row.id, patch)}
              onCommit={commitCurrent}
              onRemove={() => removeRow(row.id)}
            />
          ))
        )}
      </div>

      <div className="px-3">
        <Button
          type="button"
          variant="ghost"
          size="sm"
          disabled={saving}
          onClick={addRow}
          className="h-7 gap-1.5 px-2 text-[color:var(--color-text-tertiary)]"
        >
          <Plus className="size-3.5" />
          Add property
        </Button>
      </div>

      {error && (
        <div className="px-3 text-xs text-[color:var(--color-danger,#e5484d)]">{error}</div>
      )}

      {systemRows.length > 0 && (
        <div className="border-t border-[color:var(--border)] pt-2">
          <div className="px-3 pb-1 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-quaternary)]">
            Metadata
          </div>
          {systemRows.map((r) => (
            <div
              key={r.label}
              className="grid grid-cols-[minmax(5rem,38%)_1fr] items-baseline gap-x-3 px-3 py-1"
            >
              <span className="truncate text-sm text-[color:var(--color-text-tertiary)]">
                {r.label}
              </span>
              <span className="min-w-0 break-words text-sm text-foreground">{r.node}</span>
            </div>
          ))}
        </div>
      )}
    </div>
  );
}
