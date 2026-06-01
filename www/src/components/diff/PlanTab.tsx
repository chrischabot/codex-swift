import * as React from "react";
import { useParams } from "react-router-dom";
import { ChevronDown, Download, Copy, ArrowUpRight } from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { toast } from "@/components/ui/sonner";
import { Markdown } from "@/components/chat/Markdown";
import { useAppData } from "@/state/store";

// Markdown-rendered plan summary card, mirroring
// output/webview/plan-summary-item-content.js: a header titled "Plan"
// (or "Writing plan" with shimmer while streaming) with Download plan / Copy /
// Open-in-new-window actions, and a collapse/expand body with a bottom fade
// gradient + "Expand plan" button when collapsed.
//
// Data source: the latest `plan` block in the active thread's messages (built
// by the connector from `turn/plan/updated`). No more hardcoded sample plan.

const PLAN_FILENAME = "PLAN.md";
// Original collapsed height is ge=320px (plan-summary-item-content.js).
const COLLAPSED_HEIGHT = 320;

export function PlanTab() {
  const { threadId } = useParams();
  const { messages } = useAppData();

  // Find the most recent plan block in this thread and render its checklist.
  const { markdown, completed } = React.useMemo(() => {
    let steps: { content: string; status: string }[] | null = null;
    for (const m of messages) {
      if (m.threadId !== threadId) continue;
      for (const b of m.blocks) if (b.type === "plan") steps = b.steps;
    }
    if (!steps || steps.length === 0) return { markdown: "", completed: true };
    const md = steps
      .map((s) => {
        const box = s.status === "completed" ? "x" : " ";
        const tag = s.status === "in_progress" ? "  _(in progress)_" : "";
        return `- [${box}] ${s.content}${tag}`;
      })
      .join("\n");
    return { markdown: md, completed: !steps.some((s) => s.status === "in_progress") };
  }, [messages, threadId]);

  const [collapsed, setCollapsed] = React.useState(true);
  const bodyRef = React.useRef<HTMLDivElement>(null);
  const [overflows, setOverflows] = React.useState(false);

  React.useLayoutEffect(() => {
    const el = bodyRef.current;
    if (!el) return;
    setOverflows(el.scrollHeight > COLLAPSED_HEIGHT + 4);
  }, [markdown]);

  const onCopy = () => {
    void navigator.clipboard?.writeText(markdown);
    toast("Copied plan");
  };

  const onDownload = () => {
    const blob = new Blob([markdown], { type: "text/markdown" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = PLAN_FILENAME;
    a.click();
    URL.revokeObjectURL(url);
  };

  const showCollapse = completed && overflows;

  if (!markdown) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center px-8 text-center">
        <div className="text-[13px] font-medium text-foreground">No plan yet</div>
        <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
          When the agent drafts a plan for this thread, it will appear here.
        </div>
      </div>
    );
  }

  return (
    <div className="min-h-0 flex-1 overflow-y-auto p-3">
      <div className="overflow-hidden rounded-xl border border-[color:var(--border)] bg-[color:var(--card)]">
        {/* Header */}
        <div className="relative flex flex-wrap items-center justify-between gap-2 px-3 py-2">
          <span
            className={cn(
              "text-base font-semibold leading-tight text-foreground",
              !completed && "codex-shimmer",
            )}
          >
            {completed ? "Plan" : "Writing plan"}
          </span>
          {completed && (
            <div className="flex items-center gap-1">
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label="Download plan"
                    onClick={onDownload}
                  >
                    <Download className="!size-3.5" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>Download plan</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button
                    variant="ghost"
                    size="icon"
                    aria-label="Copy plan"
                    onClick={onCopy}
                  >
                    <Copy className="!size-3.5" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>Copy</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <Button variant="outline" size="xs" className="gap-1">
                    Open
                    <ArrowUpRight className="!size-3.5" />
                  </Button>
                </TooltipTrigger>
                <TooltipContent>Open in new window</TooltipContent>
              </Tooltip>
              {showCollapse && (
                <Tooltip>
                  <TooltipTrigger asChild>
                    <Button
                      variant="ghost"
                      size="icon"
                      aria-label={collapsed ? "Expand" : "Collapse"}
                      onClick={() => setCollapsed((v) => !v)}
                    >
                      <ChevronDown
                        className={cn(
                          "!size-3.5 transition-transform",
                          collapsed ? "rotate-0" : "rotate-180",
                        )}
                      />
                    </Button>
                  </TooltipTrigger>
                  <TooltipContent>
                    {collapsed ? "Expand" : "Collapse"}
                  </TooltipContent>
                </Tooltip>
              )}
            </div>
          )}
        </div>

        {/* Body */}
        <div
          className="relative overflow-hidden transition-[height]"
          style={{
            height: showCollapse && collapsed ? COLLAPSED_HEIGHT : "auto",
          }}
        >
          <div ref={bodyRef} className="px-3 pb-3">
            <Markdown content={markdown} streaming={!completed} />
          </div>
          {showCollapse && collapsed && (
            <>
              <div className="pointer-events-none absolute inset-x-0 bottom-0 h-40 bg-gradient-to-t from-[color:var(--card)] to-transparent" />
              <div className="pointer-events-none absolute inset-x-0 bottom-3 flex justify-center">
                <Button
                  className="pointer-events-auto"
                  size="sm"
                  onClick={() => setCollapsed(false)}
                >
                  Expand plan
                </Button>
              </div>
            </>
          )}
        </div>
      </div>
    </div>
  );
}
