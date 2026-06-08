import {
  type Completion,
  type CompletionContext,
  type CompletionResult,
  type CompletionSource,
  autocompletion,
} from "@codemirror/autocomplete";
import type { Extension } from "@codemirror/state";
import type { EditorView } from "@codemirror/view";

/**
 * Editor autocomplete for the wiki markdown surface, ported from granite's
 * MarkdownView completion sources. Three triggers fan out into one
 * `autocompletion` extension:
 *
 *   - `[[`  → wiki page titles  (async, debounced + cached)
 *   - `#`   → tags              (async, debounced + cached)
 *   - `/`   → slash commands    (static markdown snippet inserts)
 *
 * Providers are passed in by the host so this module stays decoupled from the
 * runtime connector. Each provider is wrapped with a short TTL cache + an
 * in-flight dedupe so rapid keystrokes don't fan out a request per character.
 */

export interface WikiPageOption {
  id: string;
  title: string;
}

/** Async data feeds the host wires from the connector. */
export interface AutocompleteProviders {
  /** Returns the known wiki pages for `[[` completion. */
  pages: () => Promise<WikiPageOption[]>;
  /** Returns the known tag names (without the leading `#`) for `#` completion. */
  tags: () => Promise<string[]>;
}

const CACHE_TTL_MS = 5_000;

/**
 * Wrap an async provider with a TTL cache and in-flight dedupe. Completion
 * sources can be invoked on nearly every keystroke; without this each one
 * would re-hit the connector. The cache is intentionally tiny (single slot,
 * no key) because the providers take no arguments — they return the full set
 * and the source filters locally.
 */
function cached<T>(fn: () => Promise<T>): () => Promise<T> {
  let value: T | undefined;
  let at = 0;
  let inflight: Promise<T> | null = null;
  return () => {
    const now = Date.now();
    if (value !== undefined && now - at < CACHE_TTL_MS) {
      return Promise.resolve(value);
    }
    if (inflight) return inflight;
    inflight = fn()
      .then((result) => {
        value = result;
        at = Date.now();
        inflight = null;
        return result;
      })
      .catch((err) => {
        inflight = null;
        throw err;
      });
    return inflight;
  };
}

// ── `/` slash commands ──────────────────────────────────────────────────────
// Each command replaces the `/token` with a markdown snippet. `cursor` is the
// caret offset (from the start of `insert`) to place after the apply, so the
// user lands inside the snippet (e.g. between **|**).
interface SlashCommand {
  label: string;
  detail: string;
  insert: string;
  /** Caret offset within `insert` after apply; defaults to end of insert. */
  cursor?: number;
}

const SLASH_COMMANDS: SlashCommand[] = [
  { label: "Heading 1", detail: "# ", insert: "# " },
  { label: "Heading 2", detail: "## ", insert: "## " },
  { label: "Heading 3", detail: "### ", insert: "### " },
  { label: "Heading 4", detail: "#### ", insert: "#### " },
  { label: "Bold", detail: "**text**", insert: "**bold**", cursor: 2 },
  { label: "Italic", detail: "*text*", insert: "*italic*", cursor: 1 },
  { label: "Link", detail: "[text](url)", insert: "[text](url)", cursor: 1 },
  {
    label: "Callout",
    detail: "> [!note]",
    insert: "> [!note]\n> ",
    cursor: 4,
  },
  {
    label: "Code block",
    detail: "```lang …```",
    insert: "```\n\n```\n",
    cursor: 4,
  },
  {
    label: "Table",
    detail: "Markdown table",
    insert: "| Column | Column |\n| --- | --- |\n|  |  |\n",
    cursor: 2,
  },
];

const slashCommandSource: CompletionSource = (context: CompletionContext): CompletionResult | null => {
  const before = context.matchBefore(/\/[\w-]*$/);
  if (!before) return null;
  if (before.from === before.to && !context.explicit) return null;

  // Only fire at the start of a line (leading whitespace allowed) so a `/` in
  // the middle of prose (URLs, dates) doesn't pop the menu.
  const lineStart = context.state.doc.lineAt(before.from).from;
  const head = context.state.sliceDoc(lineStart, before.from);
  if (!/^\s*$/.test(head)) return null;

  const query = context.state.sliceDoc(before.from + 1, before.to).toLowerCase();
  const filtered = query
    ? SLASH_COMMANDS.filter((c) => c.label.toLowerCase().includes(query))
    : SLASH_COMMANDS;

  return {
    from: before.from,
    options: filtered.map((cmd): Completion => ({
      label: cmd.label,
      detail: cmd.detail,
      type: "keyword",
      apply: (view: EditorView, _c, from: number, to: number) => {
        const anchor = from + (cmd.cursor ?? cmd.insert.length);
        view.dispatch({
          changes: { from, to, insert: cmd.insert },
          selection: { anchor },
        });
      },
    })),
  };
};

// ── `[[` wiki page links ──────────────────────────────────────────────────────
function wikilinkSource(pages: () => Promise<WikiPageOption[]>): CompletionSource {
  return async (context: CompletionContext): Promise<CompletionResult | null> => {
    const before = context.matchBefore(/\[\[([^[\]\n]*)$/);
    if (!before) return null;
    if (before.from === before.to && !context.explicit) return null;

    // Consume an auto-closed `]]` so we don't leave a dangling pair.
    const after = context.state.sliceDoc(before.to, before.to + 2);
    const consumeTrailing = after === "]]" ? 2 : 0;

    const query = context.state.sliceDoc(before.from + 2, before.to).toLowerCase();
    let entries: WikiPageOption[];
    try {
      entries = await pages();
    } catch {
      return null;
    }
    if (context.aborted) return null;

    const filtered = query
      ? entries.filter((p) => p.title.toLowerCase().includes(query))
      : entries;

    return {
      from: before.from,
      options: filtered.slice(0, 100).map((entry): Completion => ({
        label: entry.title,
        type: "text",
        apply: (view: EditorView, _c, from: number, to: number) => {
          const insert = `[[${entry.title}]]`;
          view.dispatch({
            changes: { from, to: to + consumeTrailing, insert },
            selection: { anchor: from + insert.length },
          });
        },
      })),
    };
  };
}

// ── `#` tags ──────────────────────────────────────────────────────────────────
function tagSource(tags: () => Promise<string[]>): CompletionSource {
  return async (context: CompletionContext): Promise<CompletionResult | null> => {
    const before = context.matchBefore(/(^|[\s([])#([\p{L}\p{N}_/-]*)$/u);
    if (!before) return null;
    if (before.from === before.to && !context.explicit) return null;

    const matchText = context.state.sliceDoc(before.from, before.to);
    const hashIdx = matchText.indexOf("#");
    if (hashIdx === -1) return null;
    const triggerFrom = before.from + hashIdx;

    // Skip inside a fenced code block (odd run of ``` line-starts before us).
    const beforeCursor = context.state.sliceDoc(0, triggerFrom);
    const fenceCount = (beforeCursor.match(/(^|\n)```/g) ?? []).length;
    if (fenceCount % 2 === 1) return null;

    // Skip inside an inline-code span (odd backtick count on the current line).
    const lineStart = context.state.doc.lineAt(triggerFrom).from;
    const lineHead = context.state.sliceDoc(lineStart, triggerFrom);
    const inlineTicks = (lineHead.match(/`/g) ?? []).length;
    if (inlineTicks % 2 === 1) return null;

    const query = matchText.slice(hashIdx + 1).toLowerCase();
    let all: string[];
    try {
      all = await tags();
    } catch {
      return null;
    }
    if (context.aborted) return null;

    const filtered = query ? all.filter((tag) => tag.toLowerCase().includes(query)) : all;
    if (filtered.length === 0) return null;

    return {
      from: triggerFrom,
      options: filtered.slice(0, 100).map((tag): Completion => ({
        label: `#${tag}`,
        type: "keyword",
        apply: (view: EditorView, _c, from: number, to: number) => {
          const insert = `#${tag}`;
          view.dispatch({
            changes: { from, to, insert },
            selection: { anchor: from + insert.length },
          });
        },
      })),
    };
  };
}

/**
 * Build the markdown autocomplete extension wiring `[[`, `#`, and `/` sources.
 * Providers are debounced/cached internally so the connector isn't hammered.
 */
export function wikiAutocomplete(providers: AutocompleteProviders): Extension {
  const pages = cached(providers.pages);
  const tags = cached(providers.tags);
  return autocompletion({
    override: [wikilinkSource(pages), tagSource(tags), slashCommandSource],
    activateOnTyping: true,
    closeOnBlur: true,
    icons: false,
  });
}
