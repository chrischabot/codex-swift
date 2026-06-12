import * as React from "react";
import { Check, Copy, Maximize2, Minimize2 } from "lucide-react";
import { cn } from "@/lib/utils";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

// Lazy-load mermaid so the initial bundle stays slim.
// Mirrors the original mermaid-diagram.js: a top-right toolbar with a
// zoom/expand toggle and a "Copy mermaid" button, a token-driven theme that
// adapts to dark mode, and accessibility (role=img + sr-only source).
interface Props {
  content: string;
}

export function Mermaid({ content }: Props) {
  const ref = React.useRef<HTMLDivElement | null>(null);
  const [svg, setSvg] = React.useState<string>("");
  // Render errors are kept SEPARATE from the (trusted) SVG and rendered as a
  // React text node below — never via dangerouslySetInnerHTML. Mermaid error
  // messages can echo the diagram source, so interpolating them into innerHTML
  // would be an XSS vector for malicious ```mermaid blocks in imported content.
  const [error, setError] = React.useState<string | null>(null);
  const [expanded, setExpanded] = React.useState(false);
  const [copied, setCopied] = React.useState(false);

  React.useEffect(() => {
    let cancelled = false;
    (async () => {
      try {
        const mod = await import("mermaid");
        const mermaid = mod.default ?? mod;
        const isDark = document.documentElement.classList.contains("dark");
        mermaid.initialize({
          startOnLoad: false,
          // Adapt to dark mode rather than a fixed "default".
          theme: isDark ? "dark" : "default",
          // Untrusted model output: do not allow arbitrary HTML / click handlers.
          securityLevel: "strict",
        });
        const id = `m-${Math.random().toString(36).slice(2, 9)}`;
        const result = await mermaid.render(id, content);
        if (!cancelled) {
          setSvg(result.svg);
          setError(null);
        }
      } catch (err) {
        if (!cancelled) {
          setSvg("");
          setError(String(err));
        }
      }
    })();
    return () => {
      cancelled = true;
    };
  }, [content]);

  return (
    <TooltipProvider delayDuration={300}>
      <div
        ref={ref}
        role="img"
        aria-label="Mermaid diagram"
        className={cn(
          "relative my-3 rounded-lg border px-4 py-3 [&>svg]:h-auto [&>svg]:text-left",
          "border-[color:var(--border)] bg-[color:var(--color-card)]/10",
          expanded ? "max-h-[var(--markdown-wide-block-max-height,640px)] overflow-auto" : "overflow-x-auto",
        )}
      >
        <div className="absolute right-2 top-2 z-10 flex gap-1">
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-pressed={expanded}
                aria-label={expanded ? "Fit to width" : "Show at rendered size"}
                onClick={() => setExpanded((v) => !v)}
                className="rounded-md p-1 text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]"
              >
                {expanded ? <Minimize2 className="size-3.5" /> : <Maximize2 className="size-3.5" />}
              </button>
            </TooltipTrigger>
            <TooltipContent>{expanded ? "Fit to width" : "Show at rendered size"}</TooltipContent>
          </Tooltip>
          <Tooltip>
            <TooltipTrigger asChild>
              <button
                type="button"
                aria-label={copied ? "Copied" : "Copy mermaid"}
                onClick={() => {
                  navigator.clipboard?.writeText(content);
                  setCopied(true);
                  setTimeout(() => setCopied(false), 2000);
                }}
                className="rounded-md p-1 text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]"
              >
                {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
              </button>
            </TooltipTrigger>
            <TooltipContent>{copied ? "Copied" : "Copy mermaid"}</TooltipContent>
          </Tooltip>
        </div>
        {error !== null ? (
          // React escapes {error} — never inject the error string as HTML.
          <pre className="font-mono text-xs whitespace-pre-wrap">{error}</pre>
        ) : (
          // Trusted: mermaid.render output with securityLevel "strict".
          <div dangerouslySetInnerHTML={{ __html: svg }} />
        )}
        <pre className="sr-only whitespace-pre-wrap">{content}</pre>
      </div>
    </TooltipProvider>
  );
}
