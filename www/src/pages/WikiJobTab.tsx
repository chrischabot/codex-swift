import { useState } from "react";
import { Loader2, Play } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiJobLine } from "@/runtime/connector";

/**
 * A live job-trigger tab for the Console: a small form starts a streamed
 * research/ingest job over the WS (wiki/research/start | wiki/ingest/start) and
 * renders each progress line as it arrives, plus the terminal result. These are
 * WRITE operations (research spends model budget; ingest writes the store).
 */
export function WikiJobTab({ kind }: { kind: "research" | "ingest" }) {
  const { connector } = useRuntime();

  // shared
  const [input, setInput] = useState("");
  const [lines, setLines] = useState<WikiJobLine[]>([]);
  const [running, setRunning] = useState(false);
  const [error, setError] = useState<string | null>(null);

  // research options
  const [mode, setMode] = useState("");
  const [depth, setDepth] = useState("standard");
  // ingest options
  const [adapter, setAdapter] = useState("");
  const [extract, setExtract] = useState(false);

  const placeholder = kind === "research"
    ? "Topic / question / thesis to research…"
    : "URL / arXiv query / GitHub-owner URL to ingest…";

  async function run() {
    const value = input.trim();
    if (!value || running) return;
    if (kind === "research" ? !connector.startWikiResearch : !connector.startWikiIngest) {
      setError("Live jobs are not available on this connector.");
      return;
    }
    setLines([]);
    setError(null);
    setRunning(true);
    const onEvent = (line: WikiJobLine, done: boolean) => {
      setLines((prev) => [...prev, line]);
      if (done) setRunning(false);
    };
    try {
      if (kind === "research") {
        await connector.startWikiResearch!(
          { topic: value, mode: mode || undefined, depth, sources: 3 }, onEvent);
      } else {
        await connector.startWikiIngest!(
          { input: value, adapter: adapter || undefined, extract }, onEvent);
      }
    } catch (e) {
      setError(String(e));
      setRunning(false);
    }
  }

  return (
    <div className="mt-3">
      <form className="flex flex-wrap items-center gap-2"
            onSubmit={(e) => { e.preventDefault(); void run(); }}>
        <Input value={input} onChange={(e) => setInput(e.target.value)}
               placeholder={placeholder} aria-label={`${kind} input`}
               className="min-w-[16rem] flex-1" />
        {kind === "research" ? (
          <>
            <select aria-label="mode" value={mode} onChange={(e) => setMode(e.target.value)}
                    className="h-9 rounded-md border border-[color:var(--border)] bg-transparent px-2 text-[13px]">
              <option value="">auto</option>
              <option value="topic">topic</option>
              <option value="question">question</option>
              <option value="thesis">thesis</option>
            </select>
            <select aria-label="depth" value={depth} onChange={(e) => setDepth(e.target.value)}
                    className="h-9 rounded-md border border-[color:var(--border)] bg-transparent px-2 text-[13px]">
              <option value="standard">standard</option>
              <option value="deep">deep</option>
              <option value="retardmax">retardmax</option>
            </select>
          </>
        ) : (
          <>
            <select aria-label="adapter" value={adapter} onChange={(e) => setAdapter(e.target.value)}
                    className="h-9 rounded-md border border-[color:var(--border)] bg-transparent px-2 text-[13px]">
              <option value="">auto</option>
              <option value="url">url</option>
              <option value="feed">feed</option>
              <option value="arxiv">arxiv</option>
              <option value="github">github</option>
              <option value="file">file</option>
            </select>
            <label className="flex items-center gap-1 text-[12px] text-[color:var(--color-text-secondary)]">
              <input type="checkbox" checked={extract} onChange={(e) => setExtract(e.target.checked)}
                     aria-label="extract" />
              extract
            </label>
          </>
        )}
        <Button type="submit" disabled={running || !input.trim()}>
          {running ? <Loader2 className="mr-1 size-3.5 animate-spin" /> : <Play className="mr-1 size-3.5" />}
          {running ? "Running…" : kind === "research" ? "Research" : "Ingest"}
        </Button>
      </form>

      {error && <p className="mt-3 text-[13px] text-[color:var(--destructive)]">{error}</p>}

      {lines.length > 0 && (
        <div className="mt-3 max-h-80 overflow-auto rounded-md border border-[color:var(--border)] p-3"
             aria-label="job log">
          <ul className="space-y-1 font-mono text-[12px]">
            {lines.map((l, i) => (
              <li key={i} className={l.type === "result"
                ? "font-medium text-foreground"
                : "text-[color:var(--color-text-secondary)]"}>
                {renderLine(kind, l)}
              </li>
            ))}
          </ul>
          {running && (
            <div className="mt-2 flex items-center gap-1 text-[11px] text-[color:var(--color-text-quaternary)]">
              <Loader2 className="size-3 animate-spin" /> streaming…
            </div>
          )}
        </div>
      )}
    </div>
  );
}

/** Render one streamed NDJSON line as a readable log entry. */
export function renderLine(kind: "research" | "ingest", l: WikiJobLine): string {
  if (l.type === "result") {
    if (kind === "research") {
      return `✓ ${l.status ?? "done"} — ${l.rounds ?? 0} round(s), ${l.sources ?? 0} sources, ${l.pages ?? 0} pages, score ${l.finalScore ?? 0}`;
    }
    return `✓ ${l.status ?? "done"} — ${l.written ?? 0} written, ${l.skipped ?? 0} skipped, ${l.failed ?? 0} failed`;
  }
  switch (l.kind) {
    case "started": return `▶ research started (mode ${l.mode ?? "?"})`;
    case "round_started": return `round ${l.round} started`;
    case "sources": return `  ${l.count} source(s) gathered (round ${l.round})`;
    case "compiled": return `  compiled round ${l.round}: ${l.written} written, ${l.claims} claims`;
    case "round_completed": return `round ${l.round} done — score ${l.score}`;
    case "finished": return `finished — ${l.rounds} round(s), score ${l.score}`;
    case "candidate": return `[${l.seq}] ${l.status} — ${l.uri}`;
    default: return JSON.stringify(l);
  }
}
