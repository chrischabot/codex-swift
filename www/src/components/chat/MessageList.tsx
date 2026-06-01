// Virtualized + sticky-to-bottom message list. Built on @tanstack/react-virtual.
//
// Design notes (matching the TanStack Virtual chat blog pattern):
//   - The list scrolls *toward* the bottom; we anchor by computing a total
//     height and only mounting visible rows. New blocks appended to the last
//     message will grow that row; we measure the row dynamically with
//     `measureElement` so the virtualizer recomputes.
//   - The sticky-to-bottom hook watches the scroll container; whenever the
//     message count grows, we call `notifyContentChanged()` and the hook
//     re-pins if the user was already at the bottom.
//   - For mid-stream block deltas (text appended to the *current* assistant
//     message), the row's height changes via ResizeObserver — we re-pin in
//     a layout effect on the message length and a hash of the trailing
//     block's content so the viewport stays glued to the bottom.

import * as React from "react";
import { useVirtualizer } from "@tanstack/react-virtual";
import type { Message } from "@/domain/models";
import { MessageView } from "./MessageView";
import { useStickToBottom } from "@/hooks/useStickToBottom";
import { ArrowUp } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  messages: Message[];
  followupsForLast?: string[];
}

export function MessageList({ messages, followupsForLast }: Props) {
  const { scrollRef, pinned, scrollToBottom, notifyContentChanged } = useStickToBottom({
    threshold: 80,
  });

  const virtualizer = useVirtualizer({
    count: messages.length,
    getScrollElement: () => scrollRef.current,
    estimateSize: () => 200,                  // best-effort; measured for real after mount
    overscan: 6,                              // small overscan; chat scrolls slowly
    getItemKey: (i) => messages[i]!.id,
  });

  // Sticky-to-bottom trigger: a single effect keyed off messages.length and
  // a cheap signature of the last message. This catches:
  //   - new messages appended (length change)
  //   - new blocks on the trailing assistant message (block count change)
  //   - mid-stream text appended to the trailing block (text length change)
  // We DON'T also key on virtualizer.getTotalSize() — that fires on every
  // measureElement re-tick (including no-op re-measures) and would write
  // scrollTop every animation frame while pinned. The tail signature
  // subsumes the cases that actually change height.
  const lastSig = React.useMemo(() => signatureOfTail(messages), [messages]);
  React.useEffect(() => {
    notifyContentChanged();
  }, [messages.length, lastSig, notifyContentChanged]);

  const totalSize = virtualizer.getTotalSize();
  const items = virtualizer.getVirtualItems();

  // Show the working-dots variant of the FAB while the assistant is streaming
  // (mirrors scroll-to-bottom-buton.js showWorkingDots).
  const last = messages[messages.length - 1];
  const working =
    last?.role === "assistant" &&
    (last.preamble === "Working" || last.preamble === "Working…");
  const showFab = !pinned && messages.length > 0;

  return (
    <div className="relative min-h-0 flex-1">
      <div ref={scrollRef} className="h-full overflow-y-auto px-4" tabIndex={0}>
        <div className="mx-auto max-w-[720px] py-6">
          {messages.length === 0 ? (
            <div className="py-8 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
              No messages yet
            </div>
          ) : (
            <div
              style={{
                height: totalSize,
                width: "100%",
                position: "relative",
              }}
            >
              {items.map((vi) => {
                const m = messages[vi.index]!;
                const isLast = vi.index === messages.length - 1;
                const followups = isLast ? followupsForLast : undefined;
                return (
                  <div
                    key={vi.key}
                    data-index={vi.index}
                    ref={virtualizer.measureElement}
                    style={{
                      position: "absolute",
                      top: 0,
                      left: 0,
                      width: "100%",
                      transform: `translateY(${vi.start}px)`,
                    }}
                  >
                    <MessageView message={m} followups={followups} />
                  </div>
                );
              })}
            </div>
          )}
        </div>
      </div>

      {/* Scroll-to-bottom FAB — always mounted; fades via opacity +
          pointer-events so it can animate in/out (scroll-to-bottom-buton.js).
          While streaming it shows three animated working dots instead of the
          arrow. */}
      <button
        type="button"
        onClick={showFab ? () => scrollToBottom({ smooth: true }) : undefined}
        aria-hidden={!showFab}
        aria-label="Scroll to bottom"
        tabIndex={showFab ? undefined : -1}
        className={cn(
          "absolute bottom-2 end-1/2 z-30 flex size-8 translate-x-1/2 items-center justify-center rounded-full border border-[color:var(--border)] bg-background bg-clip-padding text-[color:var(--color-text-secondary)] shadow-[var(--shadow-fab)] transition-opacity duration-150 ease-in-out hover:bg-[color:var(--color-surface-hover)] print:hidden",
          showFab ? "opacity-100" : "pointer-events-none opacity-0",
        )}
      >
        {working ? (
          <span aria-hidden className="flex items-center justify-center gap-1">
            <span className="codex-wave-dot size-1 rounded-full bg-[color:var(--color-text-primary)]/70" />
            <span className="codex-wave-dot size-1 rounded-full bg-[color:var(--color-text-primary)]/70" />
            <span className="codex-wave-dot size-1 rounded-full bg-[color:var(--color-text-primary)]/70" />
          </span>
        ) : (
          <ArrowUp className="size-4 rotate-180 text-[color:var(--color-text-primary)]" />
        )}
      </button>
    </div>
  );
}

// Cheap, stable hash of the *trailing* message: id + block count + last
// block content length. Changes precisely when the tail row grows.
function signatureOfTail(messages: Message[]): string {
  const last = messages[messages.length - 1];
  if (!last) return "0";
  const tail = last.blocks[last.blocks.length - 1];
  let tailLen = 0;
  if (tail) {
    if (tail.type === "markdown" || tail.type === "thinking" || tail.type === "summary")
      tailLen = tail.content.length;
    else if (tail.type === "shell")
      tailLen = (tail.output ?? "").length;
    else if (tail.type === "code-result")
      tailLen = tail.content.length;
  }
  return `${last.id}:${last.blocks.length}:${tailLen}:${last.preamble ?? ""}`;
}
