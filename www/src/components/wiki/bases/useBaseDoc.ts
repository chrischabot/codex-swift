// useBaseDoc.ts — load/save a base wiki document via the connector's
// getWikiPage / saveWikiPage, plus fetch the rows (wiki pages) the base's
// `source` selects. All persistence rides the EXISTING wiki connector methods;
// there is no new backend.

import * as React from "react";
import type { WikiPage, WikiPageSummary } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import {
  type BaseConfig,
  type BaseRow,
  DEFAULT_BASE,
  makeRow,
  parseBaseConfig,
  rowTags,
  serializeBaseConfig,
} from "./basesSchema";

const ROW_LIMIT = 200;
const SAVE_DEBOUNCE_MS = 500;
// Cap concurrent getWikiPage hydration so a large corpus doesn't fan out 200
// simultaneous RPCs. Rows beyond ROW_LIMIT are dropped (and surfaced as
// `truncated`) rather than silently swallowed.
const HYDRATE_CONCURRENCY = 8;

async function mapPool<T, R>(items: readonly T[], limit: number, fn: (item: T) => Promise<R>): Promise<R[]> {
  const out: R[] = new Array(items.length);
  let cursor = 0;
  const workers = Array.from({ length: Math.min(limit, items.length) }, async () => {
    for (;;) {
      const i = cursor++;
      if (i >= items.length) return;
      out[i] = await fn(items[i]);
    }
  });
  await Promise.all(workers);
  return out;
}

// ── The base document itself ─────────────────────────────────────────────────

export interface BaseDocState {
  /** Page title (shown in the toolbar; editable upstream via the page header). */
  title: string;
  config: BaseConfig;
  loading: boolean;
  /** True while a save is in flight. */
  saving: boolean;
  error: string | null;
}

export interface UseBaseDoc extends BaseDocState {
  /** Patch the in-memory config and persist it (debounced by the caller's flow). */
  update(next: BaseConfig): void;
  /** Force a reload from the connector. */
  reload(): void;
}

export function useBaseDoc(pageId: string): UseBaseDoc {
  const { connector, status } = useRuntime();
  const connected = status.kind === "connected";
  const [state, setState] = React.useState<BaseDocState>({
    title: "",
    config: DEFAULT_BASE,
    loading: true,
    saving: false,
    error: null,
  });
  const [reloadTick, setReloadTick] = React.useState(0);

  // Save plumbing: refs let the debounce timer flush the LATEST config and the
  // current title without going stale, and serialize concurrent saves so a
  // per-toolbar-change save can't race a debounce-timer save to a stale body.
  const configRef = React.useRef<BaseConfig>(DEFAULT_BASE);
  const titleRef = React.useRef("");
  const dirtyRef = React.useRef(false);
  const savingRef = React.useRef(false);
  const timerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);

  React.useEffect(() => {
    if (!connector.getWikiPage || !connected) {
      setState((s) => ({ ...s, loading: false }));
      return;
    }
    let alive = true;
    setState((s) => ({ ...s, loading: true, error: null }));
    connector
      .getWikiPage(pageId)
      .then((page) => {
        if (!alive) return;
        if (!page) {
          configRef.current = DEFAULT_BASE;
          titleRef.current = "";
          dirtyRef.current = false;
          setState({
            title: "",
            config: DEFAULT_BASE,
            loading: false,
            saving: false,
            error: "Base not found",
          });
          return;
        }
        const parsed = parseBaseConfig(page.content);
        configRef.current = parsed;
        titleRef.current = page.title ?? "";
        dirtyRef.current = false;
        setState({
          title: page.title ?? "",
          config: parsed,
          loading: false,
          saving: false,
          error: null,
        });
      })
      .catch((err) => {
        if (!alive) return;
        setState((s) => ({ ...s, loading: false, error: String(err) }));
      });
    return () => {
      alive = false;
    };
  }, [connector, connected, pageId, reloadTick]);

  const persist = React.useCallback(() => {
    if (!connector.saveWikiPage || !dirtyRef.current) return;
    // Serialize: if a save is in flight, leave dirty; its completion re-flushes.
    if (savingRef.current) return;
    savingRef.current = true;
    dirtyRef.current = false;
    setState((s) => ({ ...s, saving: true }));
    // Send the current title alongside body so the upsert never blanks it.
    connector
      .saveWikiPage({ id: pageId, title: titleRef.current, body: serializeBaseConfig(configRef.current) })
      .then(() => {
        savingRef.current = false;
        if (dirtyRef.current) persist();
        else setState((s) => ({ ...s, saving: false }));
      })
      .catch((err) => {
        savingRef.current = false;
        dirtyRef.current = true;
        setState((s) => ({ ...s, saving: false, error: String(err) }));
      });
  }, [connector, pageId]);

  const update = React.useCallback(
    (next: BaseConfig) => {
      configRef.current = next;
      dirtyRef.current = true;
      setState((s) => ({ ...s, config: next }));
      if (!connector.saveWikiPage) return;
      if (timerRef.current) clearTimeout(timerRef.current);
      timerRef.current = setTimeout(persist, SAVE_DEBOUNCE_MS);
    },
    [connector, persist],
  );

  // Flush a pending edit on unmount / page change so nothing is lost.
  React.useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      if (dirtyRef.current) persist();
    };
  }, [pageId, persist]);

  const reload = React.useCallback(() => setReloadTick((t) => t + 1), []);

  return { ...state, update, reload };
}

// ── The rows (pages the base's source selects) ───────────────────────────────

export interface BaseRowsState {
  rows: BaseRow[];
  loading: boolean;
  error: string | null;
  /** True when the source matched more pages than ROW_LIMIT (rows are capped). */
  truncated: boolean;
}

/**
 * Fetch the rows for a base. Uses searchWiki when `source.query` is set,
 * otherwise listWikiPages; then client-filters by `source.tag` against each
 * page's tags. To expose frontmatter properties as columns we fetch the FULL
 * page content (getWikiPage) for each summary — capped at ROW_LIMIT so a large
 * corpus doesn't fan out unbounded.
 */
export function useBaseRows(config: BaseConfig): BaseRowsState {
  const { connector, status } = useRuntime();
  const connected = status.kind === "connected";
  const [state, setState] = React.useState<BaseRowsState>({ rows: [], loading: true, error: null, truncated: false });

  const tag = config.source.tag ?? "";
  const query = config.source.query ?? "";

  React.useEffect(() => {
    if (!connected) {
      setState({ rows: [], loading: false, error: null, truncated: false });
      return;
    }
    let alive = true;
    setState((s) => ({ ...s, loading: true, error: null }));

    const fetchSummaries = (): Promise<WikiPageSummary[]> => {
      if (query.trim() && connector.searchWiki) {
        return connector.searchWiki(query.trim(), { limit: ROW_LIMIT });
      }
      if (connector.listWikiPages) {
        return connector.listWikiPages({ limit: ROW_LIMIT });
      }
      return Promise.resolve<WikiPageSummary[]>([]);
    };

    (async () => {
      try {
        const allSummaries = await fetchSummaries();
        if (!alive) return;
        // Cap before hydration: client-side filter/sort/group operates on this
        // window, so surface the truncation rather than implying full coverage.
        const truncated = allSummaries.length > ROW_LIMIT;
        const summaries = truncated ? allSummaries.slice(0, ROW_LIMIT) : allSummaries;
        // Hydrate full content for property columns + tag filtering. getWikiPage
        // is optional; when absent we degrade to summary-only rows. Bounded
        // concurrency so we never fan out ROW_LIMIT simultaneous RPCs.
        const hydrate = connector.getWikiPage?.bind(connector);
        let pages: Array<{ summary: WikiPageSummary; content?: string | null }>;
        if (hydrate) {
          pages = await mapPool(summaries, HYDRATE_CONCURRENCY, (s) =>
            hydrate(s.id)
              .then((p: WikiPage | null) => ({ summary: p ?? s, content: p?.content }))
              .catch(() => ({ summary: s, content: null as string | null })),
          );
        } else {
          pages = summaries.map((s) => ({ summary: s, content: null }));
        }
        if (!alive) return;
        let rows = pages.map((p) => makeRow(p.summary, p.content));
        // Client-side tag filter for source.tag.
        if (tag.trim()) {
          const wanted = tag.trim().replace(/^#/, "").toLowerCase();
          rows = rows.filter((r) => rowTags(r).some((t) => t.toLowerCase() === wanted));
        }
        setState({ rows, loading: false, error: null, truncated });
      } catch (err) {
        if (alive) setState({ rows: [], loading: false, error: String(err), truncated: false });
      }
    })();

    return () => {
      alive = false;
    };
  }, [connector, connected, tag, query]);

  return state;
}
