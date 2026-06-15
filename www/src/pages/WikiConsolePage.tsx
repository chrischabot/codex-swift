import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Search, Sparkles, FileText, Gauge, Radio, Telescope, Download, ShieldAlert, Boxes, Database, Images, Layers, History } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Tabs, TabsList, TabsTrigger, TabsContent } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { WikiJobTab } from "./WikiJobTab";
import type { WikiPageSummary, WikiBrief, WikiStatus, WikiWatchSource, WikiLibrarianReport, WikiAuditReport,
  WikiInventoryRecord, WikiDatasetManifest, WikiCollectCatalog, WikiQueryResult, WikiResearchSession } from "@/runtime/connector";

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

  const [librarian, setLibrarian] = useState<WikiLibrarianReport | null>(null);
  const [audit, setAudit] = useState<WikiAuditReport | null>(null);
  const [loadingReports, setLoadingReports] = useState(false);
  const [reportsLoaded, setReportsLoaded] = useState(false);

  async function loadReports() {
    setLoadingReports(true);
    // allSettled → the two reads are independent: one failing (or a connector that
    // rejects) never blocks the other and never wedges the tab at null.
    const [lib, aud] = await Promise.allSettled([
      connector.getLibrarianReport?.() ?? Promise.resolve(null),
      connector.getAuditReport?.() ?? Promise.resolve(null),
    ]);
    setLibrarian(lib.status === "fulfilled" ? lib.value : null);
    setAudit(aud.status === "fulfilled" ? aud.value : null);
    setReportsLoaded(true);
    setLoadingReports(false);
  }

  const [inventory, setInventory] = useState<WikiInventoryRecord[]>([]);
  const [datasets, setDatasets] = useState<WikiDatasetManifest[]>([]);
  const [catalogs, setCatalogs] = useState<WikiCollectCatalog[]>([]);
  const [curationLoaded, setCurationLoaded] = useState(false);

  async function loadCuration() {
    const [inv, ds, col] = await Promise.allSettled([
      connector.getWikiInventory?.() ?? Promise.resolve([]),
      connector.getWikiDatasets?.() ?? Promise.resolve([]),
      connector.getWikiCollect?.() ?? Promise.resolve([]),
    ]);
    if (inv.status === "fulfilled") setInventory(inv.value);
    if (ds.status === "fulfilled") setDatasets(ds.value);
    if (col.status === "fulfilled") setCatalogs(col.value);
    setCurationLoaded(true);
  }

  // Query (depth-tiered wiki/query) — quick(1) / standard(2) / deep(3).
  const [qq, setQq] = useState("");
  const [depth, setDepth] = useState(2);
  const [queryResult, setQueryResult] = useState<WikiQueryResult | null>(null);
  const [querying, setQuerying] = useState(false);

  async function runQuery() {
    const query = qq.trim();
    if (!query || !connector.queryWiki) return;
    setQuerying(true);
    try {
      setQueryResult(await connector.queryWiki(query, { depth, k: 25 }));
    } catch {
      setQueryResult(null);
    } finally {
      setQuerying(false);
    }
  }

  // Sessions (research_session history) — lazy on first tab open.
  const [sessions, setSessions] = useState<WikiResearchSession[]>([]);
  const [sessionsLoaded, setSessionsLoaded] = useState(false);
  const [loadingSessions, setLoadingSessions] = useState(false);

  async function loadSessions() {
    if (!connector.getWikiSessions) { setSessionsLoaded(true); return; }
    setLoadingSessions(true);
    try {
      setSessions(await connector.getWikiSessions());
    } finally {
      setSessionsLoaded(true);
      setLoadingSessions(false);
    }
  }

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
            if (v === "reports" && !reportsLoaded) void loadReports();
            if ((v === "inventory" || v === "datasets" || v === "collect") && !curationLoaded) void loadCuration();
            if (v === "sessions" && !sessionsLoaded) void loadSessions();
          }}
        >
          <TabsList>
            <TabsTrigger value="search"><Search className="mr-1 size-3.5" /> Search</TabsTrigger>
            <TabsTrigger value="query"><Layers className="mr-1 size-3.5" /> Query</TabsTrigger>
            <TabsTrigger value="brief"><Sparkles className="mr-1 size-3.5" /> Brief</TabsTrigger>
            <TabsTrigger value="research"><Telescope className="mr-1 size-3.5" /> Research</TabsTrigger>
            <TabsTrigger value="sessions"><History className="mr-1 size-3.5" /> Sessions</TabsTrigger>
            <TabsTrigger value="ingest"><Download className="mr-1 size-3.5" /> Ingest</TabsTrigger>
            <TabsTrigger value="status"><Gauge className="mr-1 size-3.5" /> Status</TabsTrigger>
            <TabsTrigger value="watch"><Radio className="mr-1 size-3.5" /> Watch</TabsTrigger>
            <TabsTrigger value="reports"><ShieldAlert className="mr-1 size-3.5" /> Reports</TabsTrigger>
            <TabsTrigger value="inventory"><Boxes className="mr-1 size-3.5" /> Inventory</TabsTrigger>
            <TabsTrigger value="datasets"><Database className="mr-1 size-3.5" /> Datasets</TabsTrigger>
            <TabsTrigger value="collect"><Images className="mr-1 size-3.5" /> Collect</TabsTrigger>
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

          {/* ── Query (depth-tiered wiki/query) ── */}
          <TabsContent value="query" className="mt-3">
            <form
              className="flex flex-wrap gap-2"
              onSubmit={(e) => { e.preventDefault(); void runQuery(); }}
            >
              <Input
                value={qq}
                onChange={(e) => setQq(e.target.value)}
                placeholder="Depth-tiered hybrid retrieval…"
                aria-label="Knowledge query"
                className="min-w-[16rem] flex-1"
              />
              <div className="flex overflow-hidden rounded-md border border-[color:var(--border)]" role="group" aria-label="Retrieval depth">
                {[{ d: 1, l: "Quick" }, { d: 2, l: "Standard" }, { d: 3, l: "Deep" }].map(({ d, l }) => (
                  <button
                    key={d}
                    type="button"
                    onClick={() => setDepth(d)}
                    aria-pressed={depth === d}
                    className={`px-2.5 py-1 text-[12px] ${depth === d ? "bg-[color:var(--primary)] text-[color:var(--primary-foreground)]" : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--muted)]"}`}
                  >
                    {l}
                  </button>
                ))}
              </div>
              <Button type="submit" disabled={querying || !qq.trim()}>
                {querying ? "Querying…" : "Query"}
              </Button>
            </form>
            {queryResult && (
              <div className="mt-3">
                <div className="mb-2 flex items-center gap-2 text-[11px] text-[color:var(--color-text-quaternary)]">
                  <Badge variant="outline">depth {queryResult.depth}</Badge>
                  <Badge variant={queryResult.retrieval === "hybrid" ? "success" : "outline"}>{queryResult.retrieval}</Badge>
                  <span>{queryResult.hits.length} hit(s)</span>
                </div>
                {queryResult.hits.length === 0 ? (
                  <p className="text-[13px] text-[color:var(--color-text-quaternary)]">No matches.</p>
                ) : (
                  <div className="space-y-2">
                    {queryResult.hits.map((h) => (
                      <button
                        key={h.id}
                        onClick={() => navigate(`/wiki/${encodeURIComponent(h.id)}`)}
                        className="block w-full rounded-md border border-[color:var(--border)] p-3 text-left hover:bg-[color:var(--muted)]"
                      >
                        <div className="flex items-center gap-2">
                          <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-quaternary)]" />
                          <span className="truncate text-[13px] font-medium text-foreground">{h.title}</span>
                          {h.score != null && (
                            <span className="ml-auto shrink-0 font-mono text-[11px] tabular-nums text-[color:var(--color-text-quaternary)]">
                              {h.score.toFixed(2)}
                            </span>
                          )}
                        </div>
                        {h.excerpt && (
                          <p className="mt-1 line-clamp-2 text-[12px] text-[color:var(--color-text-secondary)]">{h.excerpt}</p>
                        )}
                        {h.why && (
                          <p className="mt-1 font-mono text-[10px] text-[color:var(--color-text-quaternary)]">
                            bm25 {h.why.bm25.toFixed(2)} · vec {h.why.vec.toFixed(2)} · rerank {h.why.rerank.toFixed(2)}
                          </p>
                        )}
                      </button>
                    ))}
                  </div>
                )}
              </div>
            )}
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

          {/* ── Sessions (research_session history) ── */}
          <TabsContent value="sessions" className="mt-3">
            <div className="mb-2 flex items-center gap-2">
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">
                deep-research runs — topic / progress / coverage
              </p>
              <Button variant="outline" size="xs" className="ml-auto" onClick={() => void loadSessions()} disabled={loadingSessions}>
                {loadingSessions ? "Refreshing…" : "Refresh"}
              </Button>
            </div>
            {sessionsLoaded && sessions.length === 0 ? (
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">No research sessions yet.</p>
            ) : (
              <ul className="space-y-1">
                {sessions.map((s) => (
                  <li key={s.sessionID} className="rounded-md border border-[color:var(--border)] px-3 py-2">
                    <div className="flex items-center gap-2">
                      {s.mode && <Badge variant="outline">{s.mode}</Badge>}
                      {s.status && (
                        <Badge variant={s.status === "complete" ? "success" : s.status === "failed" ? "danger" : "outline"}>
                          {s.status}
                        </Badge>
                      )}
                      <span className="truncate text-[12px] font-medium text-foreground">{s.topic ?? s.sessionID}</span>
                      {s.score != null && (
                        <span className="ml-auto shrink-0 font-mono text-[11px] tabular-nums text-[color:var(--color-text-quaternary)]">
                          {s.score.toFixed(2)}
                        </span>
                      )}
                    </div>
                    <div className="mt-1 flex items-center gap-3 text-[11px] text-[color:var(--color-text-quaternary)]">
                      {s.rounds != null && <span>{s.rounds} round(s)</span>}
                      {s.sources != null && <span>{s.sources} source(s)</span>}
                      {s.articles != null && <span>{s.articles} article(s)</span>}
                      {s.startedAt != null && <span className="ml-auto">{new Date(s.startedAt).toLocaleDateString()}</span>}
                    </div>
                  </li>
                ))}
              </ul>
            )}
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

          {/* ── Reports (Librarian Tier-1 staleness + Audit Pass-2 drift) ── */}
          <TabsContent value="reports" className="mt-3">
            <div className="mb-3 flex items-center gap-2">
              <Button variant="outline" size="xs" onClick={() => void loadReports()} disabled={loadingReports}>
                {loadingReports ? "Refreshing…" : "Refresh"}
              </Button>
              <span className="text-[12px] text-[color:var(--color-text-quaternary)]">
                trust scans — staleness + output-drift (read-only)
              </span>
            </div>
            {reportsLoaded && !librarian && !audit && (
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">
                Could not load reports — is the memory wiki enabled (CODEXKIT_MEMORY)?
              </p>
            )}
            {librarian && (
              <>
                <h4 className="text-[12px] font-medium text-foreground">Librarian — staleness</h4>
                <div className="mt-1 grid grid-cols-3 gap-3">
                  <Stat label="Pages scanned" value={librarian.pages} />
                  <Stat label="Flagged for review" value={librarian.flagged} />
                  <Stat label="Tier-2 scored" value={librarian.tier2Scored ?? 0} />
                </div>
                {librarian.stalest.length === 0 ? (
                  <p className="mt-1 text-[12px] text-[color:var(--color-text-quaternary)]">No stale pages.</p>
                ) : (
                  <ul className="mt-2 space-y-1">
                    {librarian.stalest.slice(0, 10).map((p) => (
                      <li key={p.documentID} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                        {p.needsTier2 && <Badge variant="danger">flagged</Badge>}
                        {p.coherence !== undefined && p.utility !== undefined && (
                          <Badge
                            variant={Math.min(p.coherence, p.utility) <= 2 ? "danger" : Math.min(p.coherence, p.utility) === 3 ? "warning" : "success"}
                            title={p.rationale}
                          >
                            coh {p.coherence} · util {p.utility}
                          </Badge>
                        )}
                        <Badge variant="outline">{p.volatility}</Badge>
                        <span className="text-[12px] text-foreground">page #{p.documentID}</span>
                        <span className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                          staleness {p.staleness.toFixed(1)} · {p.sourceCount} src · depth {p.depthProxy}
                        </span>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
            {audit && (
              <>
                <h4 className="mt-4 text-[12px] font-medium text-foreground">Audit — output drift</h4>
                <div className="mt-1 grid grid-cols-3 gap-3">
                  <Stat label="Tracked pages" value={audit.pages} />
                  <Stat label="Drifted" value={audit.drifted} />
                  <Stat label="Indirectly drifted" value={audit.indirectlyDrifted} />
                </div>
                {audit.pagesDetail.filter((p) => p.status !== "current").length === 0 ? (
                  <p className="mt-1 text-[12px] text-[color:var(--color-text-quaternary)]">All pages current.</p>
                ) : (
                  <ul className="mt-2 space-y-1">
                    {audit.pagesDetail.filter((p) => p.status !== "current").slice(0, 10).map((p) => (
                      <li key={p.id} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                        <Badge variant={p.status === "drifted" ? "danger" : "outline"}>{p.status}</Badge>
                        <span className="text-[12px] text-foreground">page #{p.id}</span>
                      </li>
                    ))}
                  </ul>
                )}
              </>
            )}
          </TabsContent>

          {/* ── Inventory (curation) ── */}
          <TabsContent value="inventory" className="mt-3">
            <p className="mb-2 text-[12px] text-[color:var(--color-text-quaternary)]">
              durable items / candidates / questions — managed via <code>codex-memory wiki-inventory</code>
            </p>
            {curationLoaded && inventory.length === 0 ? (
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">No inventory records.</p>
            ) : (
              <ul className="space-y-1">
                {inventory.map((r) => (
                  <li key={r.slug} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                    <Badge variant={r.priority === "p0" ? "danger" : "outline"}>{r.priority}</Badge>
                    <Badge variant="outline">{r.kind}</Badge>
                    <Badge variant={r.status === "active" ? "success" : "outline"}>{r.status}</Badge>
                    <span className="truncate text-[12px] text-foreground">{r.title}</span>
                  </li>
                ))}
              </ul>
            )}
          </TabsContent>

          {/* ── Datasets (curation) ── */}
          <TabsContent value="datasets" className="mt-3">
            <p className="mb-2 text-[12px] text-[color:var(--color-text-quaternary)]">
              indexed datasets — the wiki is the interface, data stays put
            </p>
            {curationLoaded && datasets.length === 0 ? (
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">No dataset manifests.</p>
            ) : (
              <ul className="space-y-1">
                {datasets.map((d) => (
                  <li key={d.datasetID} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                    <Badge variant="outline">{d.storage}</Badge>
                    <Badge variant={d.status === "active" ? "success" : "outline"}>{d.status}</Badge>
                    <span className="truncate text-[12px] text-foreground">{d.title}</span>
                    <span className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">
                      {d.recordCount != null ? `${d.recordCount.toLocaleString()} rows` : "—"}
                    </span>
                  </li>
                ))}
              </ul>
            )}
          </TabsContent>

          {/* ── Collect (curation) ── */}
          <TabsContent value="collect" className="mt-3">
            <p className="mb-2 text-[12px] text-[color:var(--color-text-quaternary)]">
              discovery catalogs — assets staged under <code>output/assets/</code>
            </p>
            {curationLoaded && catalogs.length === 0 ? (
              <p className="text-[12px] text-[color:var(--color-text-quaternary)]">No collect catalogs.</p>
            ) : (
              <ul className="space-y-1">
                {catalogs.map((c) => (
                  <li key={c.slug} className="flex items-center gap-2 rounded-md border border-[color:var(--border)] px-3 py-2">
                    <Images className="size-3.5 text-[color:var(--color-text-quaternary)]" />
                    <span className="text-[12px] text-foreground">{c.slug}</span>
                    <span className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-quaternary)]">{c.count} item(s)</span>
                  </li>
                ))}
              </ul>
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
