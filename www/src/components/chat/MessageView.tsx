import * as React from "react";
import type { Message, MessageBlock } from "@/domain/models";
import { Markdown } from "./Markdown";
import { ShellBlock } from "./ShellBlock";
import { AttachmentList } from "./AttachmentList";
import { DiffSummaryCard } from "./DiffSummaryCard";
import { Mermaid } from "./Mermaid";
import { ThinkingShimmer } from "./ThinkingShimmer";
import { CodexAvatar } from "./CodexAvatar";
import { ToolCallBlock } from "./ToolCallBlock";
import { MessageActions } from "./MessageActions";
import { SuggestedFollowups } from "./SuggestedFollowups";
import { Button } from "@/components/ui/button";
import { dispatch } from "@/state/store";

// Block renderers
import { ThinkingBlock } from "./blocks/ThinkingBlock";
import { SummaryBlock } from "./blocks/SummaryBlock";
import { JsonBlock } from "./blocks/JsonBlock";
import { DiffBlock } from "./blocks/DiffBlock";
import {
  ImageBlock,
  AudioBlock,
  VideoBlock,
  DocumentBlock,
  RefBlock,
  CitationsBlock,
} from "./blocks/MediaBlocks";
import { ApprovalBlock } from "./blocks/ApprovalBlock";
import { QuestionBlock } from "./blocks/QuestionBlock";
import { PlanBlock } from "./blocks/PlanBlock";
import { MissionBlock } from "./blocks/MissionBlock";
import { CompactionBlock } from "./blocks/CompactionBlock";
import { SandboxBlock } from "./blocks/SandboxBlock";
import { SubAgentBlock } from "./blocks/SubAgentBlock";
import { WebFetchBlock } from "./blocks/WebFetchBlock";
import { BrowserActionBlock } from "./blocks/BrowserActionBlock";
import { ErrorBlock } from "./blocks/ErrorBlock";
import { TokenUsageBlock } from "./blocks/TokenUsageBlock";
import { ModelSwitchBlock } from "./blocks/ModelSwitchBlock";
import { CodeResultBlock } from "./blocks/CodeResultBlock";

interface Props {
  message: Message;
  followups?: string[];
}

export function MessageView({ message, followups }: Props) {
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState("");
  const [submitting, setSubmitting] = React.useState(false);

  const beginEdit = () => {
    const text = message.blocks.find((b) => b.type === "markdown")?.content ?? "";
    setDraft(text);
    setEditing(true);
  };

  if (message.role === "user") {
    if (editing) {
      const submit = () => {
        const text = draft.trim();
        if (!text || submitting) return;
        setSubmitting(true);
        dispatch.sendMessage(message.threadId, text);
        setSubmitting(false);
        setEditing(false);
      };
      return (
        <div className="mb-6 flex flex-col items-end gap-1">
          <form
            className="relative flex w-full flex-col rounded-3xl bg-[color:color-mix(in_oklab,var(--foreground)_5%,transparent)]"
            onSubmit={(e) => {
              e.preventDefault();
              submit();
            }}
          >
            <div className="mb-2 flex-grow overflow-y-auto px-3 pt-3">
              <textarea
                autoFocus
                aria-label="Edit message"
                placeholder="Edit message"
                value={draft}
                onChange={(e) => setDraft(e.target.value)}
                className="block w-full resize-none bg-transparent text-[14px] outline-none"
                rows={Math.min(8, draft.split("\n").length + 1)}
              />
            </div>
            <div className="flex justify-end gap-1.5 px-3 pb-3">
              <Button
                type="button"
                variant="outline"
                size="sm"
                disabled={submitting}
                onClick={() => setEditing(false)}
              >
                Cancel
              </Button>
              <Button type="submit" size="sm" disabled={submitting}>
                Send
              </Button>
            </div>
          </form>
        </div>
      );
    }
    return (
      <div className="group mb-6 flex flex-col items-end gap-1">
        <div className="max-w-[77%] overflow-hidden break-words rounded-2xl bg-[color:color-mix(in_oklab,var(--foreground)_5%,transparent)] px-3 py-2 text-[14px]">
          {message.blocks.map((b, i) => {
            if (b.type === "markdown") return <Markdown key={i} content={b.content} />;
            if (b.type === "image") return <ImageBlock key={i} url={b.url} alt={b.alt} />;
            if (b.type === "ref") return <RefBlock key={i} uri={b.uri} title={b.title} refKind={b.refKind} />;
            return null;
          })}
        </div>
        <MessageActions message={message} onEdit={beginEdit} />
      </div>
    );
  }

  const isStreaming = message.preamble === "Working" || message.preamble === "Working…";

  return (
    <div className="group mb-6 w-full">
      {message.preamble && !isStreaming && (
        <div className="mb-2 flex items-center gap-2 text-[12px] text-[color:var(--color-text-tertiary)]">
          <CodexAvatar size={18} />
          {message.preamble}
        </div>
      )}
      {isStreaming && <ThinkingShimmer label="Working" />}
      {message.blocks.map((b, i) => {
        const isLast = i === message.blocks.length - 1;
        const streamingTail = isStreaming && isLast;
        return (
          <BlockAnimateIn key={blockKey(b, i)}>{renderBlock(b, streamingTail)}</BlockAnimateIn>
        );
      })}
      {followups && followups.length > 0 && (
        <SuggestedFollowups items={followups} onPick={(text) => dispatch.sendMessage(message.threadId, text)} />
      )}
    </div>
  );
}

function blockKey(b: MessageBlock, idx: number): string {
  return (b as { blockId?: string }).blockId ?? `${b.type}-${idx}`;
}

// Per-block renderer. Centralising the switch here keeps MessageView lean
// and makes it trivial to add a new block kind — drop a new file under
// `blocks/`, add a domain variant, and a case below.
function renderBlock(b: MessageBlock, streamingTail = false): React.ReactNode {
  switch (b.type) {
    case "markdown":
      return <Markdown content={b.content} streaming={streamingTail || b.status === "streaming"} />;
    case "thinking":
      return <ThinkingBlock content={b.content} status={b.status} />;
    case "summary":
      return <SummaryBlock content={b.content} />;
    case "code":
      return (
        <pre className="my-3 overflow-x-auto rounded-lg border border-[color:var(--border)] bg-[color:var(--sidebar)] p-3 font-mono text-[12.5px]">
          <code>{b.content}</code>
        </pre>
      );
    case "code-result":
      return <CodeResultBlock language={b.language} content={b.content} exitCode={b.exitCode ?? undefined} />;
    case "shell":
      return (
        <ShellBlock
          language={b.cwd}
          command={b.cmd}
          output={b.output}
          status={b.status === "ok" ? "ok" : b.status === "error" ? "fail" : undefined}
        />
      );
    case "mermaid":
      return <Mermaid content={b.content} />;
    case "json":
      return <JsonBlock value={b.value} />;
    case "tool-call":
      return (
        <ToolCallBlock
          tool={b.tool}
          args={b.args}
          result={b.result}
          status={
            b.status === "streaming"
              ? "running"
              : b.status === "ok"
                ? "ok"
                : b.status === "error"
                  ? "error"
                  : undefined
          }
        />
      );
    case "tool-result":
      return <JsonBlock value={b.output} />;
    case "diff":
      return <DiffBlock path={b.path} unifiedDiff={b.unifiedDiff} added={b.added} removed={b.removed} />;
    case "diff-summary":
      return <DiffSummaryCard label={b.label} files={b.files} collapsedExtraFiles={b.collapsedExtraFiles} />;
    case "attachments":
      return <AttachmentList items={b.items} />;
    case "image":
      return <ImageBlock url={b.url} alt={b.alt} />;
    case "audio":
      return <AudioBlock url={b.url} filename={b.filename} />;
    case "video":
      return <VideoBlock url={b.url} filename={b.filename} />;
    case "document":
      return <DocumentBlock url={b.url} filename={b.filename} mime={b.mime} />;
    case "ref":
      return <RefBlock uri={b.uri} title={b.title} refKind={b.refKind} />;
    case "citations":
      return <CitationsBlock items={b.items} />;
    case "approval":
      return <ApprovalBlock {...b} />;
    case "question":
      return <QuestionBlock questionId={b.questionId} title={b.title} prompt={b.prompt} fields={b.fields} />;
    case "plan":
      return <PlanBlock title={b.title} steps={b.steps} />;
    case "mission":
      return <MissionBlock missionId={b.missionId} status={b.status} features={b.features} metrics={b.metrics} />;
    case "compaction":
      return <CompactionBlock summary={b.summary} compactedCount={b.compactedCount} />;
    case "sandbox":
      return <SandboxBlock event={b.event} sandboxId={b.sandboxId} cwd={b.cwd} durationMs={b.durationMs} />;
    case "sub-agent":
      return (
        <SubAgentBlock
          agentId={b.agentId}
          agentName={b.agentName}
          goal={b.goal}
          childThreadId={b.childThreadId}
          status={b.status}
          summary={b.summary}
        />
      );
    case "web-fetch":
      return <WebFetchBlock url={b.url} title={b.title} status={b.status} contentSnippet={b.contentSnippet} />;
    case "browser-action":
      return <BrowserActionBlock action={b.action} target={b.target} screenshotUrl={b.screenshotUrl} />;
    case "error":
      return <ErrorBlock message={b.message} code={b.code} retryable={b.retryable} />;
    case "token-usage":
      return <TokenUsageBlock input={b.input} output={b.output} cacheRead={b.cacheRead} cost={b.cost} />;
    case "model-switch":
      return <ModelSwitchBlock from={b.from} to={b.to} reason={b.reason} />;
    case "section-heading":
      return (
        <div className="my-3 flex items-center gap-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
          <span className="h-px flex-1 bg-[color:var(--color-divider)]" />
          {b.label}
          <span className="h-px flex-1 bg-[color:var(--color-divider)]" />
        </div>
      );
    default:
      return null;
  }
}

function BlockAnimateIn({ children }: { children: React.ReactNode }) {
  // Subtle fade+slide on entry — matches the Codex.app toast-open keyframe.
  return <div className="animate-in fade-in-0 slide-in-from-bottom-1 duration-200">{children}</div>;
}
