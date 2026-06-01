import * as React from "react";
import { cn } from "@/lib/utils";

interface Props {
  /** Defaults to "Thinking" to match thinkingShimmer.default in the original. */
  label?: string;
  className?: string;
}

// Cadenced thinking shimmer, mirroring output/webview/thinking-shimmer.js +
// thinking-shimmer-83dxNCp_.css. Rather than a continuous infinite sweep, the
// original runs a one-shot 1s sweep after a 600ms initial delay and then
// re-triggers it every 4s by toggling an `active` class. The sweep is disabled
// under prefers-reduced-motion (the CSS guards the animation too).
const RUN_MS = 1000;
const INTERVAL_MS = 4000;
const INITIAL_DELAY_MS = 600;

export function ThinkingShimmer({ label = "Thinking", className }: Props) {
  const rootRef = React.useRef<HTMLSpanElement>(null);

  React.useEffect(() => {
    if (
      typeof window === "undefined" ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      return;
    }
    const node = rootRef.current;
    if (!node) return;

    let runTimeout: number | undefined;
    const clearRunTimeout = () => {
      if (runTimeout != null) {
        window.clearTimeout(runTimeout);
        runTimeout = undefined;
      }
    };
    const runOnce = () => {
      clearRunTimeout();
      // Restart the one-shot animation by removing then re-adding the class.
      node.classList.remove("codex-shimmer--active");
      // Force reflow so the re-added class restarts the animation.
      void node.offsetWidth;
      node.classList.add("codex-shimmer--active");
      runTimeout = window.setTimeout(() => {
        node.classList.remove("codex-shimmer--active");
        runTimeout = undefined;
      }, RUN_MS);
    };

    let interval: number | undefined;
    const startTimeout = window.setTimeout(() => {
      runOnce();
      interval = window.setInterval(runOnce, INTERVAL_MS);
    }, INITIAL_DELAY_MS);

    return () => {
      clearRunTimeout();
      window.clearTimeout(startTimeout);
      if (interval != null) window.clearInterval(interval);
      node.classList.remove("codex-shimmer--active");
    };
  }, []);

  return (
    <div className={cn("mb-3 flex items-center gap-2", className)}>
      <span
        ref={rootRef}
        className="codex-shimmer text-size-chat text-[14px] leading-[1.5] select-none truncate"
      >
        {label}
        <span aria-hidden className="codex-shimmer__sweep">
          <span className="codex-shimmer__highlight">{label}</span>
        </span>
      </span>
    </div>
  );
}
