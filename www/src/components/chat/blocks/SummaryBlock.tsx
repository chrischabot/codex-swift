import * as React from "react";
import { ChevronRight, Newspaper } from "lucide-react";
import { cn } from "@/lib/utils";

// Auto-summarization indicator (collapsed view of a longer turn).
export function SummaryBlock({ content }: { content: string }) {
  const [open, setOpen] = React.useState(true);
  return (
    <div className="my-2 rounded-lg border border-[color:var(--border)] bg-[color:var(--sidebar)]">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex h-8 w-full items-center gap-2 px-2.5 text-left text-[13px] hover:bg-[color:var(--color-surface-hover)]"
      >
        <ChevronRight className={cn("size-3.5 text-[color:var(--color-text-tertiary)] transition-transform", open && "rotate-90")} />
        <Newspaper className="size-3.5 text-[color:var(--color-text-tertiary)]" />
        <span className="font-medium">Summary</span>
      </button>
      {open && (
        <div className="border-t border-[color:var(--color-divider)] px-3 py-2 text-[13px] leading-[1.6] text-[color:var(--color-text-secondary)]">
          {content}
        </div>
      )}
    </div>
  );
}
