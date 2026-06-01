import * as React from "react";
import { GitBranch, GitCommit, GitPullRequest, Undo2, ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { toast } from "@/components/ui/sonner";

interface FileEntry {
  path: string;
  added: number;
  removed: number;
}

interface Props {
  files: FileEntry[];
  branch: string;
  /** When false, the project has no git repo yet (shows "Create a Git repository"). */
  hasRepo?: boolean;
}

// Source-control surface, mirroring the original Codex DIFF-tab git view
// (output/webview/thread-side-panel-tabs/part-02.js + part-03.js): the "Changes"
// list with empty states ("No file changes yet", "Create a Git repository"),
// and the Commit / Commit & push / Commit, push & create PR / Revert actions.
// This replaces the earlier invented Branches list + Recent-commits log.
export function GitTab({ files, branch, hasRepo = true }: Props) {
  const [commitMsg, setCommitMsg] = React.useState("");
  const [revertOpen, setRevertOpen] = React.useState(false);

  const added = files.reduce((s, f) => s + f.added, 0);
  const removed = files.reduce((s, f) => s + f.removed, 0);

  const commit = (mode: "commit" | "commit-push" | "commit-push-pr") => {
    const label =
      mode === "commit"
        ? "Committed changes"
        : mode === "commit-push"
          ? "Committed & pushed"
          : "Committed, pushed & created PR";
    toast(label);
    setCommitMsg("");
  };

  if (!hasRepo) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center px-6 text-center">
        <div className="text-[13px] font-medium text-foreground">Create a Git repository</div>
        <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
          Track, review, and undo changes in this project.
        </div>
      </div>
    );
  }

  return (
    <div className="flex h-full w-full flex-col">
      <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] px-3 py-2 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
        <GitBranch className="size-3.5" />
        <code className="font-mono text-[12px] text-[color:var(--color-text-secondary)]">{branch}</code>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        <div className="px-3 pb-1 pt-3 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
          Changes
        </div>
        {files.length === 0 ? (
          <div className="px-3 py-8 text-center">
            <div className="text-[13px] font-medium text-foreground">No file changes yet</div>
            <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
              Changes in this project will appear here.
            </div>
          </div>
        ) : (
          <ul className="space-y-px px-2">
            {files.map((f) => (
              <li
                key={f.path}
                className="flex h-7 items-center gap-2 rounded-md px-2 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
              >
                <span className="flex-1 truncate font-mono">{f.path}</span>
                <span className="shrink-0 font-mono text-[10.5px]">
                  <span className="text-[color:var(--color-green-500)]">+{f.added}</span>{" "}
                  <span className="text-[color:var(--color-red-500)]">-{f.removed}</span>
                </span>
              </li>
            ))}
          </ul>
        )}
      </div>

      {files.length > 0 && (
        <div className="space-y-2 border-t border-[color:var(--color-divider)] p-3">
          <Input
            value={commitMsg}
            onChange={(e) => setCommitMsg(e.target.value)}
            placeholder="Commit message"
            className="h-8"
          />
          <div className="text-[11px] text-[color:var(--color-text-tertiary)]">
            {files.length} file{files.length === 1 ? "" : "s"},{" "}
            <span className="font-mono text-[color:var(--color-green-500)]">+{added}</span>{" "}
            <span className="font-mono text-[color:var(--color-red-500)]">-{removed}</span>
          </div>
          <div className="flex items-center gap-1.5">
            <Button size="sm" className="flex-1" onClick={() => commit("commit")}>
              <GitCommit className="!size-3.5" /> Commit
            </Button>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button size="iconSm" variant="outline" aria-label="More commit options">
                  <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onClick={() => commit("commit-push")}>
                  <GitPullRequest className="size-3.5" /> Commit &amp; push
                </DropdownMenuItem>
                <DropdownMenuItem onClick={() => commit("commit-push-pr")}>
                  <GitPullRequest className="size-3.5" /> Commit, push &amp; create PR
                </DropdownMenuItem>
                <DropdownMenuItem
                  className="text-[color:var(--color-red-500)]"
                  onClick={() => setRevertOpen(true)}
                >
                  <Undo2 className="size-3.5" /> Revert
                </DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        </div>
      )}

      <Dialog open={revertOpen} onOpenChange={setRevertOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Revert changes?</DialogTitle>
            <DialogDescription>
              This action removes all of these changes.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" size="sm" onClick={() => setRevertOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              size="sm"
              onClick={() => {
                setRevertOpen(false);
                toast("Reverted changes");
              }}
            >
              Revert
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </div>
  );
}
