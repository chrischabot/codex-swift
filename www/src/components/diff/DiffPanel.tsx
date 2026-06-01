import * as React from "react";
import { useParams } from "react-router-dom";
import { dispatch } from "@/state/store";
import type { DiffEnvironment, DiffFile, DiffLine } from "@/domain/models";
import {
  ChevronRight,
  GitBranch,
  GitCommit,
  GitPullRequest,
  FileText,
  Globe,
  ExternalLink,
  RotateCw,
  MoreHorizontal,
  ClipboardList,
  Inbox,
  Wrench,
  Server,
  Clock,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { toast } from "@/components/ui/sonner";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
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
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";
import { FileTree, ResizableRail } from "./FileTree";
import { GitTab } from "./GitTab";
import { PlanTab } from "./PlanTab";
import { InboxTab } from "./InboxTab";
import { ThreadToolsTab } from "./ThreadToolsTab";
import { McpAppTab } from "./McpAppTab";
import { TimelineTab } from "./TimelineTab";

interface Props {
  env: DiffEnvironment;
  files: DiffFile[];
  defaultTab?: TabId;
}

// Canonical side-panel tabs mirror the original tab kinds from
// output/webview/app-shell-tab-controller.js (BROWSER, DIFF, MCP_APP, TIMELINE);
// the original DIFF tab is titled "Review". The reimplementation keeps Plan and
// Inbox reachable as secondary tabs, but Browser + Review (Diff) are primary and
// source-control (Git) now lives INSIDE the Review/Diff tab, matching the source.
// MCP (MCP_APP) and Timeline (TIMELINE) are first-class side-panel tabs, sourced
// internally (useAppData / useRuntime) so this component's public props are
// unchanged.
type TabId = "review" | "browser" | "mcp" | "timeline" | "git" | "plan" | "inbox" | "tools";

// Original persists diff view-mode preferences via settings storage
// (diff-view-mode.js keys). We persist the same keys to localStorage.
const VIEW_MODE_KEY = "editorDiffViewMode";
const HIDE_WS_KEY = "hideDiffWhitespace";
const WRAP_KEY = "wrapCodeDiff.2";
const WORD_DIFF_KEY = "wordDiffsEnabled.2";

function usePersistedBool(key: string, initial: boolean) {
  const [value, setValue] = React.useState<boolean>(() => {
    try {
      const v = localStorage.getItem(key);
      return v == null ? initial : v === "true";
    } catch {
      return initial;
    }
  });
  React.useEffect(() => {
    try {
      localStorage.setItem(key, String(value));
    } catch {
      /* ignore */
    }
  }, [key, value]);
  return [value, setValue] as const;
}

// Original treats diffs above a threshold as "too large to display".
const LARGE_DIFF_LINE_LIMIT = 2000;

export function DiffPanel({ env, files, defaultTab = "review" }: Props) {
  const [tab, setTab] = React.useState<TabId>(defaultTab);
  const [activeFile, setActiveFile] = React.useState<string>(files[0]?.path ?? "");

  const [diffMode, setDiffMode] = React.useState<"unified" | "split">(() => {
    try {
      return (localStorage.getItem(VIEW_MODE_KEY) as "unified" | "split") || "unified";
    } catch {
      return "unified";
    }
  });
  React.useEffect(() => {
    try {
      localStorage.setItem(VIEW_MODE_KEY, diffMode);
    } catch {
      /* ignore */
    }
  }, [diffMode]);

  const [hideWs, setHideWs] = usePersistedBool(HIDE_WS_KEY, false);
  const [wrap, setWrap] = usePersistedBool(WRAP_KEY, false);
  const [wordDiff, setWordDiff] = usePersistedBool(WORD_DIFF_KEY, false);

  return (
    <aside className="flex h-full w-[520px] shrink-0 flex-col border-l border-[color:var(--border)] bg-background">
      {/* Header */}
      <div className="drag-region flex h-11 shrink-0 items-center gap-1 px-3 text-[12px] no-drag">
        <TabBtn active={tab === "review"} onClick={() => setTab("review")}>
          <FileText className="size-4" /> Review
        </TabBtn>
        <TabBtn active={tab === "browser"} onClick={() => setTab("browser")}>
          <Globe className="size-4" /> Browser
        </TabBtn>
        <TabBtn active={tab === "mcp"} onClick={() => setTab("mcp")}>
          <Server className="size-4" /> MCP
        </TabBtn>
        <TabBtn active={tab === "timeline"} onClick={() => setTab("timeline")}>
          <Clock className="size-4" /> Timeline
        </TabBtn>
        <TabBtn active={tab === "plan"} onClick={() => setTab("plan")}>
          <ClipboardList className="size-4" /> Plan
        </TabBtn>
        <TabBtn active={tab === "inbox"} onClick={() => setTab("inbox")}>
          <Inbox className="size-4" /> Inbox
        </TabBtn>
        <TabBtn active={tab === "tools"} onClick={() => setTab("tools")}>
          <Wrench className="size-4" /> Tools
        </TabBtn>
        <div className="flex-1" />
        {tab === "review" && (
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="iconSm" aria-label="Diff view options">
                <MoreHorizontal />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end">
              <DropdownMenuItem onClick={() => setDiffMode("unified")}>
                {diffMode === "unified" ? "✓" : ""} Unified
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setDiffMode("split")}>
                {diffMode === "split" ? "✓" : ""} Split
              </DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onClick={() => setHideWs((v) => !v)}>
                {hideWs ? "✓" : ""} Hide whitespace
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setWrap((v) => !v)}>
                {wrap ? "✓" : ""} Wrap lines
              </DropdownMenuItem>
              <DropdownMenuItem onClick={() => setWordDiff((v) => !v)}>
                {wordDiff ? "✓" : ""} Word diff
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        )}
      </div>

      {/* Body */}
      <div className="flex min-h-0 flex-1">
        {tab === "review" && (
          <ReviewTab
            env={env}
            files={files}
            activeFile={activeFile}
            onActivateFile={setActiveFile}
            mode={diffMode}
            hideWs={hideWs}
            wrap={wrap}
            wordDiff={wordDiff}
          />
        )}
        {tab === "browser" && <BrowserTab />}
        {tab === "mcp" && <McpAppTab />}
        {tab === "timeline" && <TimelineTab />}
        {tab === "git" && (
          <GitTab
            files={files.map((f) => ({ path: f.path, added: f.added, removed: f.removed }))}
            branch={env.branch}
            hasRepo
          />
        )}
        {tab === "plan" && <PlanTab />}
        {tab === "inbox" && <InboxTab />}
        {tab === "tools" && <ThreadToolsTab />}
      </div>
    </aside>
  );
}

function TabBtn({
  active,
  onClick,
  children,
}: {
  active: boolean;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <button
      onClick={onClick}
      className={cn(
        "flex items-center gap-1.5 rounded-md px-2 py-1 text-[13px] font-medium",
        active
          ? "text-foreground"
          : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]",
      )}
    >
      {children}
    </button>
  );
}

function ReviewTab({
  env,
  files,
  activeFile,
  onActivateFile,
  mode,
  hideWs,
  wrap,
  wordDiff,
}: {
  env: DiffEnvironment;
  files: DiffFile[];
  activeFile: string;
  onActivateFile: (path: string) => void;
  mode: "unified" | "split";
  hideWs: boolean;
  wrap: boolean;
  wordDiff: boolean;
}) {
  const [revertOpen, setRevertOpen] = React.useState(false);
  const [commitMsg, setCommitMsg] = React.useState("");
  const { threadId } = useParams();
  const onCommitAction = async (mode: "commit" | "commit-push" | "commit-push-pr" | "revert") => {
    if (mode === "revert") { setRevertOpen(true); return; }
    if (!threadId) return;
    const opts = commitMsg.trim() ? { message: commitMsg.trim() } : undefined;
    if (mode === "commit-push-pr") {
      const c = await dispatch.gitAction(threadId, "commitPush", opts);
      if (!c.ok) { toast(`Git failed: ${c.output.slice(0, 140)}`); return; }
      const pr = await dispatch.gitAction(threadId, "pr", commitMsg.trim() ? { title: commitMsg.trim() } : undefined);
      toast(pr.ok ? "Committed, pushed & PR created" : `PR failed: ${pr.output.slice(0, 140)}`);
      return;
    }
    const r = await dispatch.gitAction(threadId, mode === "commit" ? "commit" : "commitPush", opts);
    if (r.ok) setCommitMsg("");
    toast(r.ok ? (mode === "commit" ? "Committed changes" : "Committed & pushed") : `Git failed: ${r.output.slice(0, 140)}`);
  };
  // Empty / no-git-repo states mirroring the original DIFF tab.
  if (!env.local && files.length === 0) {
    return (
      <ReviewEmptyState
        title="Create a Git repository"
        description="Track, review, and undo changes in this project."
      />
    );
  }
  if (files.length === 0) {
    return (
      <ReviewEmptyState
        title="No file changes yet"
        description="Changes in this project will appear here."
      />
    );
  }

  return (
    <>
      {/* Left rail: source-control + changed files (resizable, width persisted) */}
      <ResizableRail className="overflow-y-auto border-r border-[color:var(--color-divider)] px-2 py-3 text-[12px]">
        <RailHeader>Changes</RailHeader>
        <div className="px-2 pb-1 font-mono text-[11.5px]">
          <span className="text-[color:var(--color-green-500)]">
            +{env.changes.added.toLocaleString()}
          </span>{" "}
          <span className="text-[color:var(--color-red-500)]">
            -{env.changes.removed.toLocaleString()}
          </span>
        </div>
        <RailItem icon={<GitBranch className="size-3.5" />} label={env.branch} />

        <RailHeader>Files</RailHeader>
        <FileTree
          files={files.map((f) => ({ path: f.path, added: f.added, removed: f.removed }))}
          activePath={activeFile}
          onSelect={onActivateFile}
        />

        {/* Source-control actions live inside the Diff tab (original model):
            Commit / Commit & push / Commit, push & create PR / Revert. */}
        <RailHeader>Source control</RailHeader>
        <div className="px-1 pb-1.5">
          <Input
            value={commitMsg}
            onChange={(e) => setCommitMsg(e.target.value)}
            placeholder="Commit message (optional)"
            className="h-7 text-[12px]"
          />
        </div>
        <div className="space-y-1 px-1">
          <Button
            size="sm"
            className="w-full justify-start gap-1.5"
            onClick={() => onCommitAction("commit")}
          >
            <GitCommit className="!size-3.5" /> Commit
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="w-full justify-start gap-1.5"
            onClick={() => onCommitAction("commit-push")}
          >
            <GitPullRequest className="!size-3.5" /> Commit &amp; push
          </Button>
          <Button
            variant="outline"
            size="sm"
            className="w-full justify-start gap-1.5"
            onClick={() => onCommitAction("commit-push-pr")}
          >
            <GitPullRequest className="!size-3.5" /> Commit, push &amp; create PR
          </Button>
          <Button
            variant="ghost"
            size="sm"
            className="w-full justify-start gap-1.5 text-[color:var(--color-red-500)]"
            onClick={() => onCommitAction("revert")}
          >
            <RotateCw className="!size-3.5" /> Revert
          </Button>
        </div>

        {env.sources.length > 0 && (
          <>
            <RailHeader>Sources</RailHeader>
            {env.sources.map((s) => (
              <RailItem key={s.id} icon={<Globe className="size-3.5" />} label={s.label} />
            ))}
          </>
        )}
      </ResizableRail>

      {/* Diff viewer */}
      <div className="min-w-0 flex-1 overflow-auto">
        {files.map((f) => (
          <DiffFileView key={f.path} file={f} mode={mode} hideWs={hideWs} wrap={wrap} wordDiff={wordDiff} />
        ))}
      </div>

      {/* Revert confirmation, matching the original copy. */}
      <Dialog open={revertOpen} onOpenChange={setRevertOpen}>
        <DialogContent>
          <DialogHeader>
            <DialogTitle>Revert changes?</DialogTitle>
            <DialogDescription>This action removes all of these changes.</DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="outline" size="sm" onClick={() => setRevertOpen(false)}>
              Cancel
            </Button>
            <Button
              variant="destructive"
              size="sm"
              onClick={async () => {
                setRevertOpen(false);
                if (!threadId) return;
                const r = await dispatch.gitAction(threadId, "revert");
                toast(r.ok ? "Reverted changes" : `Revert failed: ${r.output.slice(0, 140)}`);
              }}
            >
              Revert
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}

function ReviewEmptyState({ title, description }: { title: string; description: string }) {
  return (
    <div className="flex flex-1 flex-col items-center justify-center px-8 text-center">
      <div className="text-[13px] font-medium text-foreground">{title}</div>
      <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">{description}</div>
    </div>
  );
}

function BrowserTab() {
  // Webview-style frame with an address bar and external-open control, mirroring
  // the original embedded browser tab (thread-side-panel-tabs/part-02.js) rather
  // than a web-search results list.
  const [url, setUrl] = React.useState("");
  const [committed, setCommitted] = React.useState("");
  return (
    <div className="flex h-full w-full flex-col">
      <div className="flex items-center gap-1.5 border-b border-[color:var(--color-divider)] p-2">
        <Button variant="ghost" size="iconSm" aria-label="Reload">
          <RotateCw className="!size-3.5" />
        </Button>
        <form
          className="flex-1"
          onSubmit={(e) => {
            e.preventDefault();
            setCommitted(url);
          }}
        >
          <Input
            value={url}
            onChange={(e) => setUrl(e.target.value)}
            placeholder="Enter URL"
            className="h-7 text-[12px]"
          />
        </form>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="iconSm"
              aria-label="Open in external browser"
              onClick={() => committed && window.open(committed, "_blank", "noreferrer")}
            >
              <ExternalLink className="!size-3.5" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>Open in external browser</TooltipContent>
        </Tooltip>
      </div>
      <div className="flex min-h-0 flex-1 items-center justify-center p-6 text-center">
        {committed ? (
          <iframe
            title="Browser preview"
            src={committed}
            className="h-full w-full rounded-md border border-[color:var(--border)]"
          />
        ) : (
          <div className="text-[12.5px] text-[color:var(--color-text-tertiary)]">
            Try another browser URL
          </div>
        )}
      </div>
    </div>
  );
}

function RailHeader({ children }: { children: React.ReactNode }) {
  return (
    <div className="px-2 pb-1 pt-3 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
      {children}
    </div>
  );
}

function RailItem({
  icon,
  label,
  trailing,
  onClick,
}: {
  icon?: React.ReactNode;
  label: string;
  trailing?: React.ReactNode;
  onClick?: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex h-7 w-full items-center gap-2 rounded-md px-2 text-[12px] text-foreground hover:bg-[color:var(--color-surface-hover)]"
    >
      {icon && <span className="text-[color:var(--color-text-secondary)]">{icon}</span>}
      <span className="flex-1 truncate text-left">{label}</span>
      {trailing && <span className="shrink-0">{trailing}</span>}
    </button>
  );
}

function DiffFileView({
  file,
  mode,
  hideWs,
  wrap,
  wordDiff,
}: {
  file: DiffFile;
  mode: "unified" | "split";
  hideWs: boolean;
  wrap: boolean;
  wordDiff: boolean;
}) {
  const [open, setOpen] = React.useState(true);

  const lines = hideWs ? collapseWhitespace(file.lines) : file.lines;
  const tooLarge = file.lines.length > LARGE_DIFF_LINE_LIMIT;

  return (
    <div data-additions={file.added} data-deletions={file.removed}>
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        className="sticky top-0 z-10 flex h-9 w-full items-center gap-2 border-b border-[color:var(--color-divider)] bg-background px-3 text-left text-[12.5px]"
      >
        <ChevronRight className={cn("size-3.5 transition-transform", open && "rotate-90")} />
        <span
          className={cn(
            "size-1.5 shrink-0 rounded-full",
            file.added > 0 && file.removed > 0
              ? "bg-[color:var(--color-orange-400)]"
              : file.added > 0
                ? "bg-[color:var(--color-green-500)]"
                : "bg-[color:var(--color-red-500)]",
          )}
        />
        <span className="font-mono">{file.path}</span>
        {file.kind && file.kind !== "modified" && <FileKindBadge kind={file.kind} />}
        <span className="ml-auto font-mono text-[11.5px]">
          <span className="text-[color:var(--color-green-500)]">+{file.added}</span>{" "}
          <span className="text-[color:var(--color-red-500)]">-{file.removed}</span>
        </span>
      </button>
      {open &&
        (tooLarge ? (
          <div className="px-4 py-6 text-[12.5px] text-[color:var(--color-text-secondary)]">
            <div className="font-medium text-foreground">Diff too large to display</div>
            <div className="mt-0.5">Open the file to review changes directly.</div>
          </div>
        ) : mode === "unified" ? (
          <UnifiedDiff lines={lines} wrap={wrap} wordDiff={wordDiff} />
        ) : (
          <SplitDiff lines={lines} wrap={wrap} />
        ))}
    </div>
  );
}

// Small pill describing a file-level change kind (new / deleted / renamed /
// binary) — matches the badges in the original review surface.
function FileKindBadge({ kind }: { kind: NonNullable<DiffFile["kind"]> }) {
  const map = {
    added: { label: "new", cls: "text-[color:var(--color-green-500)] border-[color:var(--color-green-500)]/40" },
    deleted: { label: "deleted", cls: "text-[color:var(--color-red-500)] border-[color:var(--color-red-500)]/40" },
    renamed: { label: "renamed", cls: "text-[color:var(--color-text-secondary)] border-[color:var(--border)]" },
    binary: { label: "binary", cls: "text-[color:var(--color-text-secondary)] border-[color:var(--border)]" },
    modified: { label: "", cls: "" },
  } as const;
  const m = map[kind];
  if (!m.label) return null;
  return <span className={cn("rounded border px-1 py-px text-[10px] font-medium uppercase tracking-wide", m.cls)}>{m.label}</span>;
}

// Styled +/- sign column gutter, replacing the literal "+ " / "- " text prefix.
function SignCell({ kind }: { kind: DiffLine["kind"] }) {
  const sign = kind === "added" ? "+" : kind === "removed" ? "-" : "";
  return (
    <td
      className={cn(
        "w-5 select-none text-center font-mono text-[12px]",
        kind === "added" && "text-[color:var(--color-green-500)]",
        kind === "removed" && "text-[color:var(--color-red-500)]",
      )}
    >
      {sign}
    </td>
  );
}

// Common-prefix/suffix intra-line diff: returns [prefix, changed, suffix] for
// each side. The middle segment is what actually changed and gets highlighted.
function intraLineSegments(oldText: string, newText: string): {
  old: [string, string, string]; new: [string, string, string];
} {
  let start = 0;
  const min = Math.min(oldText.length, newText.length);
  while (start < min && oldText[start] === newText[start]) start++;
  let eo = oldText.length, en = newText.length;
  while (eo > start && en > start && oldText[eo - 1] === newText[en - 1]) { eo--; en--; }
  return {
    old: [oldText.slice(0, start), oldText.slice(start, eo), oldText.slice(eo)],
    new: [newText.slice(0, start), newText.slice(start, en), newText.slice(en)],
  };
}

function HighlightedText({ seg, kind }: { seg: [string, string, string]; kind: "added" | "removed" }) {
  const mark = kind === "added"
    ? "bg-[color:var(--color-green-500)]/30"
    : "bg-[color:var(--color-red-500)]/30";
  return (
    <>
      {seg[0]}
      {seg[1] && <span className={cn("rounded-sm", mark)}>{seg[1]}</span>}
      {seg[2]}
    </>
  );
}

function UnifiedDiff({ lines, wrap, wordDiff }: { lines: DiffLine[]; wrap: boolean; wordDiff: boolean }) {
  // Pre-compute intra-line highlight segments for adjacent removed→added pairs.
  const segs = new Map<number, [string, string, string]>();
  if (wordDiff) {
    for (let i = 0; i < lines.length - 1; i++) {
      if (lines[i].kind === "removed" && lines[i + 1].kind === "added") {
        const s = intraLineSegments(lines[i].text, lines[i + 1].text);
        segs.set(i, s.old);
        segs.set(i + 1, s.new);
      }
    }
  }
  return (
    <table className="w-full border-collapse font-mono text-[12px] leading-[1.55]">
      <tbody>
        {lines.map((l, idx) => {
          if (l.kind === "gap") {
            // Hunk header / separator row (@@ context range).
            return (
              <tr key={idx} className="border-y border-[color:var(--color-divider)] bg-[color:var(--sidebar)]">
                <td colSpan={4} className="px-3 py-1 text-[11.5px] text-[color:var(--color-text-tertiary)]">
                  {l.text || "@@"}
                </td>
              </tr>
            );
          }
          if (l.kind === "header") {
            return (
              <tr key={idx} className="bg-[color:var(--sidebar)]">
                <td colSpan={4} className="px-3 py-0.5 text-[11.5px] text-[color:var(--color-text-tertiary)]">
                  {l.text}
                </td>
              </tr>
            );
          }
          const isAdd = l.kind === "added";
          const isRem = l.kind === "removed";
          return (
            <tr
              key={idx}
              className={cn(
                isAdd && "bg-[color:var(--color-diff-added-bg)]",
                isRem && "bg-[color:var(--color-diff-deleted-bg)]",
              )}
            >
              <td className="w-10 select-none border-r border-[color:var(--color-divider)] px-2 text-right text-[color:var(--color-text-quaternary)]">
                {l.oldLine ?? ""}
              </td>
              <td className="w-10 select-none border-r border-[color:var(--color-divider)] px-2 text-right text-[color:var(--color-text-quaternary)]">
                {l.newLine ?? ""}
              </td>
              <SignCell kind={l.kind} />
              <td className={cn("px-2 py-px text-foreground", wrap ? "whitespace-pre-wrap break-all" : "whitespace-pre")}>
                {segs.has(idx) && (isAdd || isRem)
                  ? <HighlightedText seg={segs.get(idx)!} kind={isAdd ? "added" : "removed"} />
                  : l.text}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function SplitDiff({ lines, wrap }: { lines: DiffLine[]; wrap: boolean }) {
  // Build paired rows. Adjacent removed/added pairs become side-by-side rows;
  // standalone removed/added lines render with an empty opposite cell.
  const rows: Array<{ left?: DiffLine; right?: DiffLine; gap?: string }> = [];
  for (let i = 0; i < lines.length; i++) {
    const l = lines[i];
    if (l.kind === "gap") {
      rows.push({ gap: l.text || "@@" });
      continue;
    }
    if (l.kind === "header") {
      rows.push({ gap: l.text });
      continue;
    }
    if (l.kind === "context") {
      rows.push({ left: l, right: l });
      continue;
    }
    if (l.kind === "removed") {
      const next = lines[i + 1];
      if (next?.kind === "added") {
        rows.push({ left: l, right: next });
        i++;
        continue;
      }
      rows.push({ left: l });
      continue;
    }
    if (l.kind === "added") {
      rows.push({ right: l });
      continue;
    }
  }
  const cellWrap = wrap ? "whitespace-pre-wrap break-all" : "whitespace-pre";
  return (
    <table className="w-full table-fixed border-collapse font-mono text-[12px] leading-[1.55]">
      <colgroup>
        <col style={{ width: 32 }} />
        <col />
        <col style={{ width: 32 }} />
        <col />
      </colgroup>
      <tbody>
        {rows.map((r, idx) => {
          if (r.gap != null) {
            return (
              <tr key={idx} className="border-y border-[color:var(--color-divider)] bg-[color:var(--sidebar)]">
                <td colSpan={4} className="px-3 py-1 text-[11.5px] text-[color:var(--color-text-tertiary)]">
                  {r.gap}
                </td>
              </tr>
            );
          }
          return (
            <tr key={idx}>
              <td
                className={cn(
                  "select-none border-r border-[color:var(--color-divider)] px-2 text-right text-[color:var(--color-text-quaternary)]",
                  r.left?.kind === "removed" && "bg-[color:var(--color-diff-deleted-bg)]",
                )}
              >
                {r.left?.oldLine ?? ""}
              </td>
              <td className={cn("px-3 py-px", cellWrap, r.left?.kind === "removed" && "bg-[color:var(--color-diff-deleted-bg)]")}>
                {r.left ? r.left.text : ""}
              </td>
              <td
                className={cn(
                  "select-none border-l border-r border-[color:var(--color-divider)] px-2 text-right text-[color:var(--color-text-quaternary)]",
                  r.right?.kind === "added" && "bg-[color:var(--color-diff-added-bg)]",
                )}
              >
                {r.right?.newLine ?? ""}
              </td>
              <td className={cn("px-3 py-px", cellWrap, r.right?.kind === "added" && "bg-[color:var(--color-diff-added-bg)]")}>
                {r.right ? r.right.text : ""}
              </td>
            </tr>
          );
        })}
      </tbody>
    </table>
  );
}

function collapseWhitespace(lines: DiffLine[]): DiffLine[] {
  // Drop changed lines whose only difference is leading/trailing whitespace.
  return lines.filter((l) => {
    if (l.kind !== "added" && l.kind !== "removed") return true;
    return l.text.trim().length > 0;
  });
}
