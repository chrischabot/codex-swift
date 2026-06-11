import type { ComponentProps, ReactNode } from "react";
import ReactMarkdown, { type Components, defaultUrlTransform } from "react-markdown";
import remarkGfm from "remark-gfm";
import remarkMath from "remark-math";
import rehypeKatex from "rehype-katex";
import "katex/dist/katex.min.css";
import { cn } from "@/lib/utils";
import { CodeBlock } from "@/components/chat/CodeBlock";
import { Mermaid } from "@/components/chat/Mermaid";
import { Callout } from "./markdown/Callout";
import { WikiEmbed } from "./markdown/WikiEmbed";
import {
  useWikiLive,
  WikiLiveProvider,
  type EmbedLoader,
  type WikiLiveValue,
} from "./markdown/WikiLiveContext";
import { WikiBacklinksBlock, WikiQueryBlock } from "./markdown/WikiLiveBlocks";
import { WikiLinkWithHover } from "./hover/WikiLinkWithHover";
import {
  type CalloutType,
  rehypeHeadingIds,
  decodeWikiTarget,
  remarkBlockIds,
  remarkCallouts,
  remarkHashtags,
  remarkHighlight,
  remarkTaskListLines,
  remarkWikilinks,
  stripComments,
} from "./markdown/wikiRemarkPlugins";
// The wiki stylesheet (callouts / highlight / embed / footnotes polish). Imported
// here — the renderer that emits the .wiki-* classes — so it always loads with
// the reading surface and switches with the app's .dark theme.
import "@/styles/wiki.css";

/** No-op handler for the controlled-but-readonly task checkbox (see `input`
 *  override). Stable identity avoids a re-render churn. */
const NOOP = () => {};

interface Props {
  content: string;
  /** Invoked when an internal wikilink `[[Target]]` or embed is clicked. The
   *  argument is the full target (including any `#heading` / `#^block`
   *  suffix). */
  onWikiLink?: (target: string) => void;
  /** Maps a (suffix-stripped) wikilink title to a page id. When provided, a
   *  resolvable `[[Target]]` anchor gets a hover preview card. Built by the host
   *  (typically a lowercased title→id Map from listWikiPages); returns undefined
   *  for dangling links, which then render as a plain anchor (no card). */
  resolveWikiLink?: (title: string) => string | undefined;
  /** Invoked when an inline `#tag` link is clicked. Receives the bare tag (no
   *  leading `#`). When omitted, inline tags render as plain styled spans. */
  onTag?: (tag: string) => void;
  /** Toggle a task-list checkbox. `line` is the 0-based source line of the
   *  `- [ ]` / `- [x]` item; `checked` is the NEW desired state. When omitted
   *  checkboxes stay read-only (matching the previous behavior). */
  onToggleTask?: (line: number, checked: boolean) => void;
  /** Constrain the rendered content to a readable max line width (from the
   *  wiki `readableLineWidth` setting). */
  readableLineWidth?: boolean;
  /** Loads a page body by wikilink title for `![[Page]]` transclusion (M27).
   *  When supplied, embeds render the referenced note inline (depth-guarded);
   *  otherwise they stay placeholder cards. */
  loadEmbed?: EmbedLoader;
  /** Enables live ```query``` / ```backlinks``` blocks for this page (top-level
   *  reading view only). `pageId` scopes the backlinks block. */
  liveContext?: { pageId?: string; pageTitle?: string };
  /** Open a page by id — used by live blocks (backlinks/query rows). */
  onOpenPageId?: (id: string) => void;
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
export function WikiMarkdown({
  content,
  onWikiLink,
  resolveWikiLink,
  onTag,
  onToggleTask,
  readableLineWidth,
  loadEmbed,
  liveContext,
  onOpenPageId,
}: Props) {
  const src = stripComments(content);

  // Merge our props onto any inherited live context (an embed wraps a nested
  // WikiMarkdown in its own provider; we must NOT reset its depth/chain). The
  // top-level reading view supplies loadEmbed + liveContext to turn features on.
  const inherited = useWikiLive();
  const liveValue: WikiLiveValue = {
    loadEmbed: loadEmbed ?? inherited.loadEmbed,
    embedDepth: inherited.embedDepth,
    embedChain: inherited.embedChain,
    currentPageId: liveContext?.pageId ?? inherited.currentPageId,
    currentPageTitle: liveContext?.pageTitle ?? inherited.currentPageTitle,
    liveBlocks: liveContext ? true : inherited.liveBlocks,
  };

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
        // rehype percent-encodes the URL (spaces → %20, etc.), so decode back to
        // the human title before resolution — otherwise `[[Two Words]]` becomes
        // "Two%20Words" and never matches a title→id map (breaking direct-open
        // AND hover for any multi-word page).
        const target = decodeWikiTarget(href.slice("wiki:".length));
        return (
          <WikiLinkWithHover
            target={target}
            resolveId={resolveWikiLink}
            onOpen={onWikiLink}
          >
            {children}
          </WikiLinkWithHover>
        );
      }
      // Inline `#tag` links (emitted by remarkHashtags as `wikitag:<tag>`):
      // route the click through onTag (bare tag, no leading #) instead of the
      // browser. When no handler is wired, render a non-navigating styled span.
      if (typeof href === "string" && href.startsWith("wikitag:")) {
        const tag = decodeWikiTarget(href.slice("wikitag:".length));
        const clickable = typeof onTag === "function";
        return (
          <a
            href={`#${tag}`}
            className={cn(
              "wiki-tag text-[color:var(--text-link)] no-underline",
              clickable && "cursor-pointer hover:underline",
            )}
            role={clickable ? "button" : undefined}
            onClick={
              clickable
                ? (e) => {
                    e.preventDefault();
                    onTag!(tag);
                  }
                : (e) => e.preventDefault()
            }
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
          anchorId={props.id != null ? String(props.id) : undefined}
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
        "data-callout-fold"?: string;
      };
      const calloutType = (rest as Record<string, unknown>)["data-callout"] as
        | string
        | undefined;
      if (calloutType) {
        const title = (rest as Record<string, unknown>)["data-callout-title"] as
          | string
          | undefined;
        const foldRaw = (rest as Record<string, unknown>)["data-callout-fold"] as
          | string
          | undefined;
        const fold = foldRaw === "+" || foldRaw === "-" ? foldRaw : null;
        return (
          <Callout type={calloutType as CalloutType} title={title ?? null} fold={fold}>
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
    // Pass through props (notably the `id` that remarkBlockIds sets for
    // `^blockid` anchors); drop react-markdown's internal `node` prop.
    p: ({ children, node: _node, ...rest }) => (
      <p {...rest} className="mb-3 last:mb-0">
        {children}
      </p>
    ),
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
    li: (props) => {
      const { children, className: cls, node: _n, ...rest } = props as ComponentProps<"li"> & {
        node?: unknown;
        "data-task-line"?: string;
        "data-task-checked"?: string;
      };
      const isTask = (cls ?? "").includes("task-list-item");
      // remarkTaskListLines stamps the 0-based source line + current state on the
      // <li> (react-markdown v9 strips mdast position from the node it passes to
      // overrides, so the line is recovered from this data-attr instead). When a
      // toggle handler is wired we intercept clicks on the checkbox and report
      // that source line + the new state.
      const lineStr = (rest as Record<string, unknown>)["data-task-line"] as string | undefined;
      const checkedStr = (rest as Record<string, unknown>)["data-task-checked"] as string | undefined;
      const line = lineStr != null && /^\d+$/.test(lineStr) ? Number(lineStr) : undefined;
      const editable = isTask && typeof onToggleTask === "function" && line != null;
      // Strip our private data-attrs so they don't leak onto the DOM <li>.
      delete (rest as Record<string, unknown>)["data-task-line"];
      delete (rest as Record<string, unknown>)["data-task-checked"];
      return (
        <li
          {...rest}
          className={cn(
            "mb-1 marker:text-[color:var(--color-text-quaternary)]",
            isTask && "task-list-item flex list-none items-start gap-2",
            editable && "[&>input[type=checkbox]]:cursor-pointer",
          )}
          // Capture-phase click on the (otherwise read-only) checkbox toggles
          // the matching source line. Using onClick (not onChange) avoids React's
          // controlled-checkbox warning while the box stays a read-only mirror of
          // persisted state — the host re-renders with the new body after saving.
          onClickCapture={
            editable
              ? (e) => {
                  const t = e.target as HTMLElement;
                  if (
                    t instanceof HTMLInputElement &&
                    t.type === "checkbox"
                  ) {
                    e.preventDefault();
                    onToggleTask!(line!, checkedStr !== "true");
                  }
                }
              : undefined
          }
        >
          {children}
        </li>
      );
    },
    input: (props) => {
      const { type } = props as { type?: string };
      if (type === "checkbox") {
        // Task checkboxes render as a read-only mirror of the persisted state;
        // the editable toggle is wired on the parent <li> (see above), so the
        // box never desyncs from the saved body. Plain (non-task) inputs pass
        // through untouched.
        return (
          <input
            type="checkbox"
            readOnly
            checked={(props as { checked?: boolean }).checked ?? false}
            // Controlled + readOnly: a no-op onChange silences React's warning;
            // the real toggle is the parent <li>'s onClickCapture. When no
            // handler is wired the click is harmless (readOnly = no state flip).
            onChange={NOOP}
            className="mt-1 size-3.5 shrink-0 accent-[color:var(--color-blue-400)]"
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
      // A ```mermaid fence renders as a live diagram (reusing the chat
      // Mermaid component) rather than a syntax-highlighted source block.
      if (lang === "mermaid") {
        return <Mermaid content={text.replace(/\n$/, "")} />;
      }
      // Live blocks (M27) — only at the top reading view (liveBlocks gate), so
      // they don't run inside hover cards or embeds. Elsewhere → plain code.
      if (liveValue.liveBlocks && (lang === "backlinks" || lang === "wiki-backlinks")) {
        return <WikiBacklinksBlock onOpen={onOpenPageId} />;
      }
      if (liveValue.liveBlocks && (lang === "query" || lang === "wiki-query")) {
        return <WikiQueryBlock source={text} onOpen={onOpenPageId} />;
      }
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
    <WikiLiveProvider value={liveValue}>
    <div
      className={cn(
        "wiki-markdown text-[14px] leading-[1.65] text-foreground",
        readableLineWidth ? "wiki-readable-width mx-auto max-w-[42rem]" : "max-w-none",
      )}
    >
      <ReactMarkdown
        // remarkCallouts runs BEFORE wikilinks/highlight so it sees the callout
        // header's first text node intact (a `[!tip] [[Home]]` title isn't split
        // out from under it).
        remarkPlugins={[remarkGfm, remarkMath, remarkTaskListLines, remarkBlockIds, remarkCallouts, remarkWikilinks, remarkHighlight, remarkHashtags]}
        rehypePlugins={[rehypeKatex, rehypeHeadingIds]}
        // Preserve the `wiki:` sentinel scheme that remarkWikilinks emits —
        // react-markdown's defaultUrlTransform would otherwise strip it to "",
        // breaking every internal link. Everything else still goes through the
        // default safe-protocol transform.
        urlTransform={(url) =>
          url.startsWith("wiki:") || url.startsWith("wikitag:") ? url : defaultUrlTransform(url)
        }
        components={components}
      >
        {src}
      </ReactMarkdown>
    </div>
    </WikiLiveProvider>
  );
}
