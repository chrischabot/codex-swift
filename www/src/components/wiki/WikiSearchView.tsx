import * as React from "react";
import { useNavigate } from "react-router-dom";
import { Search, FileText, Loader2 } from "lucide-react";
import type { WikiPageSummary } from "@/runtime/connector";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import { ScrollArea } from "@/components/ui/scroll-area";
import { cn } from "@/lib/utils";
import { highlightMatch } from "./highlightMatch";
import { parseSearchQuery, matchSummary, requiresFullCorpus, type SearchQuery } from "./search/searchQuery";

interface Props {
  /** The active query — typically driven from the `?q=` search param. */
  query: string;
  /** Notify the host of edits so it can mirror the query into the URL (?q=). */
  onQueryChange?: (q: string) => void;
}

const DEBOUNCE_MS = 200;
const SEARCH_LIMIT = 50;

// Operator grammar (AND/OR/NOT, tag/title/path, /regex/, "phrases") lives in
// ./search/searchQuery — parsed here and applied client-side over the BM25
// summaries. `query.fullText` is what we send to searchWiki; an operator-only
// query (no free terms) falls back to listing pages and filtering.

/** Operator chips shown above the results (tag:/title:/path:/regex/-exclusions). */
function operatorChips(parsed: SearchQuery): string[] {
  const chips: string[] = [];
  for (const group of parsed.groups) {
    for (const p of group) {
      if (p.kind === "term") continue;
      const prefix = p.negate ? "-" : "";
      if (p.kind === "tag") chips.push(`${prefix}#${p.value}`);
      else if (p.kind === "phrase") chips.push(`${prefix}"${p.value}"`);
      else if (p.kind === "regex") chips.push(`${prefix}/${p.value}/`);
      else chips.push(`${prefix}${p.kind}:${p.value}`);
    }
  }
  return chips;
}

interface SearchState {
  results: WikiPageSummary[];
  loading: boolean;
  /** The full-text query that produced `results` (drives the empty-state copy). */
  ran: string;
  /** True when the candidate fetch hit its cap — operator filters ran over a
   *  bounded window, so matches beyond it may be missing. Surfaced to the user. */
  truncated: boolean;
}

// Candidate fetch caps. Operator-bearing free-text queries pull a WIDER BM25
// window so the client filters don't just see the top-50 lexical hits.
const OPERATOR_CANDIDATES = 200;
const LIST_CANDIDATES = 500;

/**
 * Self-contained debounced search hook. Mirrors the `state/wiki.ts` pattern
 * (keyed on `status.kind === "connected"`, guards the optional connector
 * method) but kept local so the integrator mounts WikiSearchView without
 * touching shared state. The `tag:`/`title:` filters are applied client-side;
 * only the bare full-text is sent over the wire.
 */
function useWikiSearch(query: string): SearchState {
  const { connector, status } = useRuntime();
  const [state, setState] = React.useState<SearchState>({ results: [], loading: false, ran: "", truncated: false });
  const connected = status.kind === "connected";
  const parsed = React.useMemo(() => parseSearchQuery(query), [query]);

  React.useEffect(() => {
    const { fullText, hasQuery, groups } = parsed;
    if (!hasQuery) {
      setState({ results: [], loading: false, ran: "", truncated: false });
      return;
    }
    if (!connector.searchWiki || !connected) {
      setState({ results: [], loading: false, ran: query, truncated: false });
      return;
    }
    // Any non-`term` predicate is an operator that filters client-side, so we
    // need a wider candidate window than the top-50 BM25 hits.
    const hasOperators = groups.some((g) => g.some((p) => p.kind !== "term"));
    // BM25 can only seed groups that contain a free term. If ANY OR-group is
    // operator-only (e.g. `title:Roadmap OR urgent`) we MUST list the corpus, or
    // that group's matches are silently lost.
    const useBM25 = fullText.length > 0 && !requiresFullCorpus(parsed);
    let alive = true;
    setState((s) => ({ ...s, loading: true }));
    const handle = setTimeout(() => {
      // Free terms seed the BM25 fetch (wider when operators will filter it);
      // otherwise list pages to filter against.
      const cap = useBM25 ? (hasOperators ? OPERATOR_CANDIDATES : SEARCH_LIMIT) : LIST_CANDIDATES;
      const fetcher =
        useBM25
          ? connector.searchWiki!(fullText, { limit: cap })
          : connector.listWikiPages
            ? connector.listWikiPages({ limit: cap })
            : Promise.resolve<WikiPageSummary[]>([]);
      fetcher
        .then((rows) => {
          if (!alive) return;
          // The candidate set hit its cap → there may be matches beyond it.
          const hitCap = rows.length >= cap;
          const matched = rows.filter((r) => matchSummary(r, parsed));
          const filtered = matched.slice(0, SEARCH_LIMIT);
          setState({
            results: filtered,
            loading: false,
            ran: query,
            truncated: hitCap || matched.length > filtered.length,
          });
        })
        .catch(() => {
          if (alive) setState({ results: [], loading: false, ran: query, truncated: false });
        });
    }, DEBOUNCE_MS);
    return () => {
      alive = false;
      clearTimeout(handle);
    };
  }, [connector, connected, parsed, query]);

  return state;
}

export function WikiSearchView({ query, onQueryChange }: Props) {
  const navigate = useNavigate();
  const parsed = React.useMemo(() => parseSearchQuery(query), [query]);
  const chips = React.useMemo(() => operatorChips(parsed), [parsed]);
  const { results, loading, ran, truncated } = useWikiSearch(query);
  const [selected, setSelected] = React.useState(0);
  const listRef = React.useRef<HTMLDivElement>(null);

  // Keep the highlighted row valid + visible as results change.
  React.useEffect(() => {
    setSelected((i) => (results.length === 0 ? 0 : Math.min(i, results.length - 1)));
  }, [results.length]);

  const open = React.useCallback(
    (page: WikiPageSummary) => navigate(`/wiki/${page.id}`),
    [navigate],
  );

  const onKeyDown = (e: React.KeyboardEvent) => {
    if (results.length === 0) return;
    if (e.key === "ArrowDown") {
      e.preventDefault();
      setSelected((i) => Math.min(i + 1, results.length - 1));
    } else if (e.key === "ArrowUp") {
      e.preventDefault();
      setSelected((i) => Math.max(i - 1, 0));
    } else if (e.key === "Enter") {
      e.preventDefault();
      const page = results[selected];
      if (page) open(page);
    }
  };

  const hasQuery = query.trim().length > 0;
  const status = loading
    ? "Searching…"
    : !hasQuery
      ? null
      : `${results.length} result${results.length === 1 ? "" : "s"}${truncated ? " (showing first matches — refine to narrow)" : ""}`;

  return (
    <div className="flex min-h-0 flex-col" onKeyDown={onKeyDown}>
      {/* SEARCH INPUT */}
      <div className="relative">
        <Search
          className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-[color:var(--color-text-tertiary)]"
          aria-hidden
        />
        {loading && (
          <Loader2 className="absolute right-3 top-1/2 size-4 -translate-y-1/2 animate-spin text-[color:var(--color-text-tertiary)]" aria-hidden />
        )}
        <Input
          type="search"
          autoFocus
          value={query}
          onChange={(e) => onQueryChange?.(e.currentTarget.value)}
          placeholder="Search the wiki…  (try tag:foo, title:bar)"
          aria-label="Search the wiki"
          className="h-10 pl-9 pr-9 text-[14px]"
        />
      </div>

      {/* STATUS LINE */}
      {status && (
        <div className="mt-2 px-1 text-[12px] text-[color:var(--color-text-tertiary)]">
          {status}
          {chips.length > 0 && !loading && (
            <span className="ml-2 inline-flex flex-wrap gap-1 align-middle">
              {chips.map((c) => (
                <Badge key={`c-${c}`} variant="outline" className="text-[11px]">
                  {c}
                </Badge>
              ))}
            </span>
          )}
        </div>
      )}

      {/* RESULTS / STATES */}
      <ScrollArea className="mt-3 min-h-0 flex-1">
        <div ref={listRef} className="flex flex-col gap-1 pb-6">
          {!hasQuery ? (
            <div className="px-2 py-10 text-center text-[13px] text-[color:var(--color-text-quaternary)]">
              Type to search your Memory Wiki.
            </div>
          ) : loading && results.length === 0 ? (
            <div className="px-2 py-10 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
              Searching…
            </div>
          ) : results.length === 0 ? (
            <div className="px-2 py-10 text-center text-[13px] text-[color:var(--color-text-quaternary)]">
              No results for{" "}
              <span className="text-[color:var(--color-text-secondary)]">“{ran || query}”</span>
            </div>
          ) : (
            results.map((p, i) => (
              <SearchResultCard
                key={p.id}
                page={p}
                terms={parsed.highlightTerms}
                selected={i === selected}
                onMouseEnter={() => setSelected(i)}
                onClick={() => open(p)}
              />
            ))
          )}
        </div>
      </ScrollArea>
    </div>
  );
}

interface CardProps {
  page: WikiPageSummary;
  terms: string[];
  selected: boolean;
  onMouseEnter: () => void;
  onClick: () => void;
}

function SearchResultCard({ page, terms, selected, onMouseEnter, onClick }: CardProps) {
  const ref = React.useRef<HTMLButtonElement>(null);
  React.useEffect(() => {
    if (selected) ref.current?.scrollIntoView({ block: "nearest" });
  }, [selected]);
  return (
    <button
      ref={ref}
      type="button"
      onClick={onClick}
      onMouseEnter={onMouseEnter}
      aria-selected={selected}
      className={cn(
        "group w-full rounded-md border border-transparent px-3 py-2.5 text-left transition-colors",
        "hover:bg-[color:var(--color-surface-hover)]",
        selected && "border-[color:var(--border)] bg-[color:var(--color-surface-hover)]",
      )}
    >
      <div className="flex items-center gap-2">
        <FileText className="size-4 shrink-0 text-[color:var(--color-text-tertiary)]" aria-hidden />
        <span className="min-w-0 flex-1 truncate text-[14px] font-medium text-foreground">
          {highlightMatch(page.title, terms)}
        </span>
        {page.source && (
          <Badge variant="outline" className="shrink-0 text-[11px]">
            {page.source}
          </Badge>
        )}
      </div>
      {page.excerpt && (
        <p className="mt-1 line-clamp-2 pl-6 text-[12px] leading-snug text-[color:var(--color-text-tertiary)]">
          {highlightMatch(page.excerpt, terms)}
        </p>
      )}
    </button>
  );
}
