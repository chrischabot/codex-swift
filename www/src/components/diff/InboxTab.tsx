import * as React from "react";
import { useParams } from "react-router-dom";
import { FileText, Terminal, Globe, ShieldAlert, HelpCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import { cn } from "@/lib/utils";
import { dispatch, useAppData } from "@/state/store";
import type { MessageBlock } from "@/domain/models";

// Side-panel Inbox: the REAL pending requests for the active thread, derived
// from the live message stream (approval + question blocks the connector
// produced from server-requests). Decisions go through the same connector
// channel as the inline cards; a local `handled` set hides answered items
// optimistically (the connector doesn't rewrite block state).
type ApprovalBlock = Extract<MessageBlock, { type: "approval" }>;
type QuestionBlockT = Extract<MessageBlock, { type: "question" }>;

export function InboxTab() {
  const { threadId } = useParams();
  const { messages } = useAppData();
  const [handled, setHandled] = React.useState<Set<string>>(() => new Set());

  const { approvals, needsInline } = React.useMemo(() => {
    const approvals: ApprovalBlock[] = [];
    const needsInline: Array<{ id: string; title: string; kind: "question" | "elicitation" }> = [];
    for (const m of messages) {
      if (threadId && m.threadId !== threadId) continue;
      for (const b of m.blocks) {
        if (b.type === "approval" && !b.decided && !handled.has(b.approvalId)) {
          // Elicitation cards need their field form — answer them inline.
          if (b.elicitation) needsInline.push({ id: b.approvalId, title: b.title, kind: "elicitation" });
          else approvals.push(b);
        } else if (b.type === "question" && !handled.has(b.questionId)) {
          needsInline.push({ id: b.questionId, title: b.title, kind: "question" });
        }
      }
    }
    return { approvals, needsInline };
  }, [messages, threadId, handled]);

  const decide = (id: string, decision: "allowed" | "denied", scope?: "once" | "session") => {
    void dispatch.respondToApproval(id, decision, scope);
    setHandled((s) => new Set(s).add(id));
    toast(decision === "allowed" ? "Allowed" : "Denied");
  };

  if (approvals.length + needsInline.length === 0) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center text-center text-[color:var(--color-text-tertiary)]">
        <div className="text-[13px] font-medium text-foreground">No pending requests</div>
        <div className="mt-0.5 text-[12px]">Approval and input requests will appear here.</div>
      </div>
    );
  }

  return (
    <ul className="flex h-full w-full flex-col gap-2 overflow-y-auto p-3">
      {approvals.map((a) => {
        const elevated = a.risk === "destructive" || a.risk === "network";
        return (
          <li
            key={a.approvalId}
            className={cn(
              "rounded-lg border border-[color:var(--border)] p-3",
              elevated && "border-[color:var(--color-red-500)]/40 bg-[color:var(--color-red-500)]/5",
            )}
          >
            <div className="flex items-center gap-2 text-[12.5px]">
              <KindIcon kind={a.kind} />
              <span className="truncate font-medium">{a.title}</span>
            </div>
            {a.detail && <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">{a.detail}</div>}
            {a.command && (
              <pre className="mt-1.5 overflow-x-auto rounded-md bg-[color:var(--sidebar)] p-2 font-mono text-[11.5px] text-[color:var(--color-text-secondary)]">
                {a.command.join(" ")}
              </pre>
            )}
            <div className="mt-2 flex justify-end gap-1.5">
              <Button variant="outline" size="xs" onClick={() => decide(a.approvalId, "denied")}>Deny</Button>
              <Button variant="outline" size="xs" onClick={() => decide(a.approvalId, "allowed", "once")}>Allow once</Button>
              {(a.decisions?.includes("allow_always") ?? true) && (
                <Button size="xs" onClick={() => decide(a.approvalId, "allowed", "session")}>Always</Button>
              )}
            </div>
          </li>
        );
      })}
      {needsInline.map((q) => (
        <li key={q.id} className="rounded-lg border border-[color:var(--border)] p-3">
          <div className="flex items-center gap-2 text-[12.5px]">
            <HelpCircle className="size-3.5 text-[color:var(--color-text-secondary)]" />
            <span className="truncate font-medium">{q.title}</span>
          </div>
          <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
            {q.kind === "elicitation" ? "Fill in the requested fields in the conversation." : "Answer this question in the conversation."}
          </div>
        </li>
      ))}
    </ul>
  );
}

function KindIcon({ kind }: { kind: ApprovalBlock["kind"] }) {
  const cls = "size-3.5 text-[color:var(--color-text-secondary)]";
  if (kind === "network") return <ShieldAlert className={cls} />;
  if (kind === "patch") return <FileText className={cls} />;
  if (kind === "exec") return <Terminal className={cls} />;
  return <Globe className={cls} />;
}
