// Wiki markdown extensions for the reused www react-markdown pipeline.
//
// We DO NOT add markdown-it. Granite's renderer is markdown-it with custom
// inline/block rules; here those features become small remark plugins that
// operate on the mdast tree (the node shape react-markdown/remark exposes),
// plus one regex string pre-process for the cases remark can't cleanly
// tokenize.
//
// Implemented here (ported from granite renderer.ts):
//   - parseWikilink / slugify  (verbatim ports)
//   - parseCallout             (the `[!type] Title` header matcher + aliases)
//   - stripComments            (regex pre-process for %%...%% Obsidian comments)
//   - remarkWikilinks          ([[Page]], [[Page|alias]], ![[Page]] → link/embed)
//   - remarkHighlight          (==text== → <mark>)
//   - remarkCallouts           (> [!type] Title blockquote → tagged callout)
//
// Why a regex pre-process is NOT used for [[ ]] / == : remark tokenizes the
// markdown into an mdast where these sequences survive as plain `text` nodes
// (they aren't CommonMark syntax). Rewriting *text nodes* in a plugin is more
// robust than a string regex because it never fires inside fenced code blocks
// or inline `code` (those become `code`/`inlineCode` nodes the visitor skips).
// The one true string pre-process is stripComments(): %% ... %% can span block
// boundaries, so it's cleanest to remove before parsing.

// ── mdast node shapes (minimal, structural) ─────────────────────────────────
// We avoid importing @types/mdast (not a direct dep) and type structurally.

interface MdastText {
  type: "text";
  value: string;
}
interface MdastLink {
  type: "link";
  url: string;
  title?: string | null;
  children: MdastNode[];
  data?: MdastNodeData;
}
interface MdastNodeData {
  hName?: string;
  hProperties?: Record<string, unknown>;
  hChildren?: unknown[];
  [key: string]: unknown;
}
interface MdastParent {
  type: string;
  children: MdastNode[];
  data?: MdastNodeData;
  [key: string]: unknown;
}
type MdastNode =
  | MdastText
  | MdastLink
  | MdastParent
  | { type: string; value?: string; children?: MdastNode[]; data?: MdastNodeData; [key: string]: unknown };

function isParent(node: MdastNode): node is MdastParent {
  return Array.isArray((node as MdastParent).children);
}

// Node types whose inner text is literal and must not be rewritten.
const LITERAL_TYPES = new Set(["code", "inlineCode", "math", "inlineMath", "html"]);

// ── Wikilink parsing (ported verbatim from granite renderer.ts:16-37) ───────

export interface WikilinkParts {
  readonly target: string;
  readonly display: string | null;
  readonly heading: string | null;
  readonly block: string | null;
}

export function parseWikilink(raw: string): WikilinkParts {
  let target = raw;
  let display: string | null = null;
  const pipeIdx = raw.indexOf("|");
  if (pipeIdx !== -1) {
    target = raw.slice(0, pipeIdx);
    display = raw.slice(pipeIdx + 1);
  }
  let heading: string | null = null;
  let block: string | null = null;
  const hashIdx = target.indexOf("#");
  if (hashIdx !== -1) {
    const after = target.slice(hashIdx + 1);
    target = target.slice(0, hashIdx);
    if (after.startsWith("^")) {
      block = after.slice(1);
    } else {
      heading = after;
    }
  }
  return { target: target.trim(), display, heading, block };
}

// ── Heading slugs (ported verbatim from granite renderer.ts:534-542) ────────

export function slugify(text: string): string {
  return text
    .toLowerCase()
    .normalize("NFD")
    .replace(/\p{Mark}/gu, "")
    .replace(/[^a-z0-9\s-]/g, "")
    .trim()
    .replace(/\s+/g, "-");
}

// ── Callout type aliases (ported from granite renderer.ts:54-82) ────────────

const CALLOUT_ALIASES: Record<string, string> = {
  note: "note",
  abstract: "abstract",
  summary: "abstract",
  tldr: "abstract",
  info: "info",
  todo: "todo",
  tip: "tip",
  hint: "tip",
  important: "important",
  success: "success",
  check: "success",
  done: "success",
  question: "question",
  help: "question",
  faq: "question",
  warning: "warning",
  caution: "warning",
  attention: "warning",
  failure: "failure",
  fail: "failure",
  missing: "failure",
  danger: "danger",
  error: "danger",
  bug: "bug",
  example: "example",
  quote: "quote",
  cite: "quote",
};

/** The canonical callout types the Callout component knows how to style. */
export type CalloutType =
  | "note"
  | "abstract"
  | "info"
  | "todo"
  | "tip"
  | "important"
  | "success"
  | "question"
  | "warning"
  | "failure"
  | "danger"
  | "bug"
  | "example"
  | "quote";

export interface CalloutHeader {
  /** Canonical callout type (after alias resolution). */
  type: CalloutType;
  /** Optional inline title following the marker; null = use the type name. */
  title: string | null;
  /** Foldable marker: "+" (open) / "-" (collapsed) / null (not foldable). */
  fold: "+" | "-" | null;
}

const CALLOUT_HEADER_RE = /^\[!([^\]\n]+)\]([+-]?)\s*(.*)$/;

/**
 * Match a callout header line ("[!type] Title"). Returns the canonical type,
 * the trailing title (or null), the fold marker, and the body text that
 * remained on that first line after the marker (almost always empty).
 * Ported from granite renderer.ts:440-446.
 */
export function parseCallout(firstLine: string): CalloutHeader | null {
  const m = CALLOUT_HEADER_RE.exec(firstLine);
  if (!m) return null;
  const rawType = (m[1] ?? "").toLowerCase().trim();
  const fold = m[2] === "+" || m[2] === "-" ? (m[2] as "+" | "-") : null;
  const title = (m[3] ?? "").trim();
  const canonical = (CALLOUT_ALIASES[rawType] ?? "note") as CalloutType;
  return { type: canonical, title: title.length > 0 ? title : null, fold };
}

// ── %%comments%% (regex pre-process — see header comment) ───────────────────

/**
 * Strip Obsidian comments `%% ... %%` (inline and multi-line block) from a
 * markdown source string before it is handed to react-markdown. Comments are
 * hidden in reading view (granite emits nothing for them).
 */
export function stripComments(source: string): string {
  // Single pass: match a fenced/inline CODE region OR a `%%` comment. Keep the
  // code verbatim (so a literal `%%` in a code sample survives), drop comments.
  // The alternation tries code first, so a `%%` inside code is consumed as code.
  return source.replace(
    /(```[\s\S]*?```|`[^`\n]*`)|%%[\s\S]*?%%/g,
    (_m, code) => (code ? code : ""),
  );
}

// ── rehypeHeadingIds ────────────────────────────────────────────────────────

/**
 * Add github-style `id`s to h1–h6 (using the same {@link slugify} the outline
 * panel uses) so intra-page `[[Page#Heading]]` links and the outline's
 * jump-to-heading can scroll to anchors. Walks the hast tree structurally to
 * avoid an external unist-util-visit dependency.
 */
export function rehypeHeadingIds() {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const hastText = (node: any): string => {
    if (node?.type === "text") return node.value ?? "";
    if (Array.isArray(node?.children)) return node.children.map(hastText).join("");
    return "";
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  const walk = (node: any): void => {
    if (node?.type === "element" && /^h[1-6]$/.test(node.tagName)) {
      node.properties = node.properties ?? {};
      if (!node.properties.id) {
        const slug = slugify(hastText(node));
        if (slug) node.properties.id = slug;
      }
    }
    if (Array.isArray(node?.children)) for (const c of node.children) walk(c);
  };
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  return (tree: any) => walk(tree);
}

// ── remarkWikilinks ─────────────────────────────────────────────────────────

// Matches [[..]] and ![[..]] with a leading group capturing the optional "!".
const WIKILINK_RE = /(!?)\[\[([^\]\n]+)\]\]/g;

/**
 * remark plugin: rewrite `[[Target|Display]]` text into mdast `link` nodes and
 * `![[Target]]` into an embed placeholder node (rendered by WikiEmbed).
 *
 * Link nodes carry a `wiki:` URL sentinel so WikiMarkdown's `a` override can
 * detect them and route via the onWikiLink callback rather than the browser.
 * The full link target (with #heading / #^block suffix) is preserved in the
 * url after the scheme so callers can decide how to resolve it.
 *
 * Embed nodes are emitted as a `paragraph`-level / inline element with
 * `data.hName = "wiki-embed"` and the target in `data.hProperties`. We render
 * `<a>` for links and a custom element for embeds; rehype maps unknown tag
 * names to the matching `components` override, so WikiMarkdown registers a
 * `"wiki-embed"` component.
 */
export function remarkWikilinks() {
  return (tree: MdastNode): void => {
    transform(tree);
  };

  function transform(node: MdastNode): void {
    if (!isParent(node)) return;
    const out: MdastNode[] = [];
    for (const child of node.children) {
      if (child.type === "text") {
        out.push(...splitText((child as MdastText).value));
      } else {
        if (!LITERAL_TYPES.has(child.type)) transform(child);
        out.push(child);
      }
    }
    node.children = out;
  }

  function splitText(value: string): MdastNode[] {
    WIKILINK_RE.lastIndex = 0;
    if (!WIKILINK_RE.test(value)) return [{ type: "text", value } as MdastText];
    WIKILINK_RE.lastIndex = 0;

    const nodes: MdastNode[] = [];
    let last = 0;
    let m: RegExpExecArray | null;
    while ((m = WIKILINK_RE.exec(value)) !== null) {
      if (m.index > last) {
        nodes.push({ type: "text", value: value.slice(last, m.index) } as MdastText);
      }
      const isEmbed = m[1] === "!";
      const parts = parseWikilink(m[2] ?? "");
      const suffix = parts.heading
        ? `#${parts.heading}`
        : parts.block
          ? `#^${parts.block}`
          : "";
      const fullTarget = parts.target + suffix;

      if (isEmbed) {
        nodes.push({
          type: "wikiEmbed",
          data: {
            hName: "wiki-embed",
            hProperties: {
              target: parts.target,
              fullTarget,
              display: parts.display ?? parts.target,
            },
          },
        } as MdastNode);
      } else {
        const display = parts.display ?? parts.target;
        nodes.push({
          type: "link",
          url: `wiki:${fullTarget}`,
          children: [{ type: "text", value: display } as MdastText],
          data: {
            hProperties: {
              "data-wikilink": "true",
              "data-target": fullTarget,
            },
          },
        } as MdastLink);
      }
      last = WIKILINK_RE.lastIndex;
    }
    if (last < value.length) {
      nodes.push({ type: "text", value: value.slice(last) } as MdastText);
    }
    return nodes;
  }
}

// ── remarkCallouts ──────────────────────────────────────────────────────────

/**
 * remark plugin: detect Obsidian callout blockquotes `> [!type] Title` and
 * (a) strip the `[!type] Title` marker from the first text node so it isn't
 * rendered in the body, and (b) tag the blockquote's `data.hProperties` with
 * `data-callout` / `data-callout-title` so WikiMarkdown's `blockquote`
 * override can render the styled Callout box. Ported from granite
 * renderer.ts:407-500 (without the markdown-it token surgery).
 */
export function remarkCallouts() {
  return (tree: MdastNode): void => {
    transform(tree);
  };

  function transform(node: MdastNode): void {
    if (!isParent(node)) return;
    for (const child of node.children) {
      if (child.type === "blockquote") tagCallout(child as MdastParent);
      transform(child);
    }
  }

  function tagCallout(bq: MdastParent): void {
    const firstPara = bq.children.find((c) => c.type === "paragraph") as MdastParent | undefined;
    if (!firstPara || !Array.isArray(firstPara.children)) return;
    const firstText = firstPara.children[0];
    if (!firstText || firstText.type !== "text") return;
    const value = (firstText as MdastText).value;
    const firstLine = value.split("\n")[0] ?? "";
    const header = parseCallout(firstLine);
    if (!header) return;

    // Strip the marker line from the first text node (keep any remainder).
    const rest = value.slice(firstLine.length).replace(/^\n/, "");
    if (rest.length > 0) {
      (firstText as MdastText).value = rest;
    } else {
      // Drop the now-empty leading text node; if the paragraph is then empty,
      // drop the paragraph too so the body starts clean.
      firstPara.children.shift();
      if (firstPara.children.length === 0) {
        bq.children = bq.children.filter((c) => c !== firstPara);
      }
    }

    const data: MdastNodeData = (bq.data ??= {});
    const props: Record<string, unknown> = (data.hProperties ??= {});
    props["data-callout"] = header.type;
    if (header.title) props["data-callout-title"] = header.title;
    if (header.fold) props["data-callout-fold"] = header.fold;
  }
}

// ── remarkHighlight (==text== → <mark>) ─────────────────────────────────────

const HIGHLIGHT_RE = /==([^=\n]+)==/g;

/**
 * remark plugin: rewrite `==text==` text spans into a node rendered as
 * `<mark>` (via data.hName). remark-gfm does not cover `==highlight==`.
 */
export function remarkHighlight() {
  return (tree: MdastNode): void => {
    transform(tree);
  };

  function transform(node: MdastNode): void {
    if (!isParent(node)) return;
    const out: MdastNode[] = [];
    for (const child of node.children) {
      if (child.type === "text") {
        out.push(...splitText((child as MdastText).value));
      } else {
        if (!LITERAL_TYPES.has(child.type)) transform(child);
        out.push(child);
      }
    }
    node.children = out;
  }

  function splitText(value: string): MdastNode[] {
    HIGHLIGHT_RE.lastIndex = 0;
    if (!HIGHLIGHT_RE.test(value)) return [{ type: "text", value } as MdastText];
    HIGHLIGHT_RE.lastIndex = 0;

    const nodes: MdastNode[] = [];
    let last = 0;
    let m: RegExpExecArray | null;
    while ((m = HIGHLIGHT_RE.exec(value)) !== null) {
      if (m.index > last) {
        nodes.push({ type: "text", value: value.slice(last, m.index) } as MdastText);
      }
      nodes.push({
        type: "highlight",
        data: { hName: "mark" },
        children: [{ type: "text", value: m[1] ?? "" } as MdastText],
      } as MdastNode);
      last = HIGHLIGHT_RE.lastIndex;
    }
    if (last < value.length) {
      nodes.push({ type: "text", value: value.slice(last) } as MdastText);
    }
    return nodes;
  }
}
