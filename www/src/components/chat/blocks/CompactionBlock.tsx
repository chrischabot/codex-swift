import * as React from "react";
import { ChevronRight, Archive } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  summary: string;
  compactedCount: number;
}

// "↑ N previous messages summarized" — a horizontal divider with a subtle
// chevron-up arrow showing where the model dropped history. Click to expand.
export function CompactionBlock({ summary, compactedCount }: Props) {
  const [open, setOpen] = React.useState(false);
  return (
    <div className="my-4">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex w-full items-center gap-2 rounded-md bg-[color:var(--color-surface-hover)] px-2 py-1 text-[12px] text-[color:var(--color-text-tertiary)] hover:text-foreground"
      >
        <Archive className="size-3" />
        <span>↑ {compactedCount} previous messages summarized</span>
        <ChevronRight className={cn("ml-auto size-3 transition-transform", open && "rotate-90")} />
      </button>
      {open && (
        <div className="mt-1 rounded-md border border-[color:var(--border)] bg-background px-3 py-2 text-[13px] leading-5 text-[color:var(--color-text-secondary)]">
          {summary}
        </div>
      )}
    </div>
  );
}
