import { Box, Play, Square, AlertTriangle } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  event: "starting" | "ready" | "stopped" | "crashed";
  sandboxId: string;
  cwd?: string;
  durationMs?: number;
}

// Tiny status pill: "Sandbox started · cwd ~/Projects/diminuendo" / "Sandbox
// stopped (12.3s)" / "Sandbox crashed". Matches the thread-page-bottom-
// panel-state visual but as an inline mark.
export function SandboxBlock({ event, sandboxId, cwd, durationMs }: Props) {
  const Icon =
    event === "starting" ? Play :
    event === "ready"    ? Box :
    event === "stopped"  ? Square :
    AlertTriangle;
  const tone =
    event === "ready"   ? "ok" :
    event === "crashed" ? "err" :
    "muted";
  return (
    <div
      className={cn(
        "my-2 inline-flex items-center gap-2 rounded-md border px-2 py-1 text-[11.5px]",
        tone === "ok"     && "border-[color:var(--color-green-500)]/30 bg-[color:var(--color-green-500)]/5 text-[color:var(--color-green-500)]",
        tone === "err"    && "border-[color:var(--color-red-500)]/30   bg-[color:var(--color-red-500)]/5   text-[color:var(--color-red-500)]",
        tone === "muted"  && "border-[color:var(--border)] bg-background text-[color:var(--color-text-secondary)]",
      )}
    >
      <Icon className="size-3" />
      <span className="font-medium capitalize">Sandbox {event}</span>
      <span className="text-[color:var(--color-text-tertiary)]">· {sandboxId}</span>
      {cwd && <span className="font-mono text-[color:var(--color-text-tertiary)]">· {cwd}</span>}
      {durationMs != null && <span className="text-[color:var(--color-text-tertiary)]">· {(durationMs / 1000).toFixed(1)}s</span>}
    </div>
  );
}
