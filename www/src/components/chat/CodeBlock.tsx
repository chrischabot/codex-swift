import * as React from "react";
import { Check, Copy, WrapText } from "lucide-react";
import { highlightToHtml } from "@/lib/shiki";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

interface Props {
  language?: string;
  code: string;
  filename?: string;
  showHeader?: boolean;
  className?: string;
}

// Mirrors the original code-snippet component (code-snippet.js te()/A()/k()/j()):
//   - container: relative w-full min-w-0 overflow-clip rounded-lg border with
//     code-block-background + input-background tokens and a data-theme attribute
//   - header (k): text-sm font-sans description-foreground select-none ps-2 pe-2 py-1
//   - word-wrap toggle (O lines 342-357) to the LEFT of the copy button
//   - copy button (copy-button.js): Tooltip "Copy code"/"Copied", aria-label,
//     check-icon swap, 2000ms reset
//   - body (A): text-size-chat overflow-auto p-2, whitespace-pre / pre-wrap
// This codebase has no code-block-background/input-background/description-foreground
// tokens, so we map to the closest: --color-card / --border / --color-text-tertiary.
export function CodeBlock({ language = "text", code, filename, showHeader = true, className }: Props) {
  const [html, setHtml] = React.useState<string>("");
  const [copied, setCopied] = React.useState(false);
  const [wrap, setWrap] = React.useState(false);
  const isDark =
    typeof document !== "undefined" && document.documentElement.classList.contains("dark");

  React.useEffect(() => {
    let alive = true;
    highlightToHtml(code, language).then((h) => {
      if (alive) setHtml(h);
    });
    return () => {
      alive = false;
    };
  }, [code, language]);

  return (
    <TooltipProvider delayDuration={300}>
      <div
        data-theme={isDark ? "dark" : "light"}
        className={cn(
          "relative my-3 w-full min-w-0 overflow-clip rounded-lg border contain-inline-size",
          "border-[color:var(--border)] bg-[color:var(--color-card)]",
          className,
        )}
      >
        {showHeader && (
          <div className="flex select-none items-center px-2 py-1 text-[length:var(--text-sm)] font-sans text-[color:var(--color-text-tertiary)]">
            <div className="min-w-0 flex-1 truncate">{filename ?? language}</div>
            <div className="ml-auto flex shrink-0 items-center gap-px">
              <Tooltip>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={wrap ? "Disable word wrap" : "Enable word wrap"}
                    aria-pressed={wrap}
                    onClick={() => setWrap((v) => !v)}
                    className={cn(
                      "rounded-md p-1 hover:bg-[color:var(--color-surface-hover)]",
                      wrap && "text-foreground",
                    )}
                  >
                    <WrapText className="size-3.5" />
                  </button>
                </TooltipTrigger>
                <TooltipContent>{wrap ? "Disable word wrap" : "Enable word wrap"}</TooltipContent>
              </Tooltip>
              <Tooltip>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={copied ? "Copied" : "Copy code"}
                    onClick={() => {
                      navigator.clipboard?.writeText(code);
                      setCopied(true);
                      setTimeout(() => setCopied(false), 2000);
                    }}
                    className="rounded-md p-1 hover:bg-[color:var(--color-surface-hover)]"
                  >
                    {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
                  </button>
                </TooltipTrigger>
                <TooltipContent>{copied ? "Copied" : "Copy code"}</TooltipContent>
              </Tooltip>
            </div>
          </div>
        )}
        {html ? (
          <div
            className={cn(
              "shiki-host text-size-chat overflow-auto p-2 text-[12.5px] leading-[1.55]",
              wrap ? "[&_pre]:whitespace-pre-wrap [&_code]:whitespace-pre-wrap" : "[&_pre]:whitespace-pre",
            )}
            dangerouslySetInnerHTML={{ __html: html }}
          />
        ) : (
          <pre
            className={cn(
              "text-size-chat m-0 overflow-auto p-2 font-mono text-[12.5px] leading-[1.55]",
              wrap ? "whitespace-pre-wrap" : "whitespace-pre",
            )}
          >
            <code>{code}</code>
          </pre>
        )}
      </div>
    </TooltipProvider>
  );
}
