import { Crosshair, CheckCircle2, Loader2, Circle, XCircle } from "lucide-react";
import { cn } from "@/lib/utils";

interface Feature {
  id: string;
  label: string;
  status: "pending" | "running" | "completed" | "failed";
}

interface Props {
  missionId: string;
  status: "running" | "paused" | "completed" | "failed" | "halted" | "error";
  features: Feature[];
  metrics: { elapsed: number; completed: number; failed: number; total: number };
}

// Higher-level "mission" dashboard: progress per-feature plus rolling metrics.
// Codex.app renders missions as a long-lived sticky card; we surface them
// inline in the conversation so the history stays addressable.
export function MissionBlock({ missionId, status, features, metrics }: Props) {
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] bg-[color:var(--sidebar)] px-3 py-2">
        <Crosshair className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <div className="text-[13px] font-medium">Mission · {missionId}</div>
        <div
          className={cn(
            "ml-auto rounded px-1.5 py-0.5 text-[10.5px] font-medium uppercase tracking-wide",
            statusTone(status),
          )}
        >
          {status}
        </div>
      </div>
      <div className="px-3 py-2 text-[12px] text-[color:var(--color-text-secondary)]">
        Elapsed {formatDur(metrics.elapsed)} · {metrics.completed}/{metrics.total} done · {metrics.failed} failed
      </div>
      <ul className="border-t border-[color:var(--color-divider)] px-2 py-1">
        {features.map((f) => (
          <li key={f.id} className="flex items-center gap-2 rounded px-2 py-1.5 text-[13px] leading-5">
            <FeatureIcon status={f.status} />
            <span className={f.status === "completed" ? "text-[color:var(--color-text-tertiary)] line-through" : ""}>
              {f.label}
            </span>
          </li>
        ))}
      </ul>
    </div>
  );
}

// Status-pill tone. Mirrors the original chart-token palette (blue=running,
// green=completed, red=failed/error, neutral=paused/halted) using the available
// --color-* tokens.
function statusTone(status: Props["status"]): string {
  switch (status) {
    case "running":   return "bg-[color:var(--color-blue-400)]/15 text-[color:var(--color-blue-400)]";
    case "completed": return "bg-[color:var(--color-green-500)]/15 text-[color:var(--color-green-500)]";
    case "failed":
    case "error":     return "bg-[color:var(--color-red-500)]/15 text-[color:var(--color-red-500)]";
    case "paused":
    case "halted":    return "bg-[color:var(--color-surface-hover)] text-[color:var(--color-text-secondary)]";
    default:          return "bg-[color:var(--color-surface-hover)] text-[color:var(--color-text-secondary)]";
  }
}

function FeatureIcon({ status }: { status: Feature["status"] }) {
  if (status === "completed") return <CheckCircle2 className="size-3.5 text-[color:var(--color-green-500)]" />;
  if (status === "running")   return <Loader2 className="size-3.5 animate-spin text-[color:var(--color-blue-400)]" />;
  if (status === "failed")    return <XCircle className="size-3.5 text-[color:var(--color-red-500)]" />;
  return <Circle className="size-3.5 text-[color:var(--color-text-quaternary)]" />;
}

function formatDur(ms: number): string {
  const s = Math.round(ms / 1000);
  if (s < 60) return `${s}s`;
  const m = Math.floor(s / 60);
  const rem = s % 60;
  return `${m}m ${rem}s`;
}
