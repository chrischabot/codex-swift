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

interface Props {
  /** The active query — typically driven from the `?q=` search param. */
  query: string;
  /** Notify the host of edits so it can mirror the query into the URL (?q=). */
  onQueryChange?: (q: string) => void;
}

const DEBOUNCE_MS = 200;
const SEARCH_LIMIT = 50;

// ── Client-side operator parsing ─────────────────────────────────────────────
// The backend search is lexical BM25 with no operator grammar, so `tag:`/`title:`
// operators are parsed here and applied as a best-effort filter over the
// returned summaries. Bare terms become the full-text query sent to searchWiki.
interface ParsedQuery {
  /** What we send to searchWiki — the bare (non-operator) terms joined. */
  fullText: string;
  /** Individual bare terms, used to highlight matches in excerpts. */
  terms: string[];
  /** `tag:foo` — result must mention `#foo` or the word `foo` in title/excerpt. */
  tags: string[];
  /** `title:foo` — result title must contain `foo` (case-insensitive). */
  titles: string[];
}

function parseQuery(raw: string): ParsedQuery {
  const tags: string[] = [];
  const titles: string[] = [];
  const bare: string[] = [];
  // Split on whitespace; quoted segments are rare in this surface so we keep it
  // simple and treat each token independently.
  for (const tok of raw.trim().split(/\s+/).filter(Boolean)) {
    const lower = tok.toLowerCase();
    if (lower.startsWith("tag:") && tok.length > 4) {
      tags.push(tok.slice(4).replace(/^#/, ""));
    } else if (lower.startsWith("title:") && tok.length > 6) {
      titles.push(tok.slice(6));
    } else if (tok.startsWith("#") && tok.length > 1) {
      // A bare `#foo` token is PURE tag sugar (matches M1 tag links which
      // navigate to ?q=#foo) — it filters the corpus; it is NOT sent to BM25 and
      // does not become a highlight term (the operator-only path lists pages).
      tags.push(tok.slice(1));
    } else {
      bare.push(tok);
    }
  }
  return { fullText: bare.join(" ").trim(), terms: bare, tags, titles };
}

/** Word-boundary test for a term within a haystack (avoids `cat` matching
 *  `category`). The term is regex-escaped first. */
function mentionsWord(hay: string, term: string): boolean {
  const esc = term.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
  return new RegExp(`(^|[^\\w#])${esc}([^\\w]|$)`, "i").test(hay);
}

/** Does a summary satisfy the parsed `tag:`/`title:` filters? */
function matchesFilters(p: WikiPageSummary, parsed: ParsedQuery): boolean {
  const hay = `${p.title} ${p.excerpt ?? ""}`;
  for (const t of parsed.titles) {
    if (!p.title.toLowerCase().includes(t.toLowerCase())) return false;
  }
  for (const tag of parsed.tags) {
    // A literal `#tag`, or the bare WORD (not a substring) in title/excerpt.
    if (!hay.toLowerCase().includes(`#${tag.toLowerCase()}`) && !mentionsWord(hay, tag)) return false;
  }
  return true;
}

interface SearchState {
  results: WikiPageSummary[];
  loading: boolean;
  /** The full-text query that produced `results` (drives the empty-state copy). */
  ran: string;
}

/**
 * Self-contained debounced search hook. Mirrors the `state/wiki.ts` pattern
 * (keyed on `status.kind === "connected"`, guards the optional connector
 * method) but kept local so the integrator mounts WikiSearchView without
 * touching shared state. The `tag:`/`title:` filters are applied client-side;
 * only the bare full-text is sent over the wire.
 */
function useWikiSearch(query: string): SearchState {
  const { connector, status } = useRuntime();
  const [state, setState] = React.useState<SearchState>({ results: [], loading: false, ran: "" });
  const connected = status.kind === "connected";
  const parsed = React.useMemo(() => parseQuery(query), [query]);

  React.useEffect(() => {
    const { fullText, tags, titles } = parsed;
    const hasQuery = fullText.length > 0 || tags.length > 0 || titles.length > 0;
    if (!hasQuery) {
      setState({ results: [], loading: false, ran: "" });
      return;
    }
    if (!connector.searchWiki || !connected) {
      setState({ results: [], loading: false, ran: query });
      return;
    }
    let alive = true;
    setState((s) => ({ ...s, loading: true }));
    const handle = setTimeout(() => {
      // If there are only operators (no bare terms) we still need a corpus to
      // filter, so fall back to listing recent pages.
      const fetcher =
        fullText.length > 0
          ? connector.searchWiki!(fullText, { limit: SEARCH_LIMIT })
          : connector.listWikiPages
            ? connector.listWikiPages({ limit: SEARCH_LIMIT })
            : Promise.resolve<WikiPageSummary[]>([]);
      fetcher
        .then((rows) => {
          if (!alive) return;
          const filtered = rows.filter((r) => matchesFilters(r, parsed));
          setState({ results: filtered, loading: false, ran: query });
        })
        .catch(() => {
          if (alive) setState({ results: [], loading: false, ran: query });
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
  const parsed = React.useMemo(() => parseQuery(query), [query]);
  const { results, loading, ran } = useWikiSearch(query);
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
      : `${results.length} result${results.length === 1 ? "" : "s"}`;

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
          {(parsed.tags.length > 0 || parsed.titles.length > 0) && !loading && (
            <span className="ml-2 inline-flex flex-wrap gap-1 align-middle">
              {parsed.titles.map((t) => (
                <Badge key={`t-${t}`} variant="outline" className="text-[11px]">
                  title:{t}
                </Badge>
              ))}
              {parsed.tags.map((t) => (
                <Badge key={`g-${t}`} variant="outline" className="text-[11px]">
                  #{t}
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
                terms={parsed.terms}
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
