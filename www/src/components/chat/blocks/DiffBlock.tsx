import * as React from "react";
import { FileText, ChevronRight } from "lucide-react";
import { cn } from "@/lib/utils";
import { parseUnifiedDiff } from "@/lib/diff";
import type { DiffLine } from "@/domain/models";

interface Props {
  path: string;
  unifiedDiff?: string;
  added?: number;
  removed?: number;
}

// Compact inline chat variant of the rich side-panel diff. It uses the SAME
// shared parser (@/lib/diff) as the Review tab so line numbers / classification
// can never diverge; read-only, no stage/unstage/revert-hunk interactions.
export function DiffBlock({ path, unifiedDiff, added, removed }: Props) {
  const [open, setOpen] = React.useState(true);
  const rows: DiffLine[] = React.useMemo(() => {
    const files = parseUnifiedDiff(unifiedDiff ?? "");
    // The block carries a single file's diff; flatten all parsed files' lines.
    return files.flatMap((f) => f.lines);
  }, [unifiedDiff]);
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex h-9 w-full items-center gap-2 border-b border-[color:var(--color-divider)] px-3 text-left text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
      >
        <ChevronRight className={cn("size-3.5 transition-transform", open && "rotate-90")} />
        <FileText className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <span className="font-mono">{path}</span>
        {(added != null || removed != null) && (
          <span className="ml-auto font-mono text-[11.5px]">
            <span className="text-[color:var(--color-text-success)]">+{added ?? 0}</span>{" "}
            <span className="text-[color:var(--color-text-danger)]">-{removed ?? 0}</span>
          </span>
        )}
      </button>
      {open && (
        <div className="overflow-x-auto font-mono text-[12px] leading-[1.55]">
          {rows.map((r, i) => {
            if (r.kind === "header" || r.kind === "gap") {
              return (
                <div
                  key={i}
                  className="flex bg-[color:var(--color-surface-hover)] px-3 py-0.5 text-[color:var(--color-text-tertiary)]"
                >
                  {r.text || "@@"}
                </div>
              );
            }
            const isAdd = r.kind === "added";
            const isDel = r.kind === "removed";
            return (
              <div
                key={i}
                className={cn(
                  "flex",
                  isAdd && "bg-[color:var(--color-diff-added-bg)]",
                  isDel && "bg-[color:var(--color-diff-deleted-bg)]",
                )}
              >
                <span
                  className={cn(
                    "w-9 shrink-0 select-none px-1 text-right tabular-nums text-[color:var(--color-text-quaternary)]",
                    isDel && "bg-[color:var(--color-diff-deleted-gutter)]",
                    isAdd && "bg-[color:var(--color-diff-added-gutter)]",
                  )}
                >
                  {r.oldLine ?? ""}
                </span>
                <span
                  className={cn(
                    "w-9 shrink-0 select-none px-1 text-right tabular-nums text-[color:var(--color-text-quaternary)]",
                    isDel && "bg-[color:var(--color-diff-deleted-gutter)]",
                    isAdd && "bg-[color:var(--color-diff-added-gutter)]",
                  )}
                >
                  {r.newLine ?? ""}
                </span>
                <span className="w-3 shrink-0 select-none text-center text-[color:var(--color-text-quaternary)]">
                  {isAdd ? "+" : isDel ? "-" : " "}
                </span>
                <span
                  className={cn(
                    "whitespace-pre pr-3",
                    isAdd && "text-[color:var(--color-text-success)]",
                    isDel && "text-[color:var(--color-text-danger)]",
                  )}
                >
                  {r.text || " "}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
