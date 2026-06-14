import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Search, Sparkles, FileText } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPageSummary, WikiBrief } from "@/runtime/connector";

/**
 * Wiki Console (route /wiki/console) — query the knowledge base and generate a
 * cited synthesis brief, the two read surfaces over the Memory Wiki. Search uses
 * `wiki/search` (hybrid retrieval); Brief uses `wiki/brief` (lexical, zero-spend
 * cited synthesis). Both go through the connector boundary.
 */
export function WikiConsolePage() {
  const { connector } = useRuntime();
  const navigate = useNavigate();

  const [q, setQ] = useState("");
  const [results, setResults] = useState<WikiPageSummary[] | null>(null);
  const [searching, setSearching] = useState(false);

  const [topic, setTopic] = useState("");
  const [brief, setBrief] = useState<WikiBrief | null>(null);
  const [briefing, setBriefing] = useState(false);
  const [briefError, setBriefError] = useState<string | null>(null);

  async function runSearch() {
    const query = q.trim();
    if (!query || !connector.searchWiki) return;
    setSearching(true);
    try {
      setResults(await connector.searchWiki(query, { limit: 25 }));
    } catch {
      setResults([]);
    } finally {
      setSearching(false);
    }
  }

  async function runBrief() {
    const t = topic.trim();
    if (!t || !connector.getWikiBrief) return;
    setBriefing(true);
    setBriefError(null);
    try {
      const b = await connector.getWikiBrief(t, { k: 8 });
      setBrief(b);
      if (!b) setBriefError("No brief returned.");
    } catch (e) {
      setBriefError(String(e));
    } finally {
      setBriefing(false);
    }
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex shrink-0 items-center gap-2 border-b border-[color:var(--border)] px-4 py-2">
        <Button variant="ghost" size="iconSm" onClick={() => navigate("/wiki")} aria-label="Back to wiki">
          <ArrowLeft />
        </Button>
        <span className="text-[13px] font-medium text-foreground">Console</span>
        <span className="text-[12px] text-[color:var(--color-text-quaternary)]">query + synthesize</span>
      </div>

      <div className="min-h-0 flex-1 overflow-auto p-4">
        <Tabs defaultValue="search" className="mx-auto max-w-3xl">
          <TabsList>
            <TabsTrigger value="search"><Search className="mr-1 size-3.5" /> Search</TabsTrigger>
            <TabsTrigger value="brief"><Sparkles className="mr-1 size-3.5" /> Brief</TabsTrigger>
          </TabsList>

          {/* ── Search ── */}
          <TabsContent value="search" className="mt-3">
            <form
              className="flex gap-2"
              onSubmit={(e) => { e.preventDefault(); void runSearch(); }}
            >
              <Input
                value={q}
                onChange={(e) => setQ(e.target.value)}
                placeholder="Search the knowledge base…"
                aria-label="Search query"
              />
              <Button type="submit" disabled={searching || !q.trim()}>
                {searching ? "Searching…" : "Search"}
              </Button>
            </form>
            <div className="mt-3 space-y-2">
              {results?.length === 0 && (
                <p className="text-[13px] text-[color:var(--color-text-quaternary)]">No matches.</p>
              )}
              {results?.map((r) => (
                <button
                  key={r.id}
                  onClick={() => navigate(`/wiki?page=${encodeURIComponent(r.id)}`)}
                  className="block w-full rounded-md border border-[color:var(--border)] p-3 text-left hover:bg-[color:var(--muted)]"
                >
                  <div className="flex items-center gap-2">
                    <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" />
                    <span className="truncate text-[13px] font-medium text-foreground">{r.title}</span>
                    {r.source && <Badge variant="outline" className="ml-auto shrink-0">{r.source}</Badge>}
                  </div>
                  {r.excerpt && (
                    <p className="mt-1 line-clamp-2 text-[12px] text-[color:var(--color-text-secondary)]">
                      {r.excerpt}
                    </p>
                  )}
                </button>
              ))}
            </div>
          </TabsContent>

          {/* ── Brief ── */}
          <TabsContent value="brief" className="mt-3">
            <form
              className="flex gap-2"
              onSubmit={(e) => { e.preventDefault(); void runBrief(); }}
            >
              <Input
                value={topic}
                onChange={(e) => setTopic(e.target.value)}
                placeholder="Topic to synthesize a cited brief on…"
                aria-label="Brief topic"
              />
              <Button type="submit" disabled={briefing || !topic.trim()}>
                {briefing ? "Synthesizing…" : "Brief"}
              </Button>
            </form>
            {briefError && (
              <p className="mt-3 text-[13px] text-[color:var(--destructive)]">{briefError}</p>
            )}
            {brief && (
              <div className="mt-3 space-y-3 rounded-md border border-[color:var(--border)] p-4">
                <div className="flex items-center gap-2">
                  <span className="text-[13px] font-medium text-foreground">{brief.topic ?? topic}</span>
                  {brief.confidence && <Badge variant="outline">confidence: {brief.confidence}</Badge>}
                </div>
                {brief.summary && (
                  <p className="text-[13px] leading-relaxed text-[color:var(--color-text-secondary)]">
                    {brief.summary}
                  </p>
                )}
                {!!brief.key_points?.length && (
                  <div>
                    <h4 className="text-[12px] font-medium text-foreground">Key points</h4>
                    <ul className="mt-1 list-disc space-y-1 pl-5">
                      {brief.key_points.map((p, i) => (
                        <li key={i} className="text-[12px] text-[color:var(--color-text-secondary)]">
                          {p.text}
                          {!!p.citation_ids.length && (
                            <span className="ml-1 text-[color:var(--color-text-quaternary)]">
                              [{p.citation_ids.join(", ")}]
                            </span>
                          )}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
                {!!brief.citations?.length && (
                  <div>
                    <h4 className="text-[12px] font-medium text-foreground">Citations</h4>
                    <ul className="mt-1 space-y-1">
                      {brief.citations.map((c) => (
                        <li key={c.id} className="text-[11px] text-[color:var(--color-text-quaternary)]">
                          <span className="font-mono">[{c.id}]</span> {c.doc_uri}
                        </li>
                      ))}
                    </ul>
                  </div>
                )}
              </div>
            )}
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
}
