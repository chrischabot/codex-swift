import * as React from "react";
import { Copy, Check, ChevronsUpDown, ChevronsDownUp } from "lucide-react";
import { highlightToHtml } from "@/lib/shiki";
import { cn } from "@/lib/utils";

interface Props {
  value: unknown;
}

// Lines past which the payload is collapsed behind an expand toggle (large
// data viewers in Codex truncate big payloads).
const COLLAPSE_THRESHOLD = 40;

// Pretty-printed JSON block with copy. Codex.app uses Prism-coloured keys/
// values; we get the same effect by running the payload through shiki with
// `language: "json"` (same path as CodeResultBlock).
export function JsonBlock({ value }: Props) {
  const text = React.useMemo(() => {
    try {
      return JSON.stringify(value, null, 2);
    } catch {
      return String(value);
    }
  }, [value]);
  const lineCount = React.useMemo(() => text.split("\n").length, [text]);
  const collapsible = lineCount > COLLAPSE_THRESHOLD;
  const [html, setHtml] = React.useState<string>("");
  const [copied, setCopied] = React.useState(false);
  const [expanded, setExpanded] = React.useState(false);
  React.useEffect(() => {
    let alive = true;
    highlightToHtml(text, "json").then((h) => { if (alive) setHtml(h); });
    return () => { alive = false; };
  }, [text]);
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-[color:var(--sidebar)]">
      <div className="flex h-7 items-center justify-between px-3 text-[11px] text-[color:var(--color-text-tertiary)]">
        <span>json</span>
        <div className="flex items-center gap-0.5">
          {collapsible && (
            <button
              type="button"
              onClick={() => setExpanded((v) => !v)}
              className="rounded-md p-1 hover:bg-[color:var(--color-surface-hover)]"
              title={expanded ? "Collapse" : "Expand"}
            >
              {expanded ? <ChevronsDownUp className="size-3" /> : <ChevronsUpDown className="size-3" />}
            </button>
          )}
          <button
            type="button"
            onClick={() => {
              navigator.clipboard?.writeText(text);
              setCopied(true);
              setTimeout(() => setCopied(false), 1200);
            }}
            className="rounded-md p-1 hover:bg-[color:var(--color-surface-hover)]"
          >
            {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
          </button>
        </div>
      </div>
      <div
        className={cn(
          "shiki-host border-t border-[color:var(--border)] overflow-auto",
          collapsible && !expanded && "max-h-[280px]",
        )}
        dangerouslySetInnerHTML={{ __html: html || `<pre><code>${escapeHtml(text)}</code></pre>` }}
      />
    </div>
  );
}

function escapeHtml(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
