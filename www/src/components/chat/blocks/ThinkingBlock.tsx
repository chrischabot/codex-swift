import * as React from "react";
import { ChevronRight, Brain } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  content: string;
  status?: "streaming" | "ok" | "error" | "cancelled";
}

// Internal reasoning / chain-of-thought. Codex.app renders the streaming label
// with a "cadenced" shimmer (thinking-shimmer-83dxNCp_.css): a masked 50%-wide
// sweep slides a brighter highlight across the text, driven by steps(48, end)
// over 1s and re-triggered on a cadence (single iteration per pulse). We
// reproduce that mechanism here (masked sweep + steps timing + re-trigger
// interval) rather than the continuous background-clip gradient. Respects
// prefers-reduced-motion.
function CadencedShimmer({ children, active }: { children: string; active: boolean }) {
  const [pulse, setPulse] = React.useState(0);
  React.useEffect(() => {
    if (!active) return;
    // Re-trigger the single-iteration sweep on a cadence (sweep is 1s, idle
    // gap until the next pulse). Matches the original's cadenced re-trigger.
    const id = window.setInterval(() => setPulse((p) => p + 1), 2600);
    return () => window.clearInterval(id);
  }, [active]);
  if (!active) {
    return <span className="text-[color:var(--color-text-secondary)]">{children}</span>;
  }
  return (
    <span className="codex-cadenced-shimmer" style={{ color: "var(--color-text-secondary)" }}>
      {children}
      <span key={pulse} className="codex-cadenced-shimmer__sweep" aria-hidden>
        <span className="codex-cadenced-shimmer__highlight">{children}</span>
      </span>
      <style>{cadencedShimmerCss}</style>
    </span>
  );
}

const cadencedShimmerCss = `
.codex-cadenced-shimmer {
  position: relative;
  display: inline-block;
  -webkit-text-fill-color: currentColor;
  text-fill-color: currentColor;
  background: none;
}
.codex-cadenced-shimmer__sweep {
  pointer-events: none;
  position: absolute;
  inset: 0 auto 0 0;
  width: 50%;
  overflow: hidden;
  transform: translateX(-100%);
  -webkit-mask-image: linear-gradient(90deg, transparent 0%, #000 40% 60%, transparent 100%);
  mask-image: linear-gradient(90deg, transparent 0%, #000 40% 60%, transparent 100%);
  animation: codex-cadenced-sweep 1s steps(48, end) 1;
}
.codex-cadenced-shimmer__highlight {
  display: block;
  width: 200%;
  color: var(--foreground);
  -webkit-text-fill-color: currentColor;
  text-fill-color: currentColor;
  transform: translateX(50%);
  animation: codex-cadenced-highlight 1s steps(48, end) 1;
}
@keyframes codex-cadenced-sweep {
  0% { transform: translateX(-100%); }
  100% { transform: translateX(250%); }
}
@keyframes codex-cadenced-highlight {
  0% { transform: translateX(50%); }
  100% { transform: translateX(-125%); }
}
@media (prefers-reduced-motion: reduce) {
  .codex-cadenced-shimmer__sweep,
  .codex-cadenced-shimmer__highlight {
    animation: none;
  }
  .codex-cadenced-shimmer__sweep { display: none; }
}
`;

export function ThinkingBlock({ content, status }: Props) {
  const [open, setOpen] = React.useState(false);
  const streaming = status === "streaming";
  return (
    <div className="my-2 rounded-lg border border-[color:var(--border)] bg-background">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="flex h-8 w-full items-center gap-2 px-2.5 text-left text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
      >
        <ChevronRight className={cn("size-3.5 text-[color:var(--color-text-tertiary)] transition-transform", open && "rotate-90")} />
        <Brain className="size-3.5 text-[color:var(--color-text-tertiary)]" />
        <CadencedShimmer active={streaming}>{streaming ? "Thinking" : "Thoughts"}</CadencedShimmer>
      </button>
      {open && (
        <div className="border-t border-[color:var(--color-divider)] px-3 py-2 font-mono text-[12px] leading-[1.6] text-[color:var(--color-text-secondary)] whitespace-pre-wrap">
          {content || "(no thinking content recorded)"}
        </div>
      )}
    </div>
  );
}
