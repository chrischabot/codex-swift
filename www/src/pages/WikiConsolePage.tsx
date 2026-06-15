import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Search, Sparkles, FileText, Gauge, Radio, Telescope, Download } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { WikiJobTab } from "./WikiJobTab";
import type { WikiPageSummary, WikiBrief, WikiStatus, WikiWatchSource } from "@/runtime/connector";

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

  const [status, setStatus] = useState<WikiStatus | null>(null);
  const [loadingStatus, setLoadingStatus] = useState(false);

  const [watch, setWatch] = useState<WikiWatchSource[] | null>(null);
  const [loadingWatch, setLoadingWatch] = useState(false);

  async function loadStatus() {
    if (!connector.getWikiStatus) return;
    setLoadingStatus(true);
    try {
      setStatus(await connector.getWikiStatus());
    } finally {
      setLoadingStatus(false);
    }
  }

  async function loadWatch() {
    if (!connector.getWikiWatch) return;
    setLoadingWatch(true);
    try {
      setWatch(await connector.getWikiWatch());
    } finally {
      setLoadingWatch(false);
    }
  }

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
        <Tabs
          defaultValue="search"
          className="mx-auto max-w-3xl"
          onValueChange={(v) => {
            if (v === "status" && !status) void loadStatus();
            if (v === "watch" && !watch) void loadWatch();
          }}
        >
          <TabsList>
            <TabsTrigger value="search"><Search className="mr-1 size-3.5" /> Search</TabsTrigger>
            <TabsTrigger value="brief"><Sparkles className="mr-1 size-3.5" /> Brief</TabsTrigger>
            <TabsTrigger value="research"><Telescope className="mr-1 size-3.5" /> Research</TabsTrigger>
            <TabsTrigger value="ingest"><Download className="mr-1 size-3.5" /> Ingest</TabsTrigger>
            <TabsTrigger value="status"><Gauge className="mr-1 size-3.5" /> Status</TabsTrigger>
            <TabsTrigger value="watch"><Radio className="mr-1 size-3.5" /> Watch</TabsTrigger>
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
                  onClick={() => navigate(`/wiki/${encodeURIComponent(r.id)}`)}
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

          {/* ── Research (live job) ── */}
          <TabsContent value="research">
            <WikiJobTab kind="research" />
          </TabsContent>

          {/* ── Ingest (live job) ── */}
          <TabsContent value="ingest">
            <WikiJobTab kind="ingest" />
          </TabsContent>

          {/* ── Status ── */}
          <TabsContent value="status" className="mt-3">
            <div className="mb-3 flex items-center gap-2">
              <Button variant="outline" size="xs" onClick={() => void loadStatus()} disabled={loadingStatus}>
                {loadingStatus ? "Refreshing…" : "Refresh"}
              </Button>
            </div>
            {status && (
              <>
                <div className="grid grid-cols-3 gap-3">
                  <Stat label="Raw documents" value={status.documents} />
                  <Stat label="Wiki pages" value={status.pages} />
                  <Stat label="Flagged stale" value={status.flaggedStale} />
                </div>
                <h4 className="mt-4 text-[12px] font-medium text-foreground">Recent ingest jobs</h4>
                {status.recentJobs.length === 0 ? (
                  <p className="mt-1 text-[12px] text-[color:var(--color-text-quaternary)]">No ingest jobs yet.</p>
                ) : (
                  <ul className="mt-1 space-y-1">
                    {status.recentJobs.map((j) => (
                      <li key={j.jobID} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                        <Badge variant={j.status === "failed" ? "danger" : j.status === "done" ? "success" : "outline"}>
                          {j.status}
                        </Badge>
                        <span className="truncate text-[12px] text-foreground">{j.input}</span>
                        <span className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                          w{j.written}/s{j.skipped}/f{j.failed}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </TabsContent>

          {/* ── Watch ── */}
          <TabsContent value="watch" className="mt-3">
            <div className="mb-3 flex items-center gap-2">
              <Button variant="outline" size="xs" onClick={() => void loadWatch()} disabled={loadingWatch}>
                {loadingWatch ? "Refreshing…" : "Refresh"}
              </Button>
              <span className="text-[12px] text-[color:var(--color-text-quaternary)]">
                register sources via <code>codex-memory wiki-watch add</code>
              </span>
            </div>
            {watch && (
              watch.length === 0 ? (
                <p className="text-[12px] text-[color:var(--color-text-quaternary)]">No watched sources.</p>
              ) : (
                <ul className="space-y-1">
                  {watch.map((w) => (
                    <li key={w.id} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                      <Badge variant={w.status === "error" ? "danger" : w.status === "active" ? "success" : "outline"}>
                        {w.status}
                      </Badge>
                      <Badge variant="outline">{w.cadence}</Badge>
                      <span className="truncate text-[12px] text-foreground">{w.id}</span>
                      <span className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                        {w.due ? "due now" : "scheduled"}
                      </span>
                    </li>
                  ))}
                </ul>
              )
            )}
          </TabsContent>
        </Tabs>
      </div>
    </div>
  );
}

function Stat({ label, value }: { label: string; value: number }) {
  return (
    <div className="rounded-md border border-[color:var(--border)] p-3">
      <div className="text-[20px] font-semibold tabular-nums text-foreground">{value.toLocaleString()}</div>
      <div className="text-[11px] text-[color:var(--color-text-quaternary)]">{label}</div>
    </div>
  );
}
