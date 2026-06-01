import * as React from "react";
import { ChevronRight, GitBranch, Loader2, CheckCircle2, XCircle, ExternalLink } from "lucide-react";
import { cn } from "@/lib/utils";
import { useNavigate } from "react-router-dom";

interface Props {
  agentId: string;          // "claude-agent" | "research-agent" | …
  agentName: string;        // "Claude (sub-agent)"
  goal: string;
  childThreadId?: string;
  status: "running" | "ok" | "error";
  summary?: string;
}

// A sub-agent invocation rendered inline: the parent agent spawned a child
// agent to complete a sub-task. We show the child as an indented card with
// a fork-style indicator and link out to its thread.
export function SubAgentBlock({ agentId, agentName, goal, childThreadId, status, summary }: Props) {
  const [open, setOpen] = React.useState(false);
  const navigate = useNavigate();
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex h-9 w-full items-center gap-2 px-3 text-left text-[13px] hover:bg-[color:var(--color-surface-hover)]"
      >
        <ChevronRight className={cn("size-3.5 transition-transform text-[color:var(--color-text-tertiary)]", open && "rotate-90")} />
        <GitBranch className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <span className="font-medium">{agentName}</span>
        <span className="rounded bg-[color:var(--color-surface-hover)] px-1 py-0.5 font-mono text-[10.5px] text-[color:var(--color-text-tertiary)]">
          {agentId}
        </span>
        <span className="truncate text-[color:var(--color-text-tertiary)]">— {goal}</span>
        <span className="ml-auto shrink-0">
          {status === "running" && <Loader2 className="size-3.5 animate-spin text-[color:var(--color-blue-400)]" />}
          {status === "ok"      && <CheckCircle2 className="size-3.5 text-[color:var(--color-green-500)]" />}
          {status === "error"   && <XCircle className="size-3.5 text-[color:var(--color-red-500)]" />}
        </span>
      </button>
      {open && (
        <div className="border-t border-[color:var(--color-divider)] px-3 py-2 text-[13px] leading-5 text-[color:var(--color-text-secondary)]">
          {summary ?? (status === "running" ? "Working…" : "No summary recorded.")}
          {childThreadId && (
            <button
              type="button"
              onClick={() => navigate(`/thread/${childThreadId}`)}
              className="mt-2 inline-flex items-center gap-1 rounded-md border border-[color:var(--border)] px-2 py-1 text-[12px] hover:bg-[color:var(--color-surface-hover)]"
            >
              Open sub-thread <ExternalLink className="size-3" />
            </button>
          )}
        </div>
      )}
    </div>
  );
}
