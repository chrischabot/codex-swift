// useStickToBottom — keep a scroll container pinned to the bottom while
// content grows, UNLESS the user has manually scrolled up. Pairs with
// TanStack Virtual (when virtualized) or a plain mapped list.
//
// Behaviour matches the TanStack Virtual chat blog pattern:
//   - "Pinned" means the viewport is within `threshold` px of the bottom.
//   - When content changes AND we were pinned before the change, scroll to
//     the new bottom synchronously (so the user never sees the stream pop in
//     above the fold).
//   - When the user scrolls up, we unpin — even momentarily — so subsequent
//     deltas don't yank them back.
//   - Wheel/touch events count as user intent and unpin immediately.

import * as React from "react";

export interface UseStickToBottomOptions {
  threshold?: number;     // px — anything closer than this counts as "pinned"
  behavior?: ScrollBehavior;
}

export interface UseStickToBottomResult {
  scrollRef: React.RefObject<HTMLDivElement | null>;
  pinned: boolean;
  scrollToBottom: (opts?: { smooth?: boolean }) => void;
  /** Call when the content that affects scroll height has changed (e.g.
   *  message list length or a streaming block was extended). */
  notifyContentChanged: () => void;
}

export function useStickToBottom(opts: UseStickToBottomOptions = {}): UseStickToBottomResult {
  const threshold = opts.threshold ?? 80;
  const behavior  = opts.behavior  ?? "auto";

  const scrollRef = React.useRef<HTMLDivElement | null>(null);
  const pinnedRef = React.useRef(true);
  const [pinned, setPinned] = React.useState(true);
  // Suppress scroll events while a programmatic scroll is in flight. Smooth
  // scrolls fire scroll events over many frames; we stay suppressed until
  // scrollTop reaches the target (within 2px) OR a 600ms safety timeout
  // elapses, whichever comes first.
  const programmaticScrollRef = React.useRef(false);
  const programmaticTargetRef = React.useRef<number>(0);

  const scrollToBottom = React.useCallback((scrollOpts: { smooth?: boolean } = {}) => {
    const el = scrollRef.current;
    if (!el) return;
    const target = el.scrollHeight - el.clientHeight;
    programmaticScrollRef.current = true;
    programmaticTargetRef.current = target;
    el.scrollTo({ top: el.scrollHeight, behavior: scrollOpts.smooth ? "smooth" : behavior });
    pinnedRef.current = true;
    setPinned(true);
    // Multi-frame suppression: poll for arrival at target (smooth scrolls
    // resolve over several frames). Fall back to a 600ms timeout in case the
    // scroll never fully reaches the target (e.g. content shrinks during it).
    const start = performance.now();
    const tick = () => {
      const node = scrollRef.current;
      if (!node) {
        programmaticScrollRef.current = false;
        return;
      }
      const reached = Math.abs(node.scrollTop - programmaticTargetRef.current) < 2;
      const timedOut = performance.now() - start > 600;
      if (reached || timedOut) {
        programmaticScrollRef.current = false;
        return;
      }
      requestAnimationFrame(tick);
    };
    requestAnimationFrame(tick);
  }, [behavior]);

  const notifyContentChanged = React.useCallback(() => {
    if (pinnedRef.current) scrollToBottom();
  }, [scrollToBottom]);

  React.useEffect(() => {
    const el = scrollRef.current;
    if (!el) return;

    const updatePinned = () => {
      const dist = el.scrollHeight - el.scrollTop - el.clientHeight;
      const next = dist <= threshold;
      if (next !== pinnedRef.current) {
        pinnedRef.current = next;
        setPinned(next);
      }
    };

    const onScroll = () => {
      if (programmaticScrollRef.current) return;
      updatePinned();
    };

    // Wheel / touch / keyboard count as user intent — unpin immediately if
    // they would scroll the viewport away from the bottom.
    const onWheel = (e: WheelEvent) => {
      if (e.deltaY < 0 && pinnedRef.current) {
        pinnedRef.current = false;
        setPinned(false);
      }
    };
    const onKey = (e: KeyboardEvent) => {
      if ((e.key === "PageUp" || e.key === "ArrowUp" || e.key === "Home") && pinnedRef.current) {
        pinnedRef.current = false;
        setPinned(false);
      }
    };

    el.addEventListener("scroll", onScroll, { passive: true });
    el.addEventListener("wheel", onWheel, { passive: true });
    el.addEventListener("keydown", onKey);
    updatePinned();
    return () => {
      el.removeEventListener("scroll", onScroll);
      el.removeEventListener("wheel", onWheel);
      el.removeEventListener("keydown", onKey);
    };
  }, [threshold]);

  return { scrollRef, pinned, scrollToBottom, notifyContentChanged };
}
