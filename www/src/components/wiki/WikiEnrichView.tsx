import * as React from "react";
import { useNavigate } from "react-router-dom";
import { Sparkles, Loader2 } from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiBrief } from "@/runtime/connector";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { ScrollArea } from "@/components/ui/scroll-area";

/**
 * Enrich surface: a lexical, zero-spend, CITATION-FIRST synthesis brief over the
 * Memory Wiki (the backend `wiki/brief` / WikiBriefTool). Enter a topic → get a
 * grounded summary, cited key points, novelty rationale, and the supporting
 * citations (each clickable through to a search). No cloud spend.
 */
export function WikiEnrichView() {
  const { connector, status } = useRuntime();
  const navigate = useNavigate();
  const [topic, setTopic] = React.useState("");
  const [brief, setBrief] = React.useState<WikiBrief | null>(null);
  const [loading, setLoading] = React.useState(false);
  const [ran, setRan] = React.useState(false);
  const available = status.kind === "connected" && typeof connector.getWikiBrief === "function";

  const run = React.useCallback(async () => {
    const t = topic.trim();
    if (!t || !connector.getWikiBrief || loading) return;
    setLoading(true);
    setRan(true);
    try {
      const r = await connector.getWikiBrief(t, { k: 8 });
      setBrief(r);
    } catch {
      setBrief(null);
    } finally {
      setLoading(false);
    }
  }, [topic, connector, loading]);

  // Citations indexed by id for key-point references.
  const citeById = React.useMemo(() => {
    const m = new Map<string, number>();
    (brief?.citations ?? []).forEach((c, i) => m.set(c.id, i + 1));
    return m;
  }, [brief]);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="shrink-0 border-b border-[color:var(--border)] px-6 py-4">
        <div className="flex items-center gap-2">
          <Sparkles className="size-4 text-[color:var(--text-link)]" />
          <h1 className="text-[18px] font-semibold text-foreground">Enrich</h1>
          <span className="text-[12px] text-[color:var(--color-text-quaternary)]">
            cited synthesis · local · no cloud spend
          </span>
        </div>
        <div className="mt-3 flex gap-2">
          <Input
            value={topic}
            onChange={(e) => setTopic(e.target.value)}
            onKeyDown={(e) => { if (e.key === "Enter") void run(); }}
            placeholder="Topic to synthesize a brief on…"
            className="max-w-[560px]"
          />
          <Button onClick={() => void run()} disabled={!available || !topic.trim() || loading} loading={loading}>
            {loading ? "Synthesizing…" : "Brief"}
          </Button>
        </div>
        {!available && (
          <div className="mt-2 text-[12px] text-[color:var(--color-text-quaternary)]">
            Enrich is unavailable with this connection.
          </div>
        )}
      </div>

      <ScrollArea className="min-h-0 flex-1">
        <div className="mx-auto w-full max-w-[820px] px-6 pb-16 pt-6">
          {loading ? (
            <div className="flex items-center gap-2 text-[13px] text-[color:var(--color-text-secondary)]">
              <Loader2 className="size-3.5 animate-spin" /> Gathering cited evidence…
            </div>
          ) : !ran ? (
            <div className="text-[13px] text-[color:var(--color-text-secondary)]">
              Enter a topic to generate a grounded, cited brief from your wiki.
            </div>
          ) : !brief ? (
            <div className="text-[13px] text-[color:var(--color-text-quaternary)]">No brief returned.</div>
          ) : (
            <article className="flex flex-col gap-6">
              <section>
                <div className="mb-1 flex items-center gap-2">
                  <h2 className="text-[15px] font-semibold text-foreground">{brief.topic || topic}</h2>
                  {brief.confidence && (
                    <span className="rounded-full bg-[color:var(--color-surface-hover)] px-2 py-0.5 text-[11px] text-[color:var(--color-text-tertiary)]">
                      {brief.confidence} confidence
                    </span>
                  )}
                </div>
                <p className="text-[14px] leading-relaxed text-foreground">{brief.summary}</p>
              </section>

              <CitedList title="Key points" points={brief.key_points} citeById={citeById} />
              <CitedList title="Why it's notable" points={brief.novelty_rationale} citeById={citeById} />
              <StringList title="What would change the conclusion" items={brief.what_would_change_my_mind} />
              <StringList title="Limitations" items={brief.limitations} />

              {brief.citations && brief.citations.length > 0 && (
                <section>
                  <h3 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
                    Citations
                  </h3>
                  <ol className="flex flex-col gap-2">
                    {brief.citations.map((c, i) => (
                      <li key={c.id} className="rounded-md border border-[color:var(--border)] px-3 py-2">
                        <button
                          type="button"
                          onClick={() => navigate(`/wiki?q=${encodeURIComponent(topic)}`)}
                          className="text-left text-[12px] font-medium text-[color:var(--text-link)] hover:underline"
                        >
                          [{i + 1}] {c.doc_uri}
                        </button>
                        <p className="mt-0.5 text-[12.5px] leading-snug text-[color:var(--color-text-secondary)]">
                          {c.snippet}
                        </p>
                      </li>
                    ))}
                  </ol>
                </section>
              )}
            </article>
          )}
        </div>
      </ScrollArea>
    </div>
  );
}

function CitedList({
  title, points, citeById,
}: { title: string; points?: { text: string; citation_ids: string[] }[]; citeById: Map<string, number> }) {
  if (!points || points.length === 0) return null;
  return (
    <section>
      <h3 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
        {title}
      </h3>
      <ul className="flex flex-col gap-1.5">
        {points.map((p, i) => (
          <li key={i} className="text-[13.5px] leading-snug text-foreground">
            {p.text}
            {p.citation_ids.map((id) => {
              const n = citeById.get(id);
              return n ? (
                <sup key={id} className="ml-0.5 text-[10px] text-[color:var(--text-link)]">[{n}]</sup>
              ) : null;
            })}
          </li>
        ))}
      </ul>
    </section>
  );
}

function StringList({ title, items }: { title: string; items?: string[] }) {
  if (!items || items.length === 0) return null;
  return (
    <section>
      <h3 className="mb-2 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
        {title}
      </h3>
      <ul className="flex list-disc flex-col gap-1 pl-5">
        {items.map((s, i) => (
          <li key={i} className="text-[13px] text-[color:var(--color-text-secondary)]">{s}</li>
        ))}
      </ul>
    </section>
  );
}
