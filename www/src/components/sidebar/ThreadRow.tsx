import type { Thread } from "@/domain/models";
import { cn, formatRelative } from "@/lib/utils";
import { ThreadContextMenu } from "./ThreadContextMenu";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/components/ui/hover-card";
import { useAppData } from "@/state/store";
import { CodexAvatar } from "@/components/chat/CodexAvatar";
import { Pin } from "lucide-react";

interface Props {
  thread: Thread;
  active?: boolean;
  onClick?: () => void;
  indent?: boolean;
}

export function ThreadRow({ thread, active, onClick, indent }: Props) {
  const { messages } = useAppData();
  const lastMessage = [...messages].reverse().find((m) => m.threadId === thread.id);
  const preview =
    lastMessage?.blocks.find((b) => b.type === "markdown")?.content ??
    lastMessage?.preamble ??
    "No messages yet";

  return (
    <HoverCard openDelay={500} closeDelay={50}>
      <HoverCardTrigger asChild>
        <div className="contents">
          <ThreadContextMenu thread={thread}>
            <button
              type="button"
              onClick={onClick}
              className={cn(
                "group flex h-7 w-full items-center rounded-md px-2 text-[13px] font-medium text-foreground transition-colors",
                "hover:bg-[color:var(--color-surface-hover)]",
                active && "bg-[color:var(--color-surface-active)]",
                indent && "pl-3",
              )}
            >
              {thread.unread && (
                <span
                  aria-label="Unread"
                  className="mr-1.5 size-1.5 shrink-0 rounded-full bg-[color:var(--color-primary)]"
                />
              )}
              <span className="flex-1 truncate text-left">{thread.title}</span>
              {thread.pinned ? (
                <Pin className="ml-2 size-3 shrink-0 text-[color:var(--color-text-quaternary)]" />
              ) : (
                <span className="ml-2 shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                  {thread.hotkey ?? formatRelative(thread.updatedAt)}
                </span>
              )}
            </button>
          </ThreadContextMenu>
        </div>
      </HoverCardTrigger>
      <HoverCardContent side="right" align="start" className="w-[300px]">
        <div className="flex items-start gap-2">
          <CodexAvatar size={20} />
          <div className="min-w-0">
            <div className="truncate text-[13px] font-medium">{thread.title}</div>
            <div className="text-[11px] text-[color:var(--color-text-tertiary)]">
              {formatRelative(thread.updatedAt)}
              {thread.modelLabel && <> · {thread.modelLabel} {thread.modelTier}</>}
              {thread.approval && <> · {thread.approval}</>}
            </div>
          </div>
        </div>
        <div className="mt-2 line-clamp-4 text-[12.5px] leading-[1.45] text-[color:var(--color-text-secondary)]">
          {truncate(preview, 220)}
        </div>
      </HoverCardContent>
    </HoverCard>
  );
}

function truncate(s: string, n: number) {
  return s.length > n ? s.slice(0, n - 1) + "…" : s;
}
