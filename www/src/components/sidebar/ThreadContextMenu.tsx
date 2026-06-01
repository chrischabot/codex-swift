import * as React from "react";
import { useNavigate } from "react-router-dom";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuSeparator,
  ContextMenuSub,
  ContextMenuSubContent,
  ContextMenuSubTrigger,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import type { Thread } from "@/domain/models";
import { dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";

interface Props {
  thread: Thread;
  children: React.ReactNode;
}

// Labels/structure mirror thread-actions.js (message defs ~lines 227-360) and
// inline-mentions.js:201 ("Open in Finder"). Deeplink scheme is codex://threads/${id}
// (thread-actions.js:1008).
export function ThreadContextMenu({ thread, children }: Props) {
  const navigate = useNavigate();
  const fork = (
    target: "local" | "same-worktree" | "new-worktree",
    label: string,
  ) => {
    dispatch.forkThread(thread.id, target);
    toast("Forked conversation", { description: label });
  };
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{children}</ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem
          onSelect={() => {
            dispatch.setThreadPinned(thread.id, !thread.pinned);
            toast(thread.pinned ? "Unpinned chat" : "Pinned chat");
          }}
        >
          {thread.pinned ? "Unpin chat" : "Pin chat"}
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            const next = window.prompt("Rename chat", thread.title);
            if (next) {
              dispatch.renameThread(thread.id, next);
              toast("Renamed chat");
            }
          }}
        >
          Rename chat
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            dispatch.setThreadArchived(thread.id, true);
            toast("Archived chat", {
              action: { label: "Undo", onClick: () => dispatch.setThreadArchived(thread.id, false) },
            });
          }}
        >
          Archive chat
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            dispatch.setThreadUnread(thread.id, true);
            toast("Marked as unread");
          }}
        >
          Mark as unread
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem onSelect={() => navigate("/automations")}>
          Add automation…
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() => {
            navigator.clipboard
              ?.writeText(thread.id)
              .then(
                () => toast("Copied working directory"),
                () => toast("Failed to copy working directory"),
              );
          }}
        >
          Copy working directory
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            navigator.clipboard?.writeText(thread.id);
            toast("Copied session ID");
          }}
        >
          Copy session ID
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            navigator.clipboard?.writeText(`codex://threads/${thread.id}`);
            toast("Copied deeplink");
          }}
        >
          Copy deeplink
        </ContextMenuItem>
        <ContextMenuItem
          onSelect={() => {
            navigator.clipboard?.writeText(thread.title);
            toast("Copied conversation as Markdown");
          }}
        >
          Copy as Markdown
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuSub>
          <ContextMenuSubTrigger>Fork chat</ContextMenuSubTrigger>
          <ContextMenuSubContent>
            <ContextMenuItem onSelect={() => fork("local", "Fork into local")}>
              Fork into local
            </ContextMenuItem>
            <ContextMenuItem
              onSelect={() => fork("same-worktree", "Fork into same worktree")}
            >
              Fork into same worktree
            </ContextMenuItem>
            <ContextMenuItem
              onSelect={() => fork("new-worktree", "Fork into new worktree")}
            >
              Fork into new worktree
            </ContextMenuItem>
          </ContextMenuSubContent>
        </ContextMenuSub>
        <ContextMenuSeparator />
        <ContextMenuItem
          onSelect={() => {
            dispatch.openThreadInNewWindow(thread.id);
            toast("Opened in new window");
          }}
        >
          Open in new window
        </ContextMenuItem>
        <ContextMenuSeparator />
        <ContextMenuItem
          className="text-[color:var(--color-text-danger)] focus:text-[color:var(--color-text-danger)]"
          onSelect={() => {
            dispatch.deleteThread(thread.id);
            toast("Deleted chat");
          }}
        >
          Delete chat
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
