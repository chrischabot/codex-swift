import { CheckCircle2, Circle, Loader2, ClipboardList } from "lucide-react";
import { cn } from "@/lib/utils";

interface Step {
  id: string;
  content: string;
  status: "pending" | "in_progress" | "completed";
}

interface Props {
  title?: string;
  steps: Step[];
}

// Inline plan checklist. Same anatomy as the side-panel PlanTab but rendered
// in the chat history (so it stays addressable after the turn finishes).
export function PlanBlock({ title, steps }: Props) {
  const done = steps.filter((s) => s.status === "completed").length;
  return (
    <div className="my-3 rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] px-3 py-2">
        <ClipboardList className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <div className="text-[13px] font-medium">{title ?? "Plan"}</div>
        <div className="ml-auto flex items-center gap-2 text-[12px] text-[color:var(--color-text-tertiary)]">
          <span><span className="font-medium text-foreground">{done}</span> / {steps.length}</span>
          <div className="h-1 w-20 overflow-hidden rounded-full bg-[color:var(--color-surface-hover)]">
            <div
              className="h-1 rounded-full bg-[color:var(--color-green-500)]"
              style={{ width: `${(done / Math.max(1, steps.length)) * 100}%` }}
            />
          </div>
        </div>
      </div>
      <ul className="px-2 py-1">
        {steps.map((s) => (
          <li key={s.id} className="flex items-start gap-2 rounded-md px-2 py-1.5 text-[13px] leading-5">
            {s.status === "completed" ? (
              <CheckCircle2 className="mt-0.5 size-3.5 shrink-0 text-[color:var(--color-green-500)]" />
            ) : s.status === "in_progress" ? (
              <Loader2 className="mt-0.5 size-3.5 shrink-0 animate-spin text-[color:var(--color-blue-400)]" />
            ) : (
              <Circle className="mt-0.5 size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" />
            )}
            <span
              className={cn(
                s.status === "completed" && "text-[color:var(--color-text-tertiary)] line-through",
              )}
            >
              {s.content}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}
