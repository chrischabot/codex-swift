import * as React from "react";
import { useParams } from "react-router-dom";
import { dispatch } from "@/state/store";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import { Target, TerminalSquare, FileSearch, Undo2, Brain, Mic, MicOff } from "lucide-react";
import { useRealtimeVoice } from "@/hooks/useRealtimeVoice";

/// Side-panel "Tools" tab: surfaces backend capabilities that previously had no
/// UI — thread goal (thread/goal/*), shell exec (thread/shellCommand), fuzzy
/// file search (fuzzyFileSearch), rollback (thread/rollback), and per-thread
/// memory mode (thread/memoryMode/set). All wired through the connector.
export function ThreadToolsTab() {
  const { threadId } = useParams();
  const tid = threadId ?? "";

  const [objective, setObjective] = React.useState("");
  const [budget, setBudget] = React.useState("");
  const [command, setCommand] = React.useState("");
  const [query, setQuery] = React.useState("");
  const [files, setFiles] = React.useState<string[]>([]);
  const [memoryOn, setMemoryOn] = React.useState(true);
  const [voices, setVoices] = React.useState<string[]>([]);
  const [voice, setVoice] = React.useState("");
  const [voiceActive, setVoiceActive] = React.useState(false);
  const [voiceText, setVoiceText] = React.useState("");
  const { transcript, micOn, startMic, stopMic } = useRealtimeVoice(tid, voiceActive);

  React.useEffect(() => {
    if (!tid) return;
    let alive = true;
    dispatch.getGoal(tid).then((g) => { if (alive && g) { setObjective(g.objective); if (g.tokenBudget) setBudget(String(g.tokenBudget)); } }).catch(() => {});
    dispatch.listVoices().then((v) => { if (alive) { setVoices(v); if (v[0]) setVoice(v[0]); } }).catch(() => {});
    return () => { alive = false; };
  }, [tid]);

  const Section = ({ icon, title, children }: { icon: React.ReactNode; title: string; children: React.ReactNode }) => (
    <div className="border-b border-[color:var(--color-divider)] px-3 py-3">
      <div className="mb-2 flex items-center gap-1.5 text-[12px] font-medium text-foreground">{icon}{title}</div>
      {children}
    </div>
  );
  const input = "w-full rounded-md border border-[color:var(--border)] bg-background px-2 py-1 text-[12px]";

  return (
    <div className="flex-1 overflow-y-auto text-[12px]">
      <Section icon={<Target className="size-3.5" />} title="Goal / mission">
        <input className={input} placeholder="Objective…" value={objective} onChange={(e) => setObjective(e.target.value)} />
        <input className={`${input} mt-1.5`} placeholder="Token budget (optional)" value={budget} onChange={(e) => setBudget(e.target.value)} />
        <div className="mt-2 flex gap-1.5">
          <Button size="sm" disabled={!tid || !objective.trim()} onClick={async () => { await dispatch.setGoal(tid, objective.trim(), budget ? Number(budget) : undefined); toast("Goal set"); }}>Set goal</Button>
          <Button size="sm" variant="outline" disabled={!tid} onClick={async () => { await dispatch.clearGoal(tid); setObjective(""); setBudget(""); toast("Goal cleared"); }}>Clear</Button>
        </div>
      </Section>

      <Section icon={<TerminalSquare className="size-3.5" />} title="Run shell command">
        <div className="flex gap-1.5">
          <input className={input} placeholder="e.g. ls -la" value={command}
                 onChange={(e) => setCommand(e.target.value)}
                 onKeyDown={(e) => { if (e.key === "Enter" && command.trim() && tid) { void dispatch.runShell(tid, command.trim()); toast("Running…"); setCommand(""); } }} />
          <Button size="sm" disabled={!tid || !command.trim()} onClick={() => { void dispatch.runShell(tid, command.trim()); toast("Running…"); setCommand(""); }}>Run</Button>
        </div>
        <div className="mt-1 text-[11px] text-[color:var(--color-text-tertiary)]">Output streams into the conversation.</div>
      </Section>

      <Section icon={<FileSearch className="size-3.5" />} title="Find files">
        <input className={input} placeholder="Fuzzy file search…" value={query}
               onChange={async (e) => { const q = e.target.value; setQuery(q); if (q.trim().length >= 2 && tid) setFiles(await dispatch.searchFiles(q.trim())); else setFiles([]); }} />
        <div className="mt-1.5 max-h-40 overflow-y-auto">
          {files.map((f) => (<div key={f} className="truncate py-0.5 font-mono text-[11px] text-[color:var(--color-text-secondary)]" title={f}>{f}</div>))}
        </div>
      </Section>

      <Section icon={<Undo2 className="size-3.5" />} title="Rollback">
        <Button size="sm" variant="outline" disabled={!tid} onClick={async () => { await dispatch.rollbackTurns(tid, 1); toast("Rolled back last turn"); }}>Undo last turn</Button>
      </Section>

      <Section icon={<Brain className="size-3.5" />} title="Memory">
        <label className="flex items-center gap-2">
          <input type="checkbox" checked={memoryOn} onChange={async (e) => { setMemoryOn(e.target.checked); await dispatch.setMemoryMode(tid, e.target.checked); }} />
          Persist memory for this thread
        </label>
      </Section>

      <Section icon={<Mic className="size-3.5" />} title="Realtime voice">
        <div className="flex gap-1.5">
          <select className={input} value={voice} onChange={(e) => setVoice(e.target.value)} disabled={voiceActive}>
            {voices.length === 0 && <option value="">(no voices)</option>}
            {voices.map((v) => (<option key={v} value={v}>{v}</option>))}
          </select>
          {voiceActive
            ? <Button size="sm" variant="outline" disabled={!tid} onClick={async () => { await dispatch.stopRealtime(tid); setVoiceActive(false); }}>Stop</Button>
            : <Button size="sm" disabled={!tid} onClick={async () => { await dispatch.startRealtime(tid, voice || undefined); setVoiceActive(true); toast("Realtime session started"); }}>Start</Button>}
        </div>
        {voiceActive && (
          <>
            <div className="mt-1.5 flex gap-1.5">
              <input className={input} placeholder="Speak as text…" value={voiceText}
                     onChange={(e) => setVoiceText(e.target.value)}
                     onKeyDown={(e) => { if (e.key === "Enter" && voiceText.trim()) { void dispatch.sendRealtimeText(tid, voiceText.trim()); setVoiceText(""); } }} />
              <Button size="sm" variant={micOn ? "default" : "outline"}
                      onClick={() => (micOn ? stopMic() : void startMic())}
                      aria-label={micOn ? "Stop microphone" : "Start microphone"}>
                {micOn ? <MicOff className="size-3.5" /> : <Mic className="size-3.5" />}
              </Button>
            </div>
            {micOn && <div className="mt-1 text-[11px] text-[color:var(--color-green-500)]">● Listening — streaming mic audio</div>}
            {transcript.length > 0 && (
              <div className="mt-2 max-h-40 space-y-1 overflow-y-auto rounded-md border border-[color:var(--border)] p-2">
                {transcript.map((l, i) => (
                  <div key={i} className="text-[11.5px]">
                    <span className="text-[color:var(--color-text-tertiary)]">{l.role}: </span>
                    <span className="text-[color:var(--color-text-secondary)]">{l.text}</span>
                  </div>
                ))}
              </div>
            )}
          </>
        )}
        <div className="mt-1 text-[11px] text-[color:var(--color-text-tertiary)]">Mic streams PCM16 to the realtime session; transcript + audio play back live.</div>
      </Section>
    </div>
  );
}
