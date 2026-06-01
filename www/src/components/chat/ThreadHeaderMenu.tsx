import { MoreHorizontal } from "lucide-react";
import { useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import type { Thread } from "@/domain/models";
import { toast } from "@/components/ui/sonner";
import { dispatch, useAppData } from "@/state/store";

interface Props {
  thread: Thread;
}

// "Chat actions" menu in the thread header. Mirrors the canonical Codex menu
// (thread-actions.js threadHeader.* / sidebarElectron.* messages):
//   Copy working directory / Copy session ID / Copy deeplink / Copy as Markdown
//   — Fork into local / same worktree / new worktree —
//   Open in new window — Rename chat / Archive chat (reversible) /
//   Mark as unread.
export function ThreadHeaderMenu({ thread }: Props) {
  const { projects } = useAppData();
  const navigate = useNavigate();
  const cwd = projects.find((p) => p.id === thread.projectId)?.workingDirectory ?? "";
  const copy = (text: string, success: string) => {
    navigator.clipboard?.writeText(text);
    toast(success);
  };
  const rename = () => {
    const next = prompt("Rename chat", thread.title);
    if (next != null && next.trim().length > 0) {
      dispatch.renameThread(thread.id, next.trim());
    }
  };
  const archive = () => {
    dispatch.setThreadArchived(thread.id, true);
    toast("Archived chat", {
      action: { label: "Undo", onClick: () => dispatch.setThreadArchived(thread.id, false) },
    });
  };
  const fork = (
    target: "local" | "same-worktree" | "new-worktree",
    label: string,
  ) => {
    dispatch.forkThread(thread.id, target);
    toast("Forked conversation", { description: label });
  };
  return (
    <DropdownMenu>
      <DropdownMenuTrigger asChild>
        <Button
          variant="ghost"
          size="iconSm"
          aria-label="Chat actions"
          className="text-[color:var(--color-text-tertiary)]"
        >
          <MoreHorizontal />
        </Button>
      </DropdownMenuTrigger>
      <DropdownMenuContent align="end">
        <DropdownMenuItem
          onSelect={() => copy(cwd, "Copied working directory")}
        >
          Copy working directory
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={() => copy(thread.id, "Copied session ID")}>
          Copy session ID
        </DropdownMenuItem>
        <DropdownMenuItem
          onSelect={() => copy(`codex://threads/${thread.id}`, "Copied deeplink")}
        >
          Copy deeplink
        </DropdownMenuItem>
        <DropdownMenuItem
          onSelect={() => copy(`# ${thread.title}`, "Copied conversation as Markdown")}
        >
          Copy as Markdown
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuSub>
          <DropdownMenuSubTrigger>Fork chat</DropdownMenuSubTrigger>
          <DropdownMenuSubContent>
            <DropdownMenuItem onSelect={() => fork("local", "Fork into local")}>
              Fork into local
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => fork("same-worktree", "Fork into same worktree")}
            >
              Fork into same worktree
            </DropdownMenuItem>
            <DropdownMenuItem
              onSelect={() => fork("new-worktree", "Fork into new worktree")}
            >
              Fork into new worktree
            </DropdownMenuItem>
          </DropdownMenuSubContent>
        </DropdownMenuSub>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          onSelect={() => {
            dispatch.openThreadInNewWindow(thread.id);
            toast("Opened in new window");
          }}
        >
          Open in new window
        </DropdownMenuItem>
        <DropdownMenuItem onSelect={() => navigate("/automations")}>
          Add automation…
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem onSelect={rename}>Rename chat</DropdownMenuItem>
        <DropdownMenuItem onSelect={archive}>Archive chat</DropdownMenuItem>
        <DropdownMenuItem
          onSelect={() => {
            dispatch.setThreadUnread(thread.id, true);
            toast("Marked as unread");
          }}
        >
          Mark as unread
        </DropdownMenuItem>
        <DropdownMenuSeparator />
        <DropdownMenuItem
          className="text-[color:var(--color-text-danger)] focus:text-[color:var(--color-text-danger)]"
          onSelect={() => {
            dispatch.deleteThread(thread.id);
            toast("Deleted chat");
          }}
        >
          Delete chat
        </DropdownMenuItem>
      </DropdownMenuContent>
    </DropdownMenu>
  );
}
