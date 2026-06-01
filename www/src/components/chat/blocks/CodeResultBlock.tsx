import * as React from "react";
import { Check, Copy, AlertTriangle } from "lucide-react";
import { highlightToHtml } from "@/lib/shiki";

interface Props {
  language?: string;
  content: string;
  exitCode?: number | null;
}

// "Result of executed code" — distinct from `code` because the agent ran it.
// Subtle dotted border + exit-code badge.
export function CodeResultBlock({ language = "text", content, exitCode }: Props) {
  const [html, setHtml] = React.useState<string>("");
  const [copied, setCopied] = React.useState(false);
  React.useEffect(() => {
    let alive = true;
    highlightToHtml(content, language).then((h) => { if (alive) setHtml(h); });
    return () => { alive = false };
  }, [content, language]);
  const failed = exitCode != null && exitCode !== 0;
  return (
    <div className={`my-3 overflow-hidden rounded-lg border border-dashed bg-[color:var(--sidebar)] ${
      failed ? "border-[color:var(--color-red-500)]/40" : "border-[color:var(--border)]"
    }`}>
      <div className="flex h-7 items-center justify-between px-3 text-[11px] text-[color:var(--color-text-tertiary)]">
        <span className="flex items-center gap-1.5">
          {failed && <AlertTriangle className="size-3 text-[color:var(--color-red-500)]" />}
          {language} · result {exitCode != null && (
            <span className={failed ? "text-[color:var(--color-red-500)]" : "text-[color:var(--color-green-500)]"}>
              (exit {exitCode})
            </span>
          )}
        </span>
        <button
          type="button"
          onClick={() => {
            navigator.clipboard?.writeText(content);
            setCopied(true);
            setTimeout(() => setCopied(false), 1200);
          }}
          className="rounded-md p-1 hover:bg-[color:var(--color-surface-hover)]"
        >
          {copied ? <Check className="size-3" /> : <Copy className="size-3" />}
        </button>
      </div>
      <div
        className="shiki-host border-t border-[color:var(--border)]"
        dangerouslySetInnerHTML={{ __html: html || `<pre><code>${escape(content)}</code></pre>` }}
      />
    </div>
  );
}

function escape(s: string): string {
  return s.replace(/&/g, "&amp;").replace(/</g, "&lt;").replace(/>/g, "&gt;");
}
