import type { ComponentProps, ReactNode } from "react";
import ReactMarkdown, { type Components, defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";
import { cn } from "@/lib/utils";
import { CodeBlock } from "@/components/chat/CodeBlock";
import { Callout } from "./markdown/Callout";
import { WikiEmbed } from "./markdown/WikiEmbed";
import {
  type CalloutType,
  rehypeHeadingIds,
  remarkCallouts,
  remarkHighlight,
  remarkWikilinks,
  stripComments,
} from "./markdown/wikiRemarkPlugins";
// The wiki stylesheet (callouts / highlight / embed / footnotes polish). Imported
// here — the renderer that emits the .wiki-* classes — so it always loads with
// the reading surface and switches with the app's .dark theme.
import "@/styles/wiki.css";

interface Props {
  content: string;
  /** Invoked when an internal wikilink `[[Target]]` or embed is clicked. The
   *  argument is the full target (including any `#heading` / `#^block`
   *  suffix). */
  onWikiLink?: (target: string) => void;
}

/**
 * Reusable wiki markdown renderer. Reuses www's react-markdown pipeline
 * (remark-gfm + remark-math + rehype-katex; fenced code → shiki CodeBlock) and
 * layers the Obsidian-flavored extensions via small remark plugins +
 * component overrides:
 *   - wikilinks `[[Page]]` / `[[Page|alias]]`  → styled internal anchor
 *   - embeds `![[Page]]`                        → bordered embed placeholder
 *   - callouts `> [!type] Title`                → colored Callout box + icon
 *   - `==highlight==`                           → <mark>
 *   - footnotes `[^1]` (+ defs)                 → via remark-gfm; styled here
 */
export function WikiMarkdown({ content, onWikiLink }: Props) {
  const src = stripComments(content);

  // The "wiki-embed" key is a custom element name not in JSX.IntrinsicElements,
  // so the object is typed loosely then cast to Components. react-markdown
  // forwards custom tag names to the matching override at runtime.
  const components = {
    // Anchor override: route `wiki:` sentinels through onWikiLink; everything
    // else (http(s), mailto, #fragment) renders as a normal styled anchor.
    a: (props) => {
      const { href, children, node: _node, ...rest } = props as ComponentProps<"a"> & {
        node?: unknown;
      };
      if (typeof href === "string" && href.startsWith("wiki:")) {
        const target = href.slice("wiki:".length);
        return (
          <a
            {...rest}
            href={`/wiki?q=${encodeURIComponent(target)}`}
            className="wiki-link cursor-pointer rounded-sm text-[color:var(--text-link)] underline decoration-dotted underline-offset-2 hover:decoration-solid"
            onClick={(e) => {
              if (onWikiLink) {
                e.preventDefault();
                onWikiLink(target);
              }
            }}
          >
            {children}
          </a>
        );
      }
      // In-document fragment links (#heading, GFM footnote refs/backrefs) must
      // stay same-document — never open a new tab.
      const isHash = typeof href === "string" && href.startsWith("#");
      return (
        <a
          {...rest}
          href={href}
          className="text-[color:var(--color-blue-400)] underline-offset-2 hover:underline"
          target={isHash ? undefined : "_blank"}
          rel={isHash ? undefined : "noreferrer"}
        >
          {children}
        </a>
      );
    },

    // ![[Page]] embed placeholder (emitted by remarkWikilinks as <wiki-embed>).
    // rehype lowercases custom element tag names + attribute names; register
    // under the lowercased tag and read lowercased props.
    "wiki-embed": (props: Record<string, unknown>) => {
      const full = props.fulltarget ?? props.fullTarget;
      return (
        <WikiEmbed
          target={String(props.target ?? "")}
          fullTarget={full != null ? String(full) : undefined}
          display={props.display != null ? String(props.display) : undefined}
          onOpen={onWikiLink}
        />
      );
    },

    // ==highlight== (emitted by remarkHighlight as <mark>).
    mark: ({ children }: { children?: ReactNode }) => (
      <mark className="rounded-sm bg-[color:color-mix(in_srgb,var(--color-yellow-400)_35%,transparent)] px-0.5 text-foreground">
        {children}
      </mark>
    ),

    // Callouts: remarkCallouts tags qualifying blockquotes with a
    // `data-callout` attribute (and strips the marker from the body). A bare
    // blockquote renders with the default quote styling.
    blockquote: (props) => {
      const { children, node: _node, ...rest } = props as ComponentProps<"blockquote"> & {
        node?: unknown;
        "data-callout"?: string;
        "data-callout-title"?: string;
      };
      const calloutType = (rest as Record<string, unknown>)["data-callout"] as
        | string
        | undefined;
      if (calloutType) {
        const title = (rest as Record<string, unknown>)["data-callout-title"] as
          | string
          | undefined;
        return (
          <Callout type={calloutType as CalloutType} title={title ?? null}>
            {children}
          </Callout>
        );
      }
      return (
        <blockquote className="my-3 border-l-2 border-[color:var(--color-divider)] pl-3 text-[color:var(--color-text-secondary)]">
          {children}
        </blockquote>
      );
    },

    // ── Reused element styling (mirrors chat/Markdown.tsx) ────────────────
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
        children?: ReactNode;
        className?: string;
      };
      const text = String(children ?? "");
      const langMatch = /language-(\w+)/.exec(cls ?? "");
      const isFenced = !!langMatch || /\n/.test(text);
      if (!isFenced) {
        return (
          <code className="rounded-sm bg-[color:var(--color-card)] px-1.5 py-0.5 font-mono text-[12.5px] leading-none text-foreground">
            {children}
          </code>
        );
      }
      const lang = langMatch ? langMatch[1] : "text";
      return <CodeBlock language={lang} code={text.replace(/\n$/, "")} />;
    },
    pre: ({ children }) => <>{children}</>,
    h1: ({ children, node: _n, ...rest }) => <h1 {...rest} className="mb-3 mt-4 scroll-mt-4 text-[20px] font-semibold">{children}</h1>,
    h2: ({ children, node: _n, ...rest }) => <h2 {...rest} className="mb-2 mt-4 scroll-mt-4 text-[16px] font-semibold">{children}</h2>,
    h3: ({ children, node: _n, ...rest }) => <h3 {...rest} className="mb-2 mt-3 scroll-mt-4 text-[14px] font-semibold">{children}</h3>,
    h4: ({ children, node: _n, ...rest }) => <h4 {...rest} className="mb-2 mt-3 scroll-mt-4 text-[13px] font-semibold">{children}</h4>,
    h5: ({ children, node: _n, ...rest }) => (
      <h5 {...rest} className="scroll-mt-4 mb-1 mt-2 text-[12.5px] font-semibold text-[color:var(--color-text-secondary)]">
        {children}
      </h5>
    ),
    h6: ({ children, node: _n, ...rest }) => (
      <h6 {...rest} className="scroll-mt-4 mb-1 mt-2 text-[12px] font-semibold uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
        {children}
      </h6>
    ),
    strong: ({ children }) => <strong className="font-semibold">{children}</strong>,
    hr: () => <hr className="my-4 border-t border-[color:var(--border)]" />,
    img: (props) => (
      <img
        {...props}
        alt={(props as { alt?: string }).alt ?? ""}
        className="my-3 max-w-full rounded-md border border-[color:var(--border)]"
      />
    ),
    table: ({ children }) => (
      <div className="my-4 overflow-x-auto overflow-y-hidden">
        <table className="w-full border-collapse text-[13px]">{children}</table>
      </div>
    ),
    tr: ({ children }) => (
      <tr className="border-b border-[color:var(--border)] last:border-b-0">{children}</tr>
    ),
    th: ({ children }) => (
      <th className="px-3 py-1.5 text-left font-semibold text-foreground">{children}</th>
    ),
    td: ({ children }) => (
      <td className="px-3 py-1.5 text-[color:var(--color-text-secondary)]">{children}</td>
    ),
    // Footnotes (GFM): remark-gfm emits a <section class="footnotes"> with an
    // <ol> of definitions and <sup><a data-footnote-ref> back-references.
    sup: ({ children }) => (
      <sup className="text-[0.7em] [&_a]:text-[color:var(--text-link)] [&_a]:no-underline [&_a]:hover:underline">
        {children}
      </sup>
    ),
    section: (props) => {
      const { children, className: cls, node: _node, ...rest } = props as ComponentProps<"section"> & {
        node?: unknown;
      };
      if ((cls ?? "").includes("footnotes")) {
        return (
          <section
            {...rest}
            className="wiki-footnotes mt-6 border-t border-[color:var(--border)] pt-3 text-[12.5px] text-[color:var(--color-text-secondary)] [&_a[data-footnote-backref]]:text-[color:var(--text-link)] [&_ol]:list-decimal [&_ol]:pl-5"
          >
            {children}
          </section>
        );
      }
      return (
        <section {...rest} className={cls}>
          {children}
        </section>
      );
    },
  } as Components;

  return (
    <div className="wiki-markdown max-w-none text-[14px] leading-[1.65] text-foreground">
      <ReactMarkdown
        // remarkCallouts runs BEFORE wikilinks/highlight so it sees the callout
        // header's first text node intact (a `[!tip] [[Home]]` title isn't split
        // out from under it).
        remarkPlugins={[remarkGfm, remarkMath, remarkCallouts, remarkWikilinks, remarkHighlight]}
        rehypePlugins={[rehypeKatex, rehypeHeadingIds]}
        // Preserve the `wiki:` sentinel scheme that remarkWikilinks emits —
        // react-markdown's defaultUrlTransform would otherwise strip it to "",
        // breaking every internal link. Everything else still goes through the
        // default safe-protocol transform.
        urlTransform={(url) => (url.startsWith("wiki:") ? url : defaultUrlTransform(url))}
        components={components}
      >
        {src}
      </ReactMarkdown>
    </div>
  );
}
