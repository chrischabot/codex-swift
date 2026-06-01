import * as React from "react";
import { ChevronDown } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  label: string;
  files: { path: string; delta: string }[];
  collapsedExtraFiles?: number;
  onReview?: () => void;
  onUndo?: () => void;
  onOpenFile?: (path: string) => void;
}

// Parse a delta string like "+12 -3" / "+5" / "-7" into add/delete counts.
function parseDelta(delta: string): { added: number; deleted: number } {
  const add = /\+(\d+)/.exec(delta);
  const del = /-(\d+)/.exec(delta);
  return { added: add ? Number(add[1]) : 0, deleted: del ? Number(del[1]) : 0 };
}

// Mirrors the original patch-item file diff card (patch-item-content.js):
// token-border rounded-lg container, file path as a link, additions/deletions
// shown as colored count dots (charts-blue / charts-red). The original header
// has no Undo/Review buttons — those live in the review toolbar — so they are
// only rendered here when handlers are explicitly supplied.
export function DiffSummaryCard({ label, files, collapsedExtraFiles, onReview, onUndo, onOpenFile }: Props) {
  const [expanded, setExpanded] = React.useState(false);
  const hasExtra = !!collapsedExtraFiles && collapsedExtraFiles > 0;

  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-[color:var(--color-card)]">
      <div className="flex items-center justify-between border-b border-[color:var(--border)] px-3 py-2">
        <div className="text-[13px] font-medium">{label}</div>
        {(onUndo || onReview) && (
          <div className="flex items-center gap-1.5">
            {onUndo && (
              <button
                type="button"
                onClick={onUndo}
                className="rounded-md px-2 py-0.5 text-[12px] text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
              >
                Undo
              </button>
            )}
            {onReview && (
              <button
                type="button"
                onClick={onReview}
                className="rounded-md px-2 py-0.5 text-[12px] text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
              >
                Review
              </button>
            )}
          </div>
        )}
      </div>
      <ul>
        {files.map((f, i) => {
          const { added, deleted } = parseDelta(f.delta);
          return (
            <li
              key={f.path + i}
              className="group flex items-center justify-between border-b border-[color:var(--border)] px-3 py-2 last:border-b-0"
            >
              <button
                type="button"
                onClick={() => onOpenFile?.(f.path)}
                className="max-w-full cursor-pointer truncate text-start font-mono text-[12.5px] text-[color:var(--color-blue-400)] select-text hover:underline"
              >
                {f.path}
              </button>
              <div className="flex shrink-0 items-center gap-2 text-[12px]">
                {added > 0 && (
                  <span className="flex items-center gap-1 text-[color:var(--color-text-secondary)]">
                    +{added}
                    <span className="block size-1.5 rounded-full bg-[color:var(--color-blue-400)]/70" />
                  </span>
                )}
                {deleted > 0 && (
                  <span className="flex items-center gap-1 text-[color:var(--color-text-secondary)]">
                    -{deleted}
                    <span className="block size-1.5 rounded-full bg-[color:var(--color-red-400)]/70" />
                  </span>
                )}
              </div>
            </li>
          );
        })}
      </ul>
      {hasExtra && (
        <button
          type="button"
          aria-expanded={expanded}
          onClick={() => setExpanded((v) => !v)}
          className="flex w-full items-center gap-1 border-t border-[color:var(--border)] px-3 py-2 text-left text-[12px] text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]"
        >
          <ChevronDown className={cn("size-3.5 transition-transform", expanded && "rotate-180")} />
          {expanded ? "Show less" : `Show ${collapsedExtraFiles} more files`}
        </button>
      )}
    </div>
  );
}
