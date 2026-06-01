import ReactMarkdown from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";
import { cn } from "@/lib/utils";
import { CodeBlock } from "./CodeBlock";

interface Props {
  content: string;
  className?: string;
  streaming?: boolean;
}

// Mirrors the original markdown surface (markdown-3.js): the content is wrapped
// in `text-size-chat` and rendered with per-element overrides. There is no
// `prose`-style global stylesheet — every element below carries its own classes.
export function Markdown({ content, className, streaming }: Props) {
  return (
    <div
      className={cn(
        "text-size-chat max-w-none text-[14px] leading-[1.65] text-foreground",
        streaming && "codex-caret",
        className,
      )}
    >
      <ReactMarkdown
        remarkPlugins={[remarkGfm, remarkMath]}
        rehypePlugins={[rehypeKatex]}
        components={{
          a: (props) => (
            <a
              {...props}
              className="text-[color:var(--color-blue-400)] underline-offset-2 hover:underline"
              target="_blank"
              rel="noreferrer"
            />
          ),
          p: ({ children }) => <p className="mb-3 last:mb-0">{children}</p>,
          ul: ({ children, className: cls }) => (
            <ul
              className={cn(
                "mb-3 list-disc pl-5 last:mb-0",
                (cls ?? "").includes("contains-task-list") && "contains-task-list list-none pl-0",
              )}
            >
              {children}
            </ul>
          ),
          ol: ({ children }) => <ol className="mb-3 list-decimal pl-5 last:mb-0">{children}</ol>,
          li: ({ children, className: cls }) => (
            <li
              className={cn(
                "mb-1 marker:text-[color:var(--color-text-quaternary)]",
                (cls ?? "").includes("task-list-item") && "task-list-item flex list-none items-start gap-2",
              )}
            >
              {children}
            </li>
          ),
          // GFM task-list checkboxes render as disabled inputs (original `_n`).
          input: (props) => {
            const { type } = props as { type?: string };
            if (type === "checkbox") {
              return (
                <input
                  type="checkbox"
                  disabled
                  checked={(props as { checked?: boolean }).checked}
                  className="mt-1 size-3.5 shrink-0 accent-[color:var(--color-blue-400)]"
                  readOnly
                />
              );
            }
            return <input {...props} />;
          },
          code: (props) => {
            const { children, className: cls } = props as {
              children?: React.ReactNode;
              className?: string;
            };
            // react-markdown v9 dropped the `inline` prop. Two indicators
            // distinguish fenced blocks from inline `code`:
            //   1. a `language-*` class set by remark-gfm on the <code>
            //   2. a trailing newline in the children (added by the markdown
            //      parser for fenced blocks even when no language is given)
            const text = String(children ?? "");
            const langMatch = /language-(\w+)/.exec(cls ?? "");
            const isFenced = !!langMatch || /\n/.test(text);
            if (!isFenced) {
              // Original Mt(): bg-token-text-code-block-background rounded-sm
              // px-1.5 py-0.5 leading-none. No code-block-background token in
              // this codebase — closest is --color-card.
              return (
                <code className="rounded-sm bg-[color:var(--color-card)] px-1.5 py-0.5 font-mono text-[12.5px] leading-none text-foreground">
                  {children}
                </code>
              );
            }
            const lang = langMatch ? langMatch[1] : "text";
            return <CodeBlock language={lang} code={text.replace(/\n$/, "")} />;
          },
          // <pre> is the parent <code> wraps in; collapse so our CodeBlock div
          // isn't double-wrapped. We render fenced code as a div which the
          // browser doesn't allow inside <pre>.
          pre: ({ children }) => <>{children}</>,
          h1: ({ children }) => <h1 className="mb-3 mt-4 text-[20px] font-semibold">{children}</h1>,
          h2: ({ children }) => <h2 className="mb-2 mt-4 text-[16px] font-semibold">{children}</h2>,
          h3: ({ children }) => <h3 className="mb-2 mt-3 text-[14px] font-semibold">{children}</h3>,
          h4: ({ children }) => <h4 className="mb-2 mt-3 text-[13px] font-semibold">{children}</h4>,
          h5: ({ children }) => (
            <h5 className="mb-1 mt-2 text-[12.5px] font-semibold text-[color:var(--color-text-secondary)]">
              {children}
            </h5>
          ),
          h6: ({ children }) => (
            <h6 className="mb-1 mt-2 text-[12px] font-semibold uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
              {children}
            </h6>
          ),
          strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
          // Original hr: my-4 border-t border-token-border.
          hr: () => <hr className="my-4 border-t border-[color:var(--border)]" />,
          img: (props) => (
            // eslint-disable-next-line @next/next/no-img-element
            <img
              {...props}
              alt={(props as { alt?: string }).alt ?? ""}
              className="my-3 max-w-full rounded-md border border-[color:var(--border)]"
            />
          ),
          // Original tables: my-4 overflow-x-auto overflow-y-hidden.
          table: ({ children }) => (
            <div className="my-4 overflow-x-auto overflow-y-hidden">
              <table className="w-full border-collapse text-[13px]">{children}</table>
            </div>
          ),
          thead: ({ children }) => <thead>{children}</thead>,
          tbody: ({ children }) => <tbody>{children}</tbody>,
          tr: ({ children }) => (
            <tr className="border-b border-[color:var(--border)] last:border-b-0">{children}</tr>
          ),
          th: ({ children }) => (
            <th className="px-3 py-1.5 text-left font-semibold text-foreground">{children}</th>
          ),
          td: ({ children }) => (
            <td className="px-3 py-1.5 text-[color:var(--color-text-secondary)]">{children}</td>
          ),
          blockquote: ({ children }) => (
            <blockquote className="border-l-2 border-[color:var(--color-divider)] pl-3 text-[color:var(--color-text-secondary)]">
              {children}
            </blockquote>
          ),
        }}
      >
        {content}
      </ReactMarkdown>
    </div>
  );
}
