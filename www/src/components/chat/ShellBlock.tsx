import { Check, Copy, ChevronDown } from "lucide-react";
import * as React from "react";
import { highlightToHtml } from "@/lib/shiki";
import { cn } from "@/lib/utils";
import { ansiToSpans } from "./ansi";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

// Output longer than this many lines is collapsed behind a "Show all" toggle so
// long terminal dumps don't dominate the conversation. Mirrors the original
// code-snippet collapse affordance.
const COLLAPSE_LINE_THRESHOLD = 16;

interface Props {
  language?: string;
  command: string;
  output?: string;
  // Original exec status surface (conversation-markdown.js Ae()): Success /
  // Running / Stopped / "Failed with exit code N". Existing callers pass
  // "ok" | "fail"; the extra states are optional and additive.
  status?: "ok" | "fail" | "running" | "interrupted";
  exitCode?: number;
}

// Mirrors the original exec/terminal panel (patch-item-content.js lines 700-861
// + conversation-markdown.js S()): a "Ran <cmd>" header with status, the
// command prefixed by `$ `, and the aggregated output rendered as plain text
// (not bash-highlighted) inside a height-constrained, scroll-faded body.
export function ShellBlock({ language = "bash", command, output, status, exitCode }: Props) {
  const [copied, setCopied] = React.useState(false);
  const [cmdHtml, setCmdHtml] = React.useState<string>("");
  const [expanded, setExpanded] = React.useState(false);

  // Parse the raw output into ANSI-colored runs once, memoized on the text.
  const ansiNodes = React.useMemo(() => (output ? ansiToSpans(output) : []), [output]);
  const lineCount = output ? output.split("\n").length : 0;
  const collapsible = lineCount > COLLAPSE_LINE_THRESHOLD;
  const showCollapsed = collapsible && !expanded;

  React.useEffect(() => {
    let alive = true;
    highlightToHtml(command, language).then((h) => {
      if (alive) setCmdHtml(h);
    });
    return () => {
      alive = false;
    };
  }, [command, language]);

  const statusLabel = (() => {
    switch (status) {
      case "interrupted":
        return "Stopped";
      case "running":
        return "Running";
      case "fail":
        return exitCode != null ? `Failed with exit code ${exitCode}` : "Failed";
      case "ok":
        return "Success";
      default:
        return null;
    }
  })();
  const statusTone =
    status === "fail"
      ? "text-[color:var(--color-text-danger)]"
      : status === "ok"
        ? "text-[color:var(--color-text-success)]"
        : "text-[color:var(--color-text-tertiary)]";

  return (
    <TooltipProvider delayDuration={300}>
      <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-[color:var(--color-card)]">
        <div className="flex items-center gap-2 border-b border-[color:var(--border)] bg-[color:var(--color-surface-hover)] px-2.5 py-0.5 text-[length:var(--text-sm)] text-[color:var(--color-text-tertiary)]">
          <span className="min-w-0 flex-1 truncate">
            Ran <span className="font-mono">{command}</span>
          </span>
          <div className="flex shrink-0 items-center gap-2">
            {statusLabel && <span className={cn("text-[11px]", statusTone)}>{statusLabel}</span>}
            <Tooltip>
              <TooltipTrigger asChild>
                <button
                  type="button"
                  aria-label={copied ? "Copied" : "Copy command"}
                  onClick={() => {
                    navigator.clipboard?.writeText(command);
                    setCopied(true);
                    setTimeout(() => setCopied(false), 2000);
                  }}
                  className="rounded-md p-1 hover:bg-[color:var(--color-surface-active)]"
                >
                  {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
                </button>
              </TooltipTrigger>
              <TooltipContent>{copied ? "Copied" : "Copy command"}</TooltipContent>
            </Tooltip>
          </div>
        </div>
        {/* Command line, prefixed with `$ ` like the original. */}
        <div className="flex items-start gap-1.5 px-2.5 py-1 font-mono text-[12.5px] leading-[1.55]">
          <span className="select-none text-[color:var(--color-text-tertiary)]">$</span>
          {cmdHtml ? (
            <div
              className="shiki-host min-w-0 flex-1 overflow-x-auto [&_pre]:!bg-transparent [&_pre]:!p-0"
              dangerouslySetInnerHTML={{ __html: cmdHtml }}
            />
          ) : (
            <span className="min-w-0 flex-1 overflow-x-auto whitespace-pre">{command}</span>
          )}
        </div>
        {output && (
          // Aggregated output. ANSI SGR escape sequences are parsed into colored
          // <span>s (ansiToSpans). When collapsed (long output) we constrain the
          // height with a scroll fade like the original code-snippet
          // codeContainerClassName (max-h-40 vertical-scroll-fade-mask) and
          // offer a "Show all" toggle.
          <div className="border-t border-[color:var(--border)]">
            <pre
              className={cn(
                "m-0 overflow-auto px-2.5 py-1 font-mono text-[12px] leading-[1.5] text-[color:var(--color-text-secondary)] whitespace-pre-wrap",
                showCollapsed && "vertical-scroll-fade-mask max-h-40",
              )}
            >
              {ansiNodes}
            </pre>
            {collapsible && (
              <button
                type="button"
                onClick={() => setExpanded((v) => !v)}
                aria-expanded={expanded}
                className="flex w-full items-center gap-1 border-t border-[color:var(--border)] px-2.5 py-1 text-[11px] text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]"
              >
                <ChevronDown className={cn("size-3 transition-transform", expanded && "rotate-180")} />
                {expanded ? "Show less" : `Show all ${lineCount} lines`}
              </button>
            )}
          </div>
        )}
      </div>
    </TooltipProvider>
  );
}
