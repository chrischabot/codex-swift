import * as React from "react";
import { useNavigate } from "react-router-dom";
import { ChevronRight, ArrowUpRight, ArrowDownLeft, Link2Off } from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage, WikiPageSummary } from "@/runtime/connector";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible";
import { Badge } from "@/components/ui/badge";
import { cn } from "@/lib/utils";
import { useWikiMetadataIndex } from "../useWikiMetadataIndex";
import { useWikiLinkIndex, backlinksOf } from "../useWikiLinkIndex";
import { maskFencedCode } from "../markdown/codeFences";

// Granite ports BacklinksView + OutgoingLinksView + unlinked-mentions into a
// single right-rail panel. As of M26 BACKLINKS are exact and vault-wide: the
// `wiki/index` link index gives every page's outgoing `[[wikilinks]]`, and we
// reverse it (resolving title→id via the metadata index) so a backlink is a
// page that ACTUALLY links here — no excerpt heuristic, no 80-hit search cap.
// UNLINKED MENTIONS still need a full-text search (the index has no body text),
// so they stay search-derived, minus any page already counted as a backlink.
// All link parsing matches the wiki dialect ([[Target]], [[Target|Display]],
// [[Target#Heading]], ![[Embed]]).

interface Props {
  page: WikiPage;
  /** Optional navigation override. Defaults to react-router → /wiki/<id>. */
  onOpenPage?: (id: string) => void;
  /** Bumps when a page is saved/renamed/deleted → refreshes the link index. */
  dataVersion?: number;
}

const DEBOUNCE_MS = 250;
const SEARCH_LIMIT = 80;

// ── Wikilink parsing ────────────────────────────────────────────────────────

interface ParsedWikilink {
  /** The link target as written (before "|", "#", "^"), trimmed. */
  target: string;
  /** Display text (alias after "|"), or the target if none. */
  display: string;
  /** True for transclusions `![[…]]`. */
  embed: boolean;
  /** Zero-based source line. */
  line: number;
}

// Matches [[Target]], [[Target|Display]], [[Target#Heading|Display]], ![[Embed]].
const WIKILINK_RE = /(!?)\[\[([^\]|#^]+)(?:[#^][^\]|]*)?(?:\|([^\]]+))?\]\]/g;

/** Mask fenced code blocks (``` / ~~~) and inline code spans so wikilinks and
 *  plain-text mentions inside code aren't treated as links/mentions. Delegates
 *  to the shared length-preserving masker (line numbers survive). */
function maskCode(content: string): string[] {
  return maskFencedCode(content); // inline code blanked by default
}

/** Parse every wikilink out of `content`, skipping fenced/inline code. */
function parseWikilinks(content: string): ParsedWikilink[] {
  const lines = maskCode(content);
  const out: ParsedWikilink[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Cheap prefilter + length cap so a pathological single long line can't
    // drive the regex into O(n^2) backtracking.
    if (!line.includes("[[") || line.length > 20000) continue;
    WIKILINK_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = WIKILINK_RE.exec(line)) !== null) {
      const target = (m[2] ?? "").trim();
      if (!target) continue;
      out.push({
        target,
        display: (m[3] ?? target).trim(),
        embed: m[1] === "!",
        line: i,
      });
    }
  }
  return out;
}

const WORD_CHAR_RE = /[A-Za-z0-9_]/;

/** Normalize a title/target for loose matching (case-insensitive, trimmed). */
function norm(s: string): string {
  return s.trim().toLowerCase();
}

interface MentionMatch {
  /** Zero-based line number. */
  line: number;
  /** Trimmed line preview (≤200 chars). */
  preview: string;
}

/**
 * Find plain-text mentions of `title` in `content` that are NOT already wrapped
 * in a wikilink, are NOT inside code, and fall on word boundaries (so "API"
 * doesn't match "APIs"). One match per line, capped. Mirrors granite's
 * findUnlinkedMentionsInText.
 */
function findUnlinkedMentions(content: string, title: string, max = 5): MentionMatch[] {
  const needle = norm(title);
  if (!needle) return [];
  const lines = maskCode(content);
  const out: MentionMatch[] = [];
  for (let i = 0; i < lines.length && out.length < max; i++) {
    const line = lines[i];
    const haystack = line.toLowerCase();
    let pos = 0;
    let found = false;
    while (pos < haystack.length) {
      const idx = haystack.indexOf(needle, pos);
      if (idx === -1) break;
      const end = idx + needle.length;
      const before = idx > 0 ? line[idx - 1] : "";
      const after = end < line.length ? line[end] : "";
      if ((before && WORD_CHAR_RE.test(before)) || (after && WORD_CHAR_RE.test(after))) {
        pos = idx + 1;
        continue;
      }
      // Inside an unclosed "[[" on this line? → it's a wikilink, not unlinked.
      const beforeText = line.substring(0, idx);
      if (beforeText.lastIndexOf("[[") > beforeText.lastIndexOf("]]")) {
        pos = idx + 1;
        continue;
      }
      found = true;
      break;
    }
    if (found) out.push({ line: i, preview: line.trim().slice(0, 200) });
  }
  return out;
}

// ── View-model types ────────────────────────────────────────────────────────

interface BacklinkVM {
  page: WikiPageSummary;
  /** Snippet context (excerpt, since the connector returns no full body here). */
  snippet?: string;
}

interface OutgoingVM {
  link: ParsedWikilink;
  /** Resolved target page, or null when unresolved. */
  resolved: WikiPageSummary | null;
}

interface UnlinkedVM {
  page: WikiPageSummary;
  matches: MentionMatch[];
}

// ── Section primitives ───────────────────────────────────────────────────────

interface SectionProps {
  icon: React.ReactNode;
  title: string;
  count: number;
  defaultOpen?: boolean;
  loading?: boolean;
  children: React.ReactNode;
}

function Section({ icon, title, count, defaultOpen, loading, children }: SectionProps) {
  const [open, setOpen] = React.useState(defaultOpen ?? false);
  return (
    <Collapsible open={open} onOpenChange={setOpen} className="border-b border-[color:var(--color-border)]">
      <CollapsibleTrigger
        className={cn(
          "group flex w-full items-center gap-2 px-3 py-2 text-left",
          "text-sm font-semibold uppercase tracking-[0.05em]",
          "text-[color:var(--color-text-tertiary)]",
          "hover:text-foreground",
        )}
      >
        <ChevronRight
          className="size-3.5 shrink-0 transition-transform duration-150 group-data-[state=open]:rotate-90"
          aria-hidden
        />
        <span className="flex shrink-0 items-center text-[color:var(--color-text-quaternary)]" aria-hidden>
          {icon}
        </span>
        <span className="min-w-0 flex-1 truncate">{title}</span>
        <span className="shrink-0 font-normal text-[color:var(--color-text-quaternary)]">
          {loading ? "…" : count}
        </span>
      </CollapsibleTrigger>
      <CollapsibleContent>
        <div className="pb-2">{children}</div>
      </CollapsibleContent>
    </Collapsible>
  );
}

function EmptyRow({ children }: { children: React.ReactNode }) {
  return (
    <div className="px-3 py-2 text-sm text-[color:var(--color-text-quaternary)]">{children}</div>
  );
}

interface RowProps {
  title: string;
  meta?: React.ReactNode;
  snippet?: string;
  interactive?: boolean;
  onOpen?: () => void;
}

function Row({ title, meta, snippet, interactive = true, onOpen }: RowProps) {
  return (
    <button
      type="button"
      disabled={!interactive}
      onClick={interactive ? onOpen : undefined}
      title={title}
      className={cn(
        "group flex w-full flex-col gap-0.5 px-3 py-1.5 text-left",
        interactive && "cursor-pointer hover:bg-[color:var(--color-surface-hover)]",
        !interactive && "opacity-70",
      )}
    >
      <span className="flex w-full items-center justify-between gap-2">
        <span
          className={cn(
            "min-w-0 truncate text-md text-foreground",
            interactive && "group-hover:text-[color:var(--text-link)]",
          )}
        >
          {title}
        </span>
        {meta ? <span className="shrink-0">{meta}</span> : null}
      </span>
      {snippet ? (
        <span className="line-clamp-2 text-sm text-[color:var(--color-text-tertiary)]">
          {snippet}
        </span>
      ) : null}
    </button>
  );
}

// ── Panel ─────────────────────────────────────────────────────────────────

export function WikiBacklinksPanel({ page, onOpenPage, dataVersion = 0 }: Props) {
  const navigate = useNavigate();
  const { connector, status } = useRuntime();
  const connected = status.kind === "connected";

  const open = React.useCallback(
    (id: string) => {
      if (onOpenPage) onOpenPage(id);
      else navigate(`/wiki/${id}`);
    },
    [onOpenPage, navigate],
  );

  // Shared vault indexes: titles (→ id resolution) and the body link graph.
  const { pages: allPages, resolve, byId } = useWikiMetadataIndex(dataVersion);
  const { entries: linkEntries, loading: indexLoading } = useWikiLinkIndex(dataVersion);

  // OUTGOING — parse this page's body, resolve targets against the title index.
  const outgoingLinks = React.useMemo(() => parseWikilinks(page.content), [page.content]);

  const outgoing = React.useMemo<OutgoingVM[]>(() => {
    const byTitle = new Map<string, WikiPageSummary>();
    for (const p of allPages) byTitle.set(norm(p.title), p);
    // De-dupe by target so repeated links to the same page collapse to one row.
    const seen = new Set<string>();
    const out: OutgoingVM[] = [];
    for (const link of outgoingLinks) {
      const key = norm(link.target);
      if (seen.has(key)) continue;
      seen.add(key);
      out.push({ link, resolved: byTitle.get(key) ?? null });
    }
    return out;
  }, [outgoingLinks, allPages]);

  // BACKLINKS — exact, vault-wide: reverse the link index resolved via titles.
  const backlinks = React.useMemo<BacklinkVM[]>(() => {
    return backlinksOf(linkEntries, page.id, resolve).map((b) => {
      const summary = byId.get(b.id);
      return {
        page: summary ?? { id: b.id, title: b.title },
        snippet: summary?.excerpt,
      };
    });
  }, [linkEntries, page.id, resolve, byId]);
  // Ids already linking here → excluded from "unlinked mentions".
  const backlinkIds = React.useMemo(
    () => new Set(backlinks.map((b) => b.page.id)),
    [backlinks],
  );

  // UNLINKED MENTIONS — debounced full-text search on the (quoted) title; a hit
  // is "unlinked" when it mentions the title as plain text but is NOT already an
  // index backlink. (Backlinks themselves no longer come from search.)
  const title = page.title;
  const [search, setSearch] = React.useState<{
    results: WikiPageSummary[];
    loading: boolean;
    ran: boolean;
  }>({ results: [], loading: false, ran: false });

  React.useEffect(() => {
    if (!connected || !connector.searchWiki || !title.trim()) {
      setSearch({ results: [], loading: false, ran: false });
      return;
    }
    let alive = true;
    setSearch((s) => ({ ...s, loading: true }));
    const handle = window.setTimeout(() => {
      // Escape `"` so a title with a quote can't break the FTS phrase query.
      const phrase = `"${title.replace(/"/g, " ")}"`;
      connector
        .searchWiki!(phrase, { limit: SEARCH_LIMIT })
        .then((r) => alive && setSearch({ results: r, loading: false, ran: true }))
        .catch(() => alive && setSearch({ results: [], loading: false, ran: true }));
    }, DEBOUNCE_MS);
    return () => {
      alive = false;
      window.clearTimeout(handle);
    };
  }, [connector, connected, title]);

  // Unlinked mentions: a search hit that mentions the title as plain text, is
  // not self, and is NOT already an index backlink (those would be "linked").
  const unlinked = React.useMemo<UnlinkedVM[]>(() => {
    const un: UnlinkedVM[] = [];
    for (const r of search.results) {
      if (r.id === page.id || norm(r.title) === norm(title)) continue;
      if (backlinkIds.has(r.id)) continue;
      const matches = findUnlinkedMentions(r.excerpt ?? "", title);
      if (matches.length > 0) un.push({ page: r, matches });
    }
    return un;
  }, [search.results, page.id, title, backlinkIds]);

  return (
    <div className="flex flex-col">
      <Section
        icon={<ArrowDownLeft className="size-3.5" />}
        title="Backlinks"
        count={backlinks.length}
        defaultOpen
        loading={indexLoading}
      >
        {indexLoading && backlinks.length === 0 ? (
          <EmptyRow>Loading…</EmptyRow>
        ) : backlinks.length === 0 ? (
          <EmptyRow>No backlinks</EmptyRow>
        ) : (
          backlinks.map((b) => (
            <Row
              key={b.page.id}
              title={b.page.title}
              snippet={b.snippet}
              onOpen={() => open(b.page.id)}
            />
          ))
        )}
      </Section>

      <Section
        icon={<ArrowUpRight className="size-3.5" />}
        title="Outgoing links"
        count={outgoing.length}
        defaultOpen
      >
        {outgoing.length === 0 ? (
          <EmptyRow>No outgoing links</EmptyRow>
        ) : (
          outgoing.map((o) => {
            const label = `${o.link.embed ? "↳ " : ""}${o.link.display}`;
            return (
              <Row
                key={`${norm(o.link.target)}:${o.link.line}`}
                title={label}
                interactive={Boolean(o.resolved)}
                onOpen={o.resolved ? () => open(o.resolved!.id) : undefined}
                meta={
                  o.resolved ? (
                    o.link.embed ? (
                      <Badge variant="outline" className="px-1.5 py-0.5 text-sm">
                        embed
                      </Badge>
                    ) : null
                  ) : (
                    <Badge variant="outline" className="px-1.5 py-0.5 text-sm text-[color:var(--color-text-quaternary)]">
                      unresolved
                    </Badge>
                  )
                }
              />
            );
          })
        )}
      </Section>

      <Section
        icon={<Link2Off className="size-3.5" />}
        title="Unlinked mentions"
        count={unlinked.length}
        loading={search.loading}
      >
        {search.loading && !search.ran ? (
          <EmptyRow>Scanning…</EmptyRow>
        ) : unlinked.length === 0 ? (
          <EmptyRow>No unlinked mentions</EmptyRow>
        ) : (
          unlinked.map((u) => (
            <Row
              key={u.page.id}
              title={u.page.title}
              snippet={u.matches[0]?.preview ?? u.page.excerpt}
              meta={
                u.matches.length > 1 ? (
                  <span className="text-sm text-[color:var(--color-text-quaternary)]">
                    {u.matches.length}
                  </span>
                ) : null
              }
              onOpen={() => open(u.page.id)}
            />
          ))
        )}
      </Section>
    </div>
  );
}
