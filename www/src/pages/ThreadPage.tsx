import * as React from "react";
import { useParams } from "react-router-dom";
import { useAppData, dispatch } from "@/state/store";
import { MessageList } from "@/components/chat/MessageList";
import { ThreadComposer } from "@/components/composer/ThreadComposer";
import { DiffPanel } from "@/components/diff/DiffPanel";
import { WorkingDirPill } from "@/components/chat/WorkingDirPill";
import { Plus, PanelRight, Monitor, Cloud, GitBranch } from "lucide-react";
import { Button } from "@/components/ui/button";
import { useSidePanel } from "@/components/shell/SidePanelContext";
import { ThreadHeaderMenu } from "@/components/chat/ThreadHeaderMenu";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { DiffViewModel } from "@/runtime/connector";

export function ThreadPage() {
  const { threadId } = useParams();
  // All hook calls go above the conditional early-return so React sees the
  // same hook order on every render (rules-of-hooks).
  const { threads, messages, projects } = useAppData();
  const sidePanel = useSidePanel();
  const { connector, refreshDiff } = useRuntime();

  // Fetch the diff for the active thread via the connector. The side panel is
  // shown whenever a non-null diff comes back (t-dim-projection AND
  // t-pin-fabric-server both qualify now) — no hardcoded thread-id gate.
  const [diff, setDiff] = React.useState<DiffViewModel | null>(null);
  React.useEffect(() => {
    if (!threadId) {
      setDiff(null);
      return;
    }
    let alive = true;
    // Bind the thread + load prior history into the snapshot on open.
    const unsubscribe = connector.subscribeThread(threadId, () => {});
    refreshDiff(threadId)
      .then((d) => {
        if (alive) setDiff(d);
      })
      .catch(() => {
        if (alive) setDiff(null);
      });
    return () => {
      alive = false;
      void unsubscribe().catch(() => {});
    };
  }, [threadId, refreshDiff, connector]);

  const thread = threads.find((t) => t.id === threadId);
  const threadMessages = messages.filter((m) => m.threadId === threadId);
  const project = thread ? projects.find((p) => p.id === thread.projectId) : undefined;

  if (!thread) {
    return (
      <div className="flex flex-1 items-center justify-center text-[color:var(--color-text-tertiary)]">
        Thread not found
      </div>
    );
  }

  // The side panel hosts MCP / Timeline / Tools / Plan / Inbox in addition to
  // the diff Review tab, so show it whenever the user opens it — not only when
  // a diff exists. When there's no diff we fall back to a synthetic empty env
  // and default to the Timeline tab (Review shows its own empty state).
  const showPanel = sidePanel.open;
  const panelEnv: DiffViewModel["env"] = diff?.env ?? {
    changes: { added: 0, removed: 0 }, local: true, branch: "working tree",
    hasCommit: false, sources: [{ id: "local", label: "Local" }],
  };

  // Environment icon driven by thread.envKind: local→Monitor,
  // remote/cloud→Cloud, worktree→GitBranch (matches the original env-kind chip).
  const EnvIcon =
    thread.envKind === "worktree"
      ? GitBranch
      : thread.envKind === "remote" || thread.envKind === "cloud"
        ? Cloud
        : Monitor;

  // Streaming = the most recent assistant message still has the "Working"
  // preamble. The composer's send arrow flips to a Stop button while true.
  const isStreaming = (() => {
    const last = [...threadMessages].reverse().find((m) => m.role === "assistant");
    return last?.preamble === "Working";
  })();

  const lastAssistantIsTail =
    threadMessages[threadMessages.length - 1]?.role === "assistant";

  return (
    <div className="flex min-h-0 flex-1">
      <div className="flex min-w-0 flex-1 flex-col">
        {/* Thread header — draggable 2-col grid (thread-page-header.js) */}
        <div className="draggable grid h-9 w-full min-w-0 shrink-0 grid-cols-[minmax(0,1fr)_auto] items-center gap-x-4 px-4">
          {/* Start: env icon + title + optional secondary line */}
          <div className="flex min-w-0 items-center gap-2 truncate text-base font-medium">
            <span className="inline-flex shrink-0">
              <EnvIcon className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" />
            </span>
            <div className="max-w-[320px] min-w-0 truncate">{thread.title}</div>
            {project && (
              <div className="flex min-w-0 truncate font-normal leading-[18px] text-[color:var(--color-text-tertiary)]">
                {project.name}
              </div>
            )}
          </div>
          {/* Trailing + start actions, separated by a divider */}
          <div className="flex items-center justify-end gap-1.5">
            <Button variant="ghost" size="iconSm" aria-label="New tab from thread" className="text-[color:var(--color-text-tertiary)]">
              <Plus />
            </Button>
            <div className="flex items-center gap-0.5">
              <div className="mx-2 h-[16px] w-px bg-[color:var(--border)]" />
              <Button variant="ghost" size="iconSm" aria-label="Toggle side panel" className="text-[color:var(--color-text-tertiary)]" onClick={sidePanel.toggle}>
                <PanelRight />
              </Button>
              <ThreadHeaderMenu thread={thread} />
            </div>
          </div>
        </div>

        {/* Messages — virtualized + sticky-to-bottom */}
        <MessageList
          messages={threadMessages}
          followupsForLast={
            !isStreaming && lastAssistantIsTail ? followupsForThread(thread.id) : undefined
          }
        />

        {/* Composer */}
        <div className="px-panel pb-4">
          <div className="mx-auto w-full max-w-[var(--thread-content-max-width)]">
            {project && <WorkingDirPill project={project.name} path={project.workingDirectory + "/"} />}
            <ThreadComposer
              threadId={thread.id}
              approval={thread.approval === "approval-required" ? "Approval required" : thread.approval === "read-only" ? "Read only" : "Full access"}
              modelLabel={thread.modelLabel ?? "5.5"}
              modelTier={thread.modelTier ?? "High"}
              streaming={isStreaming}
              onSubmit={(text, opts) => dispatch.sendMessage(thread.id, text, opts)}
              onStop={() => dispatch.interruptTurn(thread.id)}
            />
          </div>
        </div>
      </div>

      {showPanel && <DiffPanel env={panelEnv} files={diff?.files ?? []} defaultTab={diff ? "review" : "timeline"} />}
    </div>
  );
}

function followupsForThread(threadId: string): string[] {
  if (threadId === "t-dim-projection") {
    return [
      "Add metrics for evicted-items count",
      "What's the worst-case memory if TTL is 1 hour?",
      "Make TTL configurable per-thread",
    ];
  }
  if (threadId === "t-ens-arch") {
    return ["Sketch the auth handshake", "How do we handle disconnects?"];
  }
  return [];
}
