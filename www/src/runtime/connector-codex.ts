// CodexConnector — the real adapter that drives the shadcn UI from a
// codex-swift `codexd` web gateway. It speaks the codex-swift app-server
// JSON-RPC protocol directly over a same-origin WebSocket (`/ws`).
//
// IMPORTANT: this UI renders entirely from `ConnectorSnapshot.messages`
// (`subscribeThread`/`ThreadStreamEvent` is unused dead code in this build, as
// the MockConnector demonstrates). So this connector MAINTAINS `snap.messages`
// directly — appending the optimistic user message and building the streaming
// assistant message from app-server notifications — and re-broadcasts the
// snapshot. See docs/webgateway/PROTOCOL_MAP.md for the wire map.
//
// Wire shape (codex-swift is tag-less JSON-RPC — NO `jsonrpc` field):
//   request {id,method,params} · response {id,result}|{id,error}
//   notification {method,params} · serverRequest {id,method,params}

import type {
  DiffEnvironment,
  Hook,
  McpServer,
  Message,
  MessageBlock,
  Plugin,
  PluginApp,
  Project,
  Skill,
  Thread,
  TimelineEvent,
} from "@/domain/models";
import type {
  ApprovalScope,
  BlockDelta,
  Connector,
  ConnectorSnapshot,
  ConnectorStatus,
  DiffViewModel,
  RealtimeEvent,
  SendOptions,
  ThreadStreamEvent,
  UploadedAttachment,
  WikiBrief,
  WikiGraph,
  WikiPage,
  WikiPageSummary,
  WikiTag,
} from "./connector";
import { toast } from "@/components/ui/sonner";
import { parseUnifiedDiff, countDiff } from "@/lib/diff";

export interface CodexConnectorOptions {
  url?: string;
  token?: string;
}

type Json = unknown;
interface WireMessage {
  id?: number | string;
  method?: string;
  params?: Record<string, Json>;
  result?: Json;
  error?: { code: number; message: string; data?: Json };
}

const EMPTY_SNAPSHOT: ConnectorSnapshot = {
  projects: [], threads: [], messages: [], plugins: [], apps: [],
  automations: [], automationTemplates: [], mcpServers: [], skills: [], hooks: [],
};

const DEFAULT_PROJECT: Project = {
  id: "p-diminuendo", name: "Local", workingDirectory: "", kind: "git",
};

function defaultUrl(): string {
  if (typeof window === "undefined") return "ws://127.0.0.1:8443/ws";
  const scheme = window.location.protocol === "https:" ? "wss" : "ws";
  return `${scheme}://${window.location.host}/ws`;
}

let seq = 0;
const uid = (p: string) => `${p}-${Date.now().toString(36)}-${(seq++).toString(36)}`;

export function makeCodexConnector(opts: CodexConnectorOptions = {}): Connector {
  const url = opts.url ?? defaultUrl();

  let ws: WebSocket | null = null;
  let nextId = 1;
  const pending = new Map<number, { resolve: (v: Json) => void; reject: (e: unknown) => void }>();
  // RPCs issued before the socket is OPEN (e.g. a settings panel reading config
  // on mount, before connect() finishes) are queued here and flushed once the
  // connection is ready — instead of rejecting, which made config-backed panels
  // silently fall back to defaults on first load.
  let preOpenQueue: Array<() => void> = [];

  let currentStatus: ConnectorStatus = { kind: "offline" };
  const statusListeners = new Set<(s: ConnectorStatus) => void>();
  const setStatus = (s: ConnectorStatus) => { currentStatus = s; statusListeners.forEach((l) => l(s)); };

  let snap: ConnectorSnapshot = { ...EMPTY_SNAPSHOT, projects: [DEFAULT_PROJECT] };
  const snapshotListeners = new Set<(s: ConnectorSnapshot) => void>();
  const updateSnap = (mut: (s: ConnectorSnapshot) => ConnectorSnapshot) => {
    snap = mut(snap);
    snapshotListeners.forEach((l) => l(snap));
  };

  // Threads whose worker is bound + this connection subscribed (so notifications flow).
  const bound = new Set<string>();
  // Threads whose history has been loaded (synchronous double-load guard).
  const historyLoaded = new Set<string>();
  // Threads created in THIS session (via createThread): they have no
  // server-side history worth loading and are driven by the live stream, so
  // loadThreadHistory must skip them (loading would duplicate the optimistic
  // user bubble + streamed assistant message).
  const createdThisSession = new Set<string>();
  const activeTurn = new Map<string, string>();
  // Uploaded-but-not-yet-sent attachments, keyed by threadId ("shared" for the
  // home composer where no thread exists yet). Drained on the next sendMessage.
  const pendingUploads = new Map<string, UploadedAttachment[]>();
  // Latest unified diff per thread, from turn/diff/updated — powers getDiff().
  const latestDiff = new Map<string, string>();
  // Cached model catalog (id + label), loaded on connect. Used to resolve the
  // composer's display label to a real model id before turn/start.
  const modelCache: { id: string; label: string }[] = [];
  const resolveModelId = (label?: string): string | undefined => {
    if (!label) return undefined;
    const l = label.trim().toLowerCase();
    if (!l || !modelCache.length) return undefined;
    const m =
      modelCache.find((x) => x.id.toLowerCase() === l) ??
      modelCache.find((x) => x.id.toLowerCase() === `gpt-${l}`) ??
      modelCache.find((x) => x.label.toLowerCase() === l) ??
      modelCache.find((x) => x.label.toLowerCase().replace(/^gpt[- ]?/, "") === l) ??
      modelCache.find((x) => x.id.toLowerCase().endsWith(l));
    return m?.id;   // undefined → caller omits `model` (backend default)
  };
  async function loadModels() {
    try {
      const r = (await rpc("model/list", {})) as { data?: Record<string, unknown>[] };
      modelCache.length = 0;
      for (const m of r.data ?? []) modelCache.push({ id: pick(m, "id", "slug", "name"), label: pick(m, "displayName", "label", "name", "id") });
    } catch { /* leave cache empty → model omitted, backend default used */ }
  }
  // Per-thread timeline of structured events (turns, commands, edits, approvals)
  // accumulated from the live stream — powers getTimeline() for the side panel.
  const timeline = new Map<string, TimelineEvent[]>();
  const pushTimeline = (threadId: string, ev: Omit<TimelineEvent, "id" | "at">) => {
    if (!threadId) return;
    const list = timeline.get(threadId) ?? [];
    list.push({ id: uid("tl"), at: Date.now(), ...ev });
    // Cap so a long thread can't grow the buffer without bound.
    timeline.set(threadId, list.slice(-200));
  };
  // itemId → concatenated unified diff, captured from fileChange items so a
  // subsequent item/fileChange/requestApproval can show the patch in its card.
  const fileChangeDiffs = new Map<string, string>();
  // Per-thread realtime-session listeners (transcript + audio output).
  const realtimeListeners = new Map<string, Set<(e: RealtimeEvent) => void>>();
  const emitRealtime = (threadId: string, e: RealtimeEvent) => {
    realtimeListeners.get(threadId)?.forEach((l) => l(e));
  };
  // Record a completed item into the timeline + diff cache.
  const recordItemEvents = (threadId: string, item: ThreadItemWire) => {
    switch (item.type) {
      case "commandExecution":
        pushTimeline(threadId, { kind: "turn", title: item.command || "Command", detail: item.cwd });
        break;
      case "fileChange": {
        const changes = item.changes ?? [];
        if (item.id) fileChangeDiffs.set(item.id, changes.map((c) => c.diff ?? "").join("\n"));
        pushTimeline(threadId, {
          kind: "file",
          title: changes.length === 1 ? (changes[0].path ?? "File change") : `${changes.length} files changed`,
        });
        break;
      }
      default: break;
    }
  };

  // ── snapshot message mutators (the rendered surface) ──────────────────────
  const appendMessage = (m: Message) => updateSnap((s) => ({ ...s, messages: [...s.messages, m] }));
  const ensureAssistant = (threadId: string, turnId: string) => {
    if (!snap.messages.some((m) => m.id === turnId)) {
      appendMessage({ id: turnId, threadId, role: "assistant", preamble: "Working", blocks: [], createdAt: Date.now() });
    }
  };
  const blockId = (b: MessageBlock) => (b as { blockId?: string }).blockId;
  const upsertBlock = (messageId: string, block: MessageBlock) =>
    updateSnap((s) => ({
      ...s,
      messages: s.messages.map((m) => {
        if (m.id !== messageId) return m;
        const i = m.blocks.findIndex((b) => blockId(b) === blockId(block));
        return { ...m, blocks: i >= 0 ? m.blocks.map((b, j) => (j === i ? block : b)) : [...m.blocks, block] };
      }),
    }));
  const applyDelta = (messageId: string, bid: string, delta: BlockDelta) =>
    updateSnap((s) => ({
      ...s,
      messages: s.messages.map((m) => {
        if (m.id !== messageId) return m;
        let blocks = m.blocks;
        if (!blocks.some((b) => blockId(b) === bid)) {
          const seed: MessageBlock = delta.kind === "stdout-append"
            ? { type: "shell", blockId: bid, cmd: "", output: "", status: "streaming" }
            : { type: "markdown", blockId: bid, content: "", status: "streaming" };
          blocks = [...blocks, seed];
        }
        return { ...m, blocks: blocks.map((b) => mergeDelta(b, bid, delta)) };
      }),
    }));
  const finalizeBlock = (messageId: string, bid: string, status: "ok" | "error" | "cancelled") =>
    updateSnap((s) => ({
      ...s,
      messages: s.messages.map((m) =>
        m.id !== messageId ? m : { ...m, blocks: m.blocks.map((b) => (blockId(b) === bid ? ({ ...b, status } as MessageBlock) : b)) }),
    }));
  const setPreamble = (messageId: string, preamble?: string) =>
    updateSnap((s) => ({ ...s, messages: s.messages.map((m) => (m.id === messageId ? { ...m, preamble } : m)) }));

  // ── transport ──────────────────────────────────────────────────────────
  function rpc(method: string, params?: Json): Promise<Json> {
    return new Promise((resolve, reject) => {
      const send = () => {
        const id = nextId++;
        pending.set(id, { resolve, reject });
        try { ws!.send(JSON.stringify({ id, method, params })); }
        catch (e) { pending.delete(id); reject(e); }
      };
      if (ws && ws.readyState === WebSocket.OPEN) { send(); return; }
      if (!ws || ws.readyState === WebSocket.CONNECTING) {
        // Socket not open yet (connect() pending or in flight): queue until it
        // opens, with a safety timeout — early reads must not silently fall
        // back to defaults. connect() always follows, and its onopen flushes.
        let done = false;
        const timer = setTimeout(() => { if (!done) { done = true; reject(new Error("gateway connect timeout")); } }, 12000);
        preOpenQueue.push(() => { if (!done) { done = true; clearTimeout(timer); send(); } });
        return;
      }
      reject(new Error("gateway not connected"));   // CLOSING / CLOSED
    });
  }
  function reply(id: number | string, result: Json) {
    if (ws && ws.readyState === WebSocket.OPEN) ws.send(JSON.stringify({ id, result }));
  }
  // Server-request ids are tagless and MAY be non-numeric (the backend mints MCP
  // elicitation ids like "mcp-<thread>-<uuid>"). approvalId is stored as a
  // String(msg.id); recover the original wire type — Number() on a UUID yields
  // NaN → {"id":null} and the backend can never correlate the reply.
  const wireId = (s: string): number | string => (/^\d+$/.test(s) ? Number(s) : s);
  // Mark an approval/elicitation block decided in the snapshot so BOTH the
  // inline card and the Inbox tab reflect the resolution (and neither can
  // re-submit a second reply for an already-answered request).
  const markApprovalDecided = (approvalId: string, decided: "allowed" | "denied" | "cancelled") =>
    updateSnap((s) => ({
      ...s,
      messages: s.messages.map((m) => ({
        ...m,
        blocks: m.blocks.map((b) =>
          b.type === "approval" && b.approvalId === approvalId ? { ...b, decided } : b),
      })),
    }));

  function onWireMessage(raw: string) {
    let msg: WireMessage;
    try { msg = JSON.parse(raw) as WireMessage; } catch { return; }
    const hasId = msg.id !== undefined && msg.id !== null;
    const hasMethod = typeof msg.method === "string";
    if (hasId && hasMethod) { handleServerRequest(msg); return; }
    if (hasId) {
      const entry = pending.get(msg.id as number);
      if (entry) { pending.delete(msg.id as number); msg.error ? entry.reject(new Error(msg.error.message)) : entry.resolve(msg.result); }
      return;
    }
    if (hasMethod) handleNotification(msg.method!, msg.params ?? {});
  }

  // ── server→client requests → approval / elicitation / question blocks ──────
  function handleServerRequest(msg: WireMessage) {
    const p = msg.params ?? {};
    const threadId = (p.threadId as string) ?? "";
    const turnId = (p.turnId as string) ?? "";
    const itemId = (p.itemId as string) ?? "";
    const approvalId = String(msg.id);
    const method = msg.method ?? "";

    // MCP elicitation can arrive with no turnId — handle it before the guard,
    // anchoring to the active turn (or a synthetic message) so it always shows.
    if (method === "mcpServer/elicitation/request") {
      if (!threadId) { reply(msg.id!, { action: "decline" }); return; }
      const mid = turnId || activeTurn.get(threadId) || `elicit-${approvalId}`;
      ensureAssistant(threadId, mid);
      const fields = schemaToFields(p.requestedSchema as Record<string, unknown> | undefined);
      const server = (p.serverName as string) ?? "MCP server";
      upsertBlock(mid, {
        type: "approval", blockId: `elicit-${approvalId}`, approvalId, kind: "custom",
        title: `${server} requests input`,
        detail: (p.message as string) ?? undefined,
        prompt: (p.message as string) ?? undefined,
        elicitation: true,
        fields: fields.length ? fields : [{ id: "value", label: "Response", kind: "text" }],
        decisions: ["allow_once", "cancel"],
      });
      pushTimeline(threadId, { kind: "approval", title: `Elicitation: ${server}` });
      return;
    }

    if (!threadId || !turnId) { reply(msg.id!, {}); return; }
    ensureAssistant(threadId, turnId);

    if (method === "item/commandExecution/requestApproval") {
      const command = (p.command as string) ?? "";
      upsertBlock(turnId, {
        type: "approval", blockId: `appr-${approvalId}`, approvalId, kind: "exec",
        title: command || "Run command", detail: (p.reason as string) ?? undefined,
        command: command ? [command] : undefined, cwd: (p.cwd as string) ?? undefined,
        risk: "modify", decisions: ["allow_once", "allow_always", "deny_once", "cancel"],
      });
      pushTimeline(threadId, { kind: "approval", title: `Run: ${command}` });
    } else if (method === "item/fileChange/requestApproval") {
      // Correlate by itemId to the fileChange item we already saw, so the card
      // shows the actual patch instead of a blind "Apply file changes".
      const patch = (itemId && fileChangeDiffs.get(itemId)) || undefined;
      upsertBlock(turnId, {
        type: "approval", blockId: `appr-${approvalId}`, approvalId, kind: "patch",
        title: "Apply file changes", detail: (p.reason as string) ?? undefined,
        patch,
        risk: "modify", decisions: ["allow_once", "allow_always", "deny_once", "cancel"],
      });
      pushTimeline(threadId, { kind: "approval", title: "Apply file changes" });
    } else if (method === "item/permissions/requestApproval") {
      // Additional-permission escalation — show a card instead of silently
      // auto-approving (was a single-tenant default; now user-controlled).
      upsertBlock(turnId, {
        type: "approval", blockId: `appr-${approvalId}`, approvalId, kind: "network",
        title: "Grant additional permissions",
        detail: (p.reason as string) ?? "The agent is requesting elevated permissions.",
        risk: "network", decisions: ["allow_once", "allow_always", "deny_once", "cancel"],
      });
      pushTimeline(threadId, { kind: "approval", title: "Permission request" });
    } else if (method === "item/tool/requestUserInput") {
      // Build an inline question form; answered via answerQuestion (reply path).
      const questions = (p.questions as Array<Record<string, unknown>> | undefined) ?? [];
      const fields = questions.map((q, i) => {
        const rawOpts = q.options as Array<string | { label?: string }> | undefined;
        const opts = Array.isArray(rawOpts)
          ? rawOpts.map((o) => (typeof o === "string" ? o : String(o.label ?? ""))).filter(Boolean)
          : undefined;
        return {
          id: String(q.id ?? `q${i}`),
          label: String(q.header ?? q.question ?? q.label ?? q.prompt ?? q.text ?? `Question ${i + 1}`),
          kind: (Array.isArray(opts) && opts.length ? "choice" : "text") as "choice" | "text",
          options: opts,
        };
      });
      upsertBlock(turnId, {
        type: "question", blockId: `q-${approvalId}`, questionId: approvalId,
        title: "Input requested",
        prompt: typeof p.message === "string" ? p.message : undefined,
        fields: fields.length ? fields : [{ id: "answer", label: "Answer", kind: "text" }],
      });
    } else {
      // dynamic-tool / attestation / auth-refresh: not user-facing — ack so the
      // backend call doesn't hang (single-tenant: the user owns this agent).
      reply(msg.id!, {});
    }
  }

  // ── server→client notifications → snapshot message mutations ──────────────
  function handleNotification(method: string, p: Record<string, Json>) {
    const threadId = (p.threadId as string) ?? "";
    const turnId = (p.turnId as string) ?? "";
    const itemId = (p.itemId as string) ?? "";
    const msgId = turnId; // assistant message keyed by turn

    switch (method) {
      case "turn/started": {
        const t = p.turn as { id?: string } | undefined;
        if (t?.id) { activeTurn.set(threadId, t.id); ensureAssistant(threadId, t.id); }
        break;
      }
      case "turn/completed": {
        const t = p.turn as { id?: string } | undefined;
        const id = t?.id ?? msgId;
        if (id) setPreamble(id, "Worked");
        activeTurn.delete(threadId);
        pushTimeline(threadId, { kind: "turn", title: "Turn completed" });
        break;
      }
      case "item/started": {
        const block = itemToBlock(p.item as ThreadItemWire);
        if (block && threadId) { ensureAssistant(threadId, msgId); upsertBlock(msgId, block); }
        break;
      }
      case "item/completed": {
        const item = p.item as ThreadItemWire | undefined;
        const block = itemToBlock(item);
        if (block && threadId && item?.id) {
          ensureAssistant(threadId, msgId);
          upsertBlock(msgId, block);
          finalizeBlock(msgId, item.id, item.status === "failed" ? "error" : item.status === "declined" ? "cancelled" : "ok");
          recordItemEvents(threadId, item);
        }
        break;
      }
      case "item/agentMessage/delta": {
        if (threadId && itemId) { ensureAssistant(threadId, msgId); applyDelta(msgId, itemId, { kind: "text-append", text: (p.delta as string) ?? "" }); }
        break;
      }
      case "item/reasoning/textDelta":
      case "item/reasoning/summaryTextDelta": {
        if (threadId && itemId) {
          ensureAssistant(threadId, msgId);
          // Seed a THINKING block (not markdown) if the reasoning delta arrives
          // before its item/started.
          const m = snap.messages.find((x) => x.id === msgId);
          if (!m?.blocks.some((b) => (b as { blockId?: string }).blockId === itemId)) {
            upsertBlock(msgId, { type: "thinking", blockId: itemId, content: "", status: "streaming" });
          }
          applyDelta(msgId, itemId, { kind: "text-append", text: (p.delta as string) ?? "" });
        }
        break;
      }
      case "item/commandExecution/outputDelta": {
        if (threadId && itemId) { ensureAssistant(threadId, msgId); applyDelta(msgId, itemId, { kind: "stdout-append", text: (p.delta as string) ?? "" }); }
        break;
      }
      case "turn/plan/updated": {
        const steps = (p.plan as { step: string; status: string }[] | undefined) ?? [];
        if (threadId && msgId) {
          ensureAssistant(threadId, msgId);
          upsertBlock(msgId, {
            type: "plan", blockId: `plan-${msgId}`,
            steps: steps.map((s, i) => ({ id: `${i}`, content: s.step, status: s.status === "completed" ? "completed" : s.status === "inProgress" ? "in_progress" : "pending" })),
          });
        }
        break;
      }
      case "thread/name/updated": {
        const title = (p.threadName as string) ?? "";
        if (threadId && title) updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === threadId ? { ...t, title } : t)) }));
        break;
      }
      case "error": {
        const err = p.error as { message?: string } | undefined;
        if (threadId && msgId && err?.message) { ensureAssistant(threadId, msgId); upsertBlock(msgId, { type: "error", blockId: `err-${msgId}`, message: err.message, retryable: !!(p.willRetry as boolean) }); setPreamble(msgId, "Error"); }
        break;
      }
      case "thread/tokenUsage/updated": {
        const usage = p.tokenUsage as { total?: { inputTokens?: number; outputTokens?: number; cachedInputTokens?: number } } | undefined;
        const t = usage?.total;
        if (threadId && msgId && t) {
          ensureAssistant(threadId, msgId);
          upsertBlock(msgId, { type: "token-usage", blockId: `tokens-${msgId}`, input: t.inputTokens ?? 0, output: t.outputTokens ?? 0, cacheRead: t.cachedInputTokens });
        }
        break;
      }
      case "model/rerouted": {
        const to = (p.toModel as string) ?? "";
        if (threadId && msgId && to) {
          ensureAssistant(threadId, msgId);
          upsertBlock(msgId, { type: "model-switch", blockId: `model-${msgId}`, from: (p.fromModel as string) ?? undefined, to, reason: (p.reason as string) ?? undefined });
        }
        break;
      }
      // Live sidebar: keep snapshot.threads in sync without a refresh round-trip.
      case "thread/started": {
        const summary = p.thread as ThreadSummaryWire | undefined;
        if (summary?.id) {
          const t = mapThread(summary);
          updateSnap((s) => (s.threads.some((x) => x.id === t.id) ? s : { ...s, threads: [t, ...s.threads] }));
        }
        break;
      }
      case "thread/archived": {
        if (threadId) updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === threadId ? { ...t, status: "archived" } : t)) }));
        break;
      }
      case "thread/unarchived": {
        if (threadId) updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === threadId ? { ...t, status: "active" } : t)) }));
        break;
      }
      case "turn/diff/updated": {
        const diff = (p.diff as string) ?? "";
        if (threadId) latestDiff.set(threadId, diff);
        break;
      }
      // Live incremental patch streaming: refresh the diff block for this item
      // (and cache its body) before item/completed arrives.
      case "item/fileChange/patchUpdated": {
        const changes = (p.changes as ThreadItemWire["changes"]) ?? [];
        if (threadId && itemId && changes.length) {
          ensureAssistant(threadId, msgId);
          const block = itemToBlock({ type: "fileChange", id: itemId, changes });
          if (block) upsertBlock(msgId, block);
          fileChangeDiffs.set(itemId, changes.map((c) => c.diff ?? "").join("\n"));
        }
        break;
      }
      // Surfacing previously-dropped diagnostics. These have live emit sites.
      case "warning": {
        const m = (p.message as string) ?? "";
        if (m) toast(m, { description: "Warning" });
        break;
      }
      case "model/verification": {
        const v = (p.verifications as string[] | undefined) ?? [];
        if (v.length) toast(`Model verification: ${v.join(", ")}`);
        break;
      }
      case "account/updated":
      case "account/rateLimits/updated": {
        // Settings panels re-read account/rate-limit data when opened; nudge any
        // open view to refetch by re-broadcasting the (unchanged) snapshot.
        updateSnap((s) => ({ ...s }));
        break;
      }
      case "hook/started":
      case "hook/completed": {
        const run = p.run as { eventName?: string; status?: string } | undefined;
        if (threadId && run?.eventName) {
          pushTimeline(threadId, {
            kind: "branch",
            title: `Hook ${method === "hook/started" ? "started" : "finished"}: ${run.eventName}`,
            detail: run.status,
          });
        }
        break;
      }
      case "thread/status/changed": {
        const st = (p.status as { type?: string } | undefined)?.type;
        if (threadId && st) updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === threadId ? { ...t } : t)) }));
        break;
      }
      // Realtime-voice session output → per-thread realtime listeners.
      case "thread/realtime/started": { if (threadId) emitRealtime(threadId, { kind: "started" }); break; }
      case "thread/realtime/transcript/delta": {
        if (threadId) emitRealtime(threadId, { kind: "transcript-delta", role: (p.role as string) ?? "assistant", delta: (p.delta as string) ?? "" });
        break;
      }
      case "thread/realtime/transcript/done": {
        if (threadId) emitRealtime(threadId, { kind: "transcript-done", role: (p.role as string) ?? "assistant", text: (p.text as string) ?? "" });
        break;
      }
      case "thread/realtime/outputAudio/delta": {
        if (threadId) emitRealtime(threadId, { kind: "audio", audio: p.audio });
        break;
      }
      case "thread/realtime/closed": {
        if (threadId) emitRealtime(threadId, { kind: "closed", reason: (p.reason as string) ?? undefined });
        break;
      }
      default: break;
    }
  }

  async function ensureBound(threadId: string) {
    if (bound.has(threadId)) return;
    try { await rpc("thread/resume", { threadId }); bound.add(threadId); } catch { /* ignore */ }
  }

  async function refreshThreads() {
    // Fetch active AND archived threads. thread/list defaults to archived:false,
    // so the Archive page (which filters status==="archived") would otherwise
    // never receive any threads. Archived threads carry their activity status
    // (idle) on the wire, NOT an archived marker, so tag them by which query
    // they came from.
    const safe = (p: Promise<unknown>) => p.then((r) => (r as { data?: ThreadSummaryWire[] }).data ?? []).catch(() => [] as ThreadSummaryWire[]);
    try {
      const [active, archived] = await Promise.all([
        safe(rpc("thread/list", { archived: false })),
        safe(rpc("thread/list", { archived: true })),
      ]);
      const byId = new Map<string, Thread>();
      for (const t of active.map(mapThread)) byId.set(t.id, t);
      for (const t of archived.map((a) => ({ ...mapThread(a), status: "archived" as const }))) byId.set(t.id, t);
      updateSnap((s) => ({ ...s, threads: [...byId.values()] }));
    } catch { /* sidebar stays empty */ }
  }

  // Populate the sidebar/settings/plugins snapshot fields from the backend list
  // endpoints (all already exist). Best-effort + defensive: a failing/odd list
  // just leaves that section empty rather than breaking connect.
  async function hydrateSnapshot() {
    const tryRpc = async (m: string, p: Json = {}): Promise<Json> => {
      try { return await rpc(m, p); } catch { return null; }
    };
    const [skills, mcp, hooks, plugins, installed, apps, autos] = await Promise.all([
      tryRpc("skills/list", {}), tryRpc("mcpServerStatus/list", {}), tryRpc("hooks/list", {}),
      tryRpc("plugin/list", {}), tryRpc("plugin/installed", {}), tryRpc("app/list", {}),
      tryRpc("automation/action", { action: "list" }),
    ]);
    const automations = (((autos as { automations?: { id?: string; name?: string; schedule?: string }[] } | null)?.automations) ?? [])
      .map((a) => ({ id: a.id ?? uid("auto"), name: a.name ?? "Automation", schedule: a.schedule ?? "manual" }));
    updateSnap((s) => ({
      ...s,
      skills: mapSkills(skills),
      mcpServers: mapMcp(mcp),
      hooks: mapHooks(hooks),
      plugins: mapPlugins(plugins, installed),
      apps: mapApps(apps),
      automations: automations.length ? automations : s.automations,
    }));
  }

  // Load prior turns into snapshot.messages when opening an existing thread.
  // Guarded so it never duplicates messages already present from the live
  // stream (e.g. a freshly-created thread).
  async function loadThreadHistory(threadId: string) {
    // Skip threads created this session (live stream owns them; no server
    // history). For EXISTING threads we always load once — NOT gated on
    // "messages already present", since an optimistic bubble from a fast send
    // would otherwise permanently suppress loading the real prior turns.
    if (createdThisSession.has(threadId)) return;
    // Mark synchronously BEFORE the await so two concurrent subscribers (e.g.
    // the page + side panel both calling subscribeThread) can't each pass the
    // guard and double-load the same history.
    if (historyLoaded.has(threadId)) return;
    historyLoaded.add(threadId);
    try {
      const res = (await rpc("thread/read", { threadId, includeTurns: true })) as {
        thread?: { turns?: Array<{ id?: string; items?: unknown[] }> };
      };
      for (const turn of res.thread?.turns ?? []) {
        const turnId = turn.id ?? "";
        if (!turnId) continue;
        const items = turn.items ?? [];
        // userMessage items render as their own user bubble; agent items group
        // under the assistant message keyed by turnId.
        for (const raw of items) {
          const item = raw as ThreadItemWire;
          if (item.type === "userMessage") {
            const text = ((item as { content?: { text?: string }[] }).content ?? [])
              .map((c) => c.text ?? "").join("");
            if (text) appendMessage({ id: `u-${item.id}`, threadId, role: "user", blocks: [{ type: "markdown", content: text }], createdAt: Date.now() });
            continue;
          }
          const block = itemToBlock(item);
          if (block) { ensureAssistant(threadId, turnId); setPreamble(turnId, "Worked"); upsertBlock(turnId, block); }
        }
      }
    } catch {
      // Failed/transient load: release the guard so a later subscribe retries
      // (otherwise a single failed thread/read poisons the thread until the
      // socket reconnects).
      historyLoaded.delete(threadId);
    }
  }

  // ── Connector implementation ─────────────────────────────────────────────
  return {
    connect: async () => {
      if (ws && ws.readyState === WebSocket.OPEN) return;
      setStatus({ kind: "connecting" });
      await new Promise<void>((resolve, reject) => {
        ws = new WebSocket(url, opts.token ? [`bearer.${opts.token}`] : undefined);
        ws.onmessage = (ev) => onWireMessage(typeof ev.data === "string" ? ev.data : "");
        ws.onclose = () => { setStatus({ kind: "offline" }); pending.forEach((e) => e.reject(new Error("socket closed"))); pending.clear(); bound.clear(); historyLoaded.clear(); preOpenQueue = []; };
        ws.onerror = () => setStatus({ kind: "error", message: "websocket error" });
        ws.onopen = async () => {
          try {
            // Negotiate experimentalApi: the UI legitimately uses goal/*,
            // realtime/*, remoteControl/*, and collaborationMode/list, all of
            // which the backend gates behind this capability. The MethodGate
            // allowlist remains the security boundary (exec/fs/etc. stay denied).
            await rpc("initialize", {
              clientInfo: { name: "diminuendo-shadcn", version: "0.1.0" },
              capabilities: { experimentalApi: true },
            });
            setStatus({ kind: "connected", clientId: "codex" });
            // Flush RPCs that components queued before the socket opened (e.g.
            // settings panels reading config on first mount). Sent after
            // initialize so the backend sees the handshake first.
            const queued = preOpenQueue; preOpenQueue = []; queued.forEach((fn) => fn());
            await refreshThreads();
            void loadModels();
            void hydrateSnapshot();
            resolve();
          } catch (e) { reject(e); }
        };
      });
    },
    disconnect: async () => { ws?.close(); ws = null; setStatus({ kind: "offline" }); },
    onStatus: (cb) => { statusListeners.add(cb); cb(currentStatus); return () => statusListeners.delete(cb); },
    status: () => currentStatus,

    snapshot: async () => snap,
    onSnapshot: (cb) => { snapshotListeners.add(cb); cb(snap); return () => snapshotListeners.delete(cb); },

    subscribeThread: (threadId, _cb: (e: ThreadStreamEvent) => void) => {
      void ensureBound(threadId).then(() => loadThreadHistory(threadId));
      // Detach the sink on teardown so subscriptions don't accumulate.
      return async () => {
        bound.delete(threadId);
        await rpc("thread/unsubscribe", { threadId }).catch(() => {});
      };
    },

    sendMessage: async (threadId, text, opts?: SendOptions) => {
      await ensureBound(threadId);
      // Drain ONLY this thread's pending uploads. The home-composer ("shared")
      // bucket is re-keyed to a thread in createThread, never drained here, so
      // it can't leak into an unrelated thread.
      const drained = pendingUploads.get(threadId) ?? [];
      pendingUploads.delete(threadId);
      const images = drained.filter((a) => a.mime.startsWith("image/"));
      const files = drained.filter((a) => !a.mime.startsWith("image/"));

      // Optimistic user message: text + attachment blocks (served via /media).
      const blocks: MessageBlock[] = [];
      if (text) blocks.push({ type: "markdown", content: text });
      for (const a of images) blocks.push({ type: "image", url: a.url, alt: a.name });
      for (const a of files) blocks.push({ type: "ref", uri: a.url, title: a.name, refKind: "file" });
      appendMessage({ id: uid("u"), threadId, role: "user", blocks, createdAt: Date.now() });

      // Structured turn input ONLY — never splice the staged path into free
      // text (that would be a confused-deputy / prompt-injection surface).
      // Images → localImage; other files → a structured mention part.
      const input: Array<Record<string, unknown>> = [{ type: "text", text }];
      for (const a of images) input.push({ type: "localImage", path: a.path });
      for (const a of files) input.push({ type: "mention", path: a.path, name: a.name });

      // Forward the composer's model/effort/approval pickers (previously dropped).
      const params: Record<string, unknown> = { threadId, input };
      // Resolve the composer's display label ("5.5") to a REAL model id
      // ("gpt-5.5"). Sending the bare label made every real turn fail with
      // OpenAI `model_not_found`. If it can't be resolved, omit `model` so the
      // backend falls back to its configured default (config.model).
      const resolvedModel = resolveModelId(opts?.modelLabel);
      if (resolvedModel) params.model = resolvedModel;
      if (opts?.modelTier) {
        const t = String(opts.modelTier).toLowerCase();
        params.effort = t === "extra high" ? "high" : t;   // backend: low|medium|high
      }
      if (opts?.approval) {
        params.approvalPolicy = opts.approval === "full-access" ? "never" : "on-request";
        if (opts.approval === "read-only") params.sandboxPolicy = "read-only";
        else if (opts.approval === "full-access") params.sandboxPolicy = "danger-full-access";
      }

      try {
        await rpc("turn/start", params);
      } catch (e) {
        // Re-insert the drained uploads so a retry still carries them.
        if (drained.length) {
          pendingUploads.set(threadId, [...(pendingUploads.get(threadId) ?? []), ...drained]);
        }
        appendMessage({ id: uid("err"), threadId, role: "assistant", blocks: [{ type: "error", message: String(e) }], createdAt: Date.now() });
      }
    },
    interruptTurn: async (threadId) => {
      const turnId = activeTurn.get(threadId);
      if (turnId) await rpc("turn/interrupt", { threadId, turnId }).catch(() => {});
    },

    setThreadPinned: async (id, pinned) => {
      await rpc("thread/pin/set", { threadId: id, pinned }).catch(() => {});
      updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === id ? { ...t, pinned } : t)) }));
    },
    setThreadArchived: async (id, archived) => { await rpc(archived ? "thread/archive" : "thread/unarchive", { threadId: id }).catch(() => {}); await refreshThreads(); },
    setThreadUnread: async (id, unread) => updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === id ? { ...t, unread } : t)) })),
    renameThread: async (id, title) => {
      // Optimistically update the sidebar — thread/name/updated only fires to
      // connections subscribed to that thread, so renaming an unopened thread
      // would otherwise persist on the backend but never show in the UI.
      updateSnap((s) => ({ ...s, threads: s.threads.map((t) => (t.id === id ? { ...t, title } : t)) }));
      await rpc("thread/name/set", { threadId: id, name: title }).catch(() => {});
    },
    deleteThread: async (id) => {
      await rpc("thread/archive", { threadId: id }).catch(() => {});
      updateSnap((s) => ({ ...s, threads: s.threads.filter((t) => t.id !== id), messages: s.messages.filter((m) => m.threadId !== id) }));
    },
    openThreadInNewWindow: async (id) => { if (typeof window !== "undefined") window.open(`${window.location.origin}/thread/${id}`, "_blank", "noopener"); },
    forkThread: async (id) => { try { const r = (await rpc("thread/fork", { threadId: id })) as { thread?: { id?: string } }; return r.thread?.id ?? id; } catch { return id; } },
    togglePlugin: async (id, enabled) => { await rpc(enabled ? "plugin/install" : "plugin/uninstall", { pluginId: id }).catch(() => {}); },
    addAutomation: async (name, schedule) => {
      let a = { id: uid("auto"), name, schedule };
      try {
        const r = (await rpc("automation/action", { action: "create", name, schedule })) as { automation?: { id?: string; name?: string; schedule?: string } };
        if (r.automation?.id) a = { id: r.automation.id, name: r.automation.name ?? name, schedule: r.automation.schedule ?? schedule };
      } catch { /* keep local */ }
      updateSnap((s) => ({ ...s, automations: [...s.automations, a] }));
      return a;
    },
    deleteAutomation: async (id) => {
      await rpc("automation/action", { action: "delete", id }).catch(() => {});
      updateSnap((s) => ({ ...s, automations: s.automations.filter((a) => a.id !== id) }));
    },
    updateAutomation: async (id, patch) => {
      await rpc("automation/action", { action: "update", id, ...patch }).catch(() => {});
      updateSnap((s) => ({ ...s, automations: s.automations.map((a) => (a.id === id ? { ...a, ...patch } : a)) }));
    },
    runAutomation: async (id) => { await rpc("automation/action", { action: "run", id }).catch(() => {}); },

    createThread: async (projectId, title) => {
      const res = (await rpc("thread/start", {})) as { thread?: ThreadSummaryWire };
      const id = res.thread?.id ?? uid("t");
      bound.add(id);
      createdThisSession.add(id);
      // Adopt any home-composer ("shared") uploads into the thread they created.
      const shared = pendingUploads.get("shared");
      if (shared && shared.length) {
        pendingUploads.set(id, [...(pendingUploads.get(id) ?? []), ...shared]);
        pendingUploads.delete("shared");
      }
      const t: Thread = { id, projectId, title, status: "active", updatedAt: Date.now() };
      updateSnap((s) => ({ ...s, threads: [t, ...s.threads] }));
      return t;
    },

    respondToApproval: async (approvalId, decision, scope?: ApprovalScope) => {
      // Map the UI's coarse outcome + scope onto the backend ApprovalDecision
      // vocabulary. "allow always / don't ask again this session" → the real
      // acceptForSession (previously collapsed to a one-shot accept).
      const wire = decision === "cancelled" ? "cancel"
        : decision === "denied" ? "decline"
        : scope === "session" ? "acceptForSession" : "accept";
      reply(wireId(approvalId), { decision: wire });
      markApprovalDecided(approvalId, decision);
    },
    answerElicitation: async (requestId, accept, content) => {
      // MCP elicitation replies use {action, content} (NOT {decision}); the
      // result flows back verbatim to the MCP server.
      reply(wireId(requestId), accept ? { action: "accept", content: content ?? {} } : { action: "decline" });
      markApprovalDecided(requestId, accept ? "allowed" : "cancelled");
    },
    answerQuestion: async (requestId, values) => {
      // RequestUserInputResponse: { answers: { [id]: { answers: [..] } } }
      const answers = Object.fromEntries(
        Object.entries(values).map(([k, v]) => [k, { answers: [String(v)] }]));
      reply(wireId(requestId), { answers });
    },

    uploadFile: async (threadId, file): Promise<UploadedAttachment> => {
      const form = new FormData();
      form.append("threadId", threadId ?? "");
      form.append("file", file, file.name);
      const headers: Record<string, string> = {};
      if (opts.token) headers["Authorization"] = `Bearer ${opts.token}`;
      const res = await fetch("/api/upload", { method: "POST", body: form, headers });
      if (!res.ok) throw new Error(`upload failed: ${res.status}`);
      const r = (await res.json()) as UploadedAttachment;
      const key = threadId ?? "shared";
      pendingUploads.set(key, [...(pendingUploads.get(key) ?? []), r]);
      return r;
    },

    // ── extended capabilities (wired to existing backend endpoints) ──
    listModels: async () => {
      try {
        const r = (await rpc("model/list", {})) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map((m) => {
          const efforts = (m as { reasoningEfforts?: unknown[] }).reasoningEfforts;
          const tiers = Array.isArray(efforts)
            ? efforts.map((e) => { const s = String(e); return s.charAt(0).toUpperCase() + s.slice(1); })
            : ["Low", "Medium", "High"];
          return { id: pick(m, "id", "slug", "name"), label: pick(m, "displayName", "label", "name", "id"), tiers: tiers as ("Low" | "Medium" | "High")[] };
        });
      } catch { return []; }
    },
    readConfig: async () => { try { return ((await rpc("config/read", {})) as { config?: Record<string, unknown> }).config ?? {}; } catch { return {}; } },
    writeConfig: async (keyPath, value) => { await rpc("config/value/write", { keyPath, value, mergeStrategy: "replace" }).catch(() => {}); },
    readAccount: async () => { try { return (await rpc("account/read", {})) as { account?: unknown; requiresOpenaiAuth?: boolean }; } catch { return {}; } },
    readRateLimits: async () => { try { return (await rpc("account/rateLimits/read", {})) as Record<string, unknown>; } catch { return {}; } },
    searchFiles: async (query, roots) => { try { return ((await rpc("fuzzyFileSearch", { query, roots: roots ?? [] })) as { files?: string[] }).files ?? []; } catch { return []; } },
    getGoal: async (threadId) => {
      try {
        const g = ((await rpc("thread/goal/get", { threadId })) as { goal?: Record<string, unknown> }).goal;
        return g ? { objective: pick(g, "objective"), status: pick(g, "status") || "active", tokenBudget: (g.tokenBudget as number) ?? undefined, tokensUsed: (g.tokensUsed as number) ?? undefined } : null;
      } catch { return null; }
    },
    setGoal: async (threadId, objective, tokenBudget) => { await rpc("thread/goal/set", { threadId, objective, ...(tokenBudget != null ? { tokenBudget } : {}) }).catch(() => {}); },
    clearGoal: async (threadId) => { await rpc("thread/goal/clear", { threadId }).catch(() => {}); },
    rollbackTurns: async (threadId, numTurns) => { await rpc("thread/rollback", { threadId, numTurns }).catch(() => {}); },
    steerTurn: async (threadId, text) => { const turnId = activeTurn.get(threadId); if (turnId) await rpc("turn/steer", { threadId, input: [{ type: "text", text }], expectedTurnId: turnId }).catch(() => {}); },
    runShell: async (threadId, command) => { await ensureBound(threadId); await rpc("thread/shellCommand", { threadId, command }).catch(() => {}); },
    startReview: async (threadId, target) => { try { return ((await rpc("review/start", { threadId, target: { type: target } })) as { reviewThreadId?: string }).reviewThreadId ?? null; } catch { return null; } },
    setMemoryMode: async (threadId, enabled) => { await rpc("thread/memoryMode/set", { threadId, mode: enabled ? "enabled" : "disabled" }).catch(() => {}); },
    resetMemory: async () => { await rpc("memory/reset", null).catch(() => {}); },
    injectContext: async (threadId, text) => { await rpc("thread/inject_items", { threadId, items: [{ type: "text", text }] }).catch(() => {}); },
    remoteControlStatus: async () => { try { return (await rpc("remoteControl/status/read", {})) as Record<string, unknown>; } catch { return {}; } },
    enableRemoteControl: async () => { await rpc("remoteControl/enable", {}).catch(() => {}); },
    disableRemoteControl: async () => { await rpc("remoteControl/disable", {}).catch(() => {}); },
    addEnvironment: async (environmentId, execServerUrl) => { await rpc("environment/add", { environmentId, execServerUrl }).catch(() => {}); },
    listExperimentalFeatures: async () => { try { return (((await rpc("experimentalFeature/list", {})) as { data?: Record<string, unknown>[] }).data ?? []).map((f) => ({ id: pick(f, "id", "name"), enabled: (f as { enabled?: boolean }).enabled === true })); } catch { return []; } },
    setExperimentalFeature: async (id, enabled) => { await rpc("experimentalFeature/enablement/set", { enablement: { [id]: enabled } }).catch(() => {}); },
    reloadMcpServers: async () => { await rpc("config/mcpServer/reload", {}).catch(() => {}); },
    gitAction: async (threadId, action, opts) => {
      try { return (await rpc("git/action", { threadId, action, ...(opts ?? {}) })) as { ok: boolean; output: string; branch?: string }; }
      catch (e) { return { ok: false, output: String(e) }; }
    },
    listVoices: async () => {
      try {
        const r = (await rpc("thread/realtime/listVoices", {})) as {
          voices?: { v1?: string[]; v2?: string[] } | string[]; data?: string[];
        };
        const v = r.voices as { v1?: string[]; v2?: string[] } | string[] | Record<string, unknown> | undefined;
        const onlyStrings = (xs: unknown[]) => xs.filter((x): x is string => typeof x === "string");
        if (Array.isArray(v)) return onlyStrings(v);
        if (v && typeof v === "object") {
          // Backend shape is nested {v1:[…], v2:[…], defaultV1, defaultV2};
          // prefer the richer v2 set, fall back to v1, then to ANY string[]
          // value (defensive against a renamed key).
          const o = v as { v1?: unknown; v2?: unknown };
          if (Array.isArray(o.v2) && o.v2.length) return onlyStrings(o.v2);
          if (Array.isArray(o.v1) && o.v1.length) return onlyStrings(o.v1);
          for (const val of Object.values(v)) {
            if (Array.isArray(val) && val.some((x) => typeof x === "string")) return onlyStrings(val);
          }
        }
        return onlyStrings(r.data ?? []);
      } catch { return []; }
    },
    startRealtime: async (threadId, voice) => {
      await rpc("thread/realtime/start", { threadId, outputModality: "audio", ...(voice ? { voice } : {}) }).catch(() => {});
    },
    sendRealtimeText: async (threadId, text) => { await rpc("thread/realtime/appendText", { threadId, text }).catch(() => {}); },
    sendRealtimeAudio: async (threadId, data, sampleRate, numChannels) => {
      await rpc("thread/realtime/appendAudio", { threadId, audio: { data, sampleRate, numChannels } }).catch(() => {});
    },
    stopRealtime: async (threadId) => { await rpc("thread/realtime/stop", { threadId }).catch(() => {}); },
    onRealtime: (threadId, cb) => {
      const set = realtimeListeners.get(threadId) ?? new Set();
      set.add(cb); realtimeListeners.set(threadId, set);
      return () => { set.delete(cb); };
    },

    getDiff: async (threadId): Promise<DiffViewModel | null> => {
      const raw = latestDiff.get(threadId);
      if (!raw) return null;
      const files = parseUnifiedDiff(raw);
      if (files.length === 0) return null;
      const added = files.reduce((n, f) => n + f.added, 0);
      const removed = files.reduce((n, f) => n + f.removed, 0);
      const env: DiffEnvironment = {
        changes: { added, removed }, local: true, branch: "working tree",
        hasCommit: false, sources: [{ id: "local", label: "Local" }],
      };
      return { env, files };
    },
    getTimeline: async (threadId): Promise<TimelineEvent[]> => (timeline.get(threadId) ?? []).slice().reverse(),

    // ── Wiki (read-only; on-demand, never folded into the snapshot) ──
    listWikiPages: async (opts) => {
      try {
        const r = (await rpc("wiki/list", { limit: opts?.limit ?? 50 })) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map(mapWikiSummary);
      } catch { return []; }
    },
    getWikiPage: async (pageId) => {
      const n = Number(pageId);
      if (!Number.isInteger(n)) return null;   // non-numeric route → no round-trip
      try {
        const r = (await rpc("wiki/page/get", { id: n })) as Record<string, unknown> | null;
        return r ? mapWikiPage(r) : null;
      } catch { return null; }   // backend maps not-found to an error → null
    },
    searchWiki: async (query, opts) => {
      try {
        const r = (await rpc("wiki/search", { query, k: opts?.limit ?? 25 })) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map(mapWikiSummary);
      } catch { return []; }
    },
    getWikiGraph: async (opts) => {
      try {
        const params: Record<string, unknown> = {};
        if (opts?.seedEntityId) {
          const s = Number(opts.seedEntityId);
          if (Number.isInteger(s)) params.seed = s;   // entity id; skip if malformed
        }
        if (opts?.depth != null) params.depth = opts.depth;
        const r = (await rpc("wiki/graph", params)) as { nodes?: Record<string, unknown>[]; edges?: Record<string, unknown>[] };
        return {
          nodes: (r.nodes ?? []).map((n) => ({
            id: idStr(n.id),
            title: pick(n, "title", "canonical") || idStr(n.id),
            kind: pick(n, "kind") || undefined,
            weight: numOrU(n.weight),
          })),
          edges: (r.edges ?? []).map((e) => ({
            source: idStr(e.source ?? (e as { src?: unknown }).src),
            target: idStr(e.target ?? (e as { dst?: unknown }).dst),
            relation: pick(e, "relation") || undefined,
          })).filter((e) => e.source && e.target),
        };
      } catch { return { nodes: [], edges: [] }; }
    },
    getWikiTags: async () => {
      try {
        const r = (await rpc("wiki/tags", {})) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map((t) => ({ tag: pick(t, "tag", "name"), count: numOrU(t.count) ?? 0 })).filter((t) => t.tag);
      } catch { return []; }
    },
    getWikiEntityBacklinks: async (entityId) => {
      const n = Number(entityId);
      if (!Number.isInteger(n)) return [];
      try {
        const r = (await rpc("wiki/entityBacklinks", { entityId: n })) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map(mapWikiSummary);
      } catch { return []; }
    },
    getWikiIndex: async () => {
      try {
        const r = (await rpc("wiki/index", {})) as { data?: Record<string, unknown>[] };
        return (r.data ?? []).map(mapWikiIndexEntry).filter((e) => e.id);
      } catch { return []; }
    },
    saveWikiPage: async (input) => {
      const params: Record<string, unknown> = { body: input.body };
      if (input.title != null) params.title = input.title;
      if (input.id) {
        const n = Number(input.id);
        if (Number.isInteger(n)) params.id = n;   // omit id → create new page
      }
      const r = (await rpc("wiki/page/upsert", params)) as { id?: unknown };
      const id = idStr(r?.id);
      return id ? { id } : null;
    },
    deleteWikiPage: async (pageId) => {
      const n = Number(pageId);
      if (!Number.isInteger(n)) return null;   // non-numeric route → no round-trip
      try {
        const r = (await rpc("wiki/page/delete", { id: n })) as { deleted?: unknown };
        return { deleted: r?.deleted === true };
      } catch { return null; }
    },
    renameWikiPage: async (pageId, title) => {
      const n = Number(pageId);
      if (!Number.isInteger(n)) return null;
      try {
        const r = (await rpc("wiki/page/rename", { id: n, title })) as { renamed?: unknown };
        return { renamed: r?.renamed === true };
      } catch { return null; }
    },
    getWikiBrief: async (topic, opts) => {
      try {
        // The backend returns the WikiBriefPayload object directly (parsed).
        const r = (await rpc("wiki/brief", { topic, k: opts?.k ?? 8 })) as WikiBrief;
        return r ?? null;
      } catch { return null; }
    },
    getWikiStatus: async () => {
      try {
        const r = (await rpc("wiki/status", {})) as {
          documents?: number; pages?: number; flaggedStale?: number;
          recentJobs?: Record<string, unknown>[];
        };
        return {
          documents: r.documents ?? 0,
          pages: r.pages ?? 0,
          flaggedStale: r.flaggedStale ?? 0,
          recentJobs: (r.recentJobs ?? []).map((j) => ({
            jobID: idStr(j.jobID),
            input: pick(j, "input") || "",
            status: pick(j, "status") || "",
            adapter: pick(j, "adapter") || undefined,
            candidates: numOrU(j.candidates) ?? 0,
            written: numOrU(j.written) ?? 0,
            skipped: numOrU(j.skipped) ?? 0,
            failed: numOrU(j.failed) ?? 0,
            startedAt: numOrU(j.startedAt),
          })),
        };
      } catch { return null; }
    },
    getWikiWatch: async () => {
      try {
        const r = (await rpc("wiki/watch/list", {})) as { watched?: Record<string, unknown>[] };
        return (r.watched ?? []).map((w) => ({
          id: idStr(w.id),
          cadence: pick(w, "cadence") || "warm",
          status: pick(w, "status") || "active",
          nextDueAt: numOrU(w.nextDueAt),
          errorCount: numOrU(w.errorCount) ?? 0,
          due: w.due === true,
        }));
      } catch { return []; }
    },
  };
}

// ── Wiki mappers (ids arrive as integers on the wire; stringify for routing). ──
// Exported for characterization tests (see connectorWikiMappers.test.ts) — they
// lock the wire contract between the Swift wiki/* RPCs and the UI types.
export function idStr(v: unknown): string {
  if (typeof v === "number") return String(v);
  if (typeof v === "string") return v;
  return "";
}
function numOrU(v: unknown): number | undefined {
  return typeof v === "number" ? v : undefined;
}
function normalizeEpochMs(v: unknown): number | undefined {
  if (typeof v !== "number" || v <= 0) return undefined;
  return v < 1e12 ? v * 1000 : v;
}
export function mapWikiSummary(o: Record<string, unknown>): WikiPageSummary {
  return {
    id: idStr(o.id),
    title: pick(o, "title", "name") || "Untitled",
    excerpt: pick(o, "excerpt", "snippet", "preview") || undefined,
    source: pick(o, "source") || undefined,
    updatedAt: normalizeEpochMs(o.updatedAt),
  };
}
export function mapWikiPage(o: Record<string, unknown>): WikiPage {
  const tags = Array.isArray(o.tags) ? (o.tags as unknown[]).filter((t): t is string => typeof t === "string") : undefined;
  const connections = Array.isArray(o.connections)
    ? (o.connections as Record<string, unknown>[]).map((c) => ({
        entityId: idStr(c.entityId),
        canonical: pick(c, "canonical"),
        kind: pick(c, "kind"),
        relation: pick(c, "relation"),
        weight: numOrU(c.weight),
      })).filter((c) => c.canonical)
    : undefined;
  return {
    ...mapWikiSummary(o),
    content: pick(o, "content", "body", "markdown"),
    tags: tags?.length ? tags : undefined,
    connections: connections?.length ? connections : undefined,
  };
}

/** Map one wire `wiki/index` entry → WikiIndexEntry (string links + props only,
 *  id stringified). Extracted from the connector closure for unit testing. */
export function mapWikiIndexEntry(e: Record<string, unknown>): { id: string; title: string; links: string[]; props: Record<string, string> } {
  const links = Array.isArray(e.links)
    ? (e.links as unknown[]).filter((x): x is string => typeof x === "string")
    : [];
  const props: Record<string, string> = {};
  const rawProps = e.props;
  if (rawProps && typeof rawProps === "object") {
    for (const [k, v] of Object.entries(rawProps as Record<string, unknown>)) {
      if (typeof v === "string") props[k] = v;
    }
  }
  return { id: idStr(e.id), title: pick(e, "title"), links, props };
}

// ── block / delta helpers ───────────────────────────────────────────────────

function mergeDelta(b: MessageBlock, bid: string, delta: BlockDelta): MessageBlock {
  if ((b as { blockId?: string }).blockId !== bid) return b;
  if (delta.kind === "text-append" && (b.type === "markdown" || b.type === "thinking")) {
    return { ...b, content: b.content + delta.text } as MessageBlock;
  }
  if (delta.kind === "stdout-append") {
    if (b.type === "shell") return { ...b, output: (b.output ?? "") + delta.text };
    if (b.type === "code-result") return { ...b, content: b.content + delta.text };
  }
  return b;
}

interface ThreadSummaryWire { id?: string; name?: string | null; preview?: string; status?: { type?: string }; updatedAt?: number; pinned?: boolean; }
interface ThreadItemWire {
  type?: string; id?: string; text?: string; content?: string[]; summary?: string[];
  command?: string; cwd?: string; aggregatedOutput?: string | null; exitCode?: number | null;
  commandActions?: { type?: string; command?: string }[];
  status?: string;
  changes?: { path?: string; diff?: string; kind?: { type?: string; movePath?: string } | string }[];
  // Defensive: fields a future imageView / imageGeneration item might carry.
  url?: string; path?: string; mimeType?: string;
}

function mapThread(t: ThreadSummaryWire): Thread {
  // app-server emits epoch SECONDS; the UI expects ms. Convert (and fall back
  // to now for unset/zero) — otherwise the sidebar shows "686mo".
  const raw = typeof t.updatedAt === "number" && t.updatedAt > 0 ? t.updatedAt : Date.now();
  const updated = raw < 1e12 ? raw * 1000 : raw;
  return {
    id: t.id ?? "", projectId: DEFAULT_PROJECT.id,
    title: t.name || t.preview || "Untitled",
    status: t.status?.type === "archived" ? "archived" : "active",
    updatedAt: updated,
    pinned: t.pinned ?? false,
  };
}

function mapItemStatus(s?: string): "streaming" | "ok" | "error" | "cancelled" | undefined {
  if (s === "inProgress") return "streaming";
  if (s === "completed") return "ok";
  if (s === "failed") return "error";
  if (s === "declined") return "cancelled";
  return undefined;
}

// Convert a JSON-Schema object (MCP elicitation `requestedSchema`) into the
// UI's QuestionField[] — title→label, enum→choice, boolean→boolean, else text.
function schemaToFields(schema?: Record<string, unknown>): import("@/domain/models").QuestionField[] {
  const props = (schema?.properties as Record<string, Record<string, unknown>> | undefined) ?? {};
  const required = new Set((schema?.required as string[] | undefined) ?? []);
  return Object.entries(props).map(([id, def]) => {
    const enumVals = def.enum as string[] | undefined;
    const kind = Array.isArray(enumVals) && enumVals.length ? "choice" : def.type === "boolean" ? "boolean" : "text";
    return {
      id,
      label: (def.title as string) || (def.description as string) || id,
      kind: kind as "text" | "choice" | "boolean",
      required: required.has(id),
      options: enumVals,
    };
  });
}

// A commandExecution item is the wire shape for ALL tool invocations in this
// backend (MCP calls, web_search, and real shell). Route the recognisable tool
// calls to their purpose-built blocks; everything else is a genuine shell exec.
function commandBlock(item: ThreadItemWire, bid: string): MessageBlock {
  const cmd = item.command ?? "";
  const status = mapItemStatus(item.status);
  if (cmd.startsWith("mcp__")) {
    // mcp__<server>__<tool> → "server · tool"
    const parts = cmd.split("__").filter(Boolean);
    const tool = parts.length >= 3 ? `${parts[1]} · ${parts.slice(2).join("__")}` : cmd;
    return { type: "tool-call", blockId: bid, tool, args: {}, result: item.aggregatedOutput ?? undefined, status };
  }
  if (cmd === "web_search" || cmd.startsWith("web_search ")) {
    return { type: "tool-call", blockId: bid, tool: "web_search", args: {}, result: item.aggregatedOutput ?? undefined, summary: "Web search", status };
  }
  return { type: "shell", blockId: bid, cmd, cwd: item.cwd ?? undefined, output: item.aggregatedOutput ?? undefined, exitCode: item.exitCode ?? undefined, status };
}

// One ThreadItem → one MessageBlock (blockId = item.id). userMessage skipped
// (the composer renders the user's text optimistically in sendMessage).
function itemToBlock(item?: ThreadItemWire): MessageBlock | null {
  if (!item || !item.id) return null;
  const bid = item.id;
  const any = item as Record<string, unknown>;
  switch (item.type) {
    case "userMessage": return null;
    // Internal developer/user context (permissions, skills, AGENTS.md, env) —
    // appended to model history + rollout but NOT a user-facing chat item. It
    // surfaces in thread/read history; never render it (was dumped as raw JSON).
    case "contextMessage": return null;
    case "agentMessage": return { type: "markdown", blockId: bid, content: item.text ?? "", status: mapItemStatus(item.status) };
    case "reasoning": {
      // Reasoning persists its visible text in `summary`; `content` is usually
      // empty (raw CoT, often encrypted). Prefer summary, fall back to content.
      const summary = item.summary ?? [];
      const body = (summary.length ? summary : item.content ?? []).join("\n");
      return { type: "thinking", blockId: bid, content: body, status: mapItemStatus(item.status) };
    }
    case "commandExecution": return commandBlock(item, bid);
    case "fileChange": {
      const changes = item.changes ?? [];
      let added = 0, removed = 0;
      for (const c of changes) { const n = countDiff(c.diff); added += n.added; removed += n.removed; }
      if (changes.length === 1 && changes[0].path) {
        const n = countDiff(changes[0].diff);
        return { type: "diff", blockId: bid, path: changes[0].path, unifiedDiff: changes[0].diff, added: n.added, removed: n.removed };
      }
      return {
        type: "diff-summary", blockId: bid,
        label: `${changes.length} file${changes.length === 1 ? "" : "s"} changed`,
        added, removed,
        files: changes.map((c) => { const n = countDiff(c.diff); return { path: c.path ?? "", delta: `+${n.added} −${n.removed}` }; }),
      };
    }
    case "collabAgentToolCall": {
      const receivers = any.receiverThreadIds as string[] | undefined;
      const tool = String(any.tool ?? "agent");
      return {
        type: "sub-agent", blockId: bid, agentId: tool, agentName: tool,
        goal: (any.prompt as string) ?? "", childThreadId: receivers?.[0],
        status: item.status === "completed" ? "ok" : item.status === "failed" ? "error" : "running",
      };
    }
    case "enteredReviewMode": return { type: "section-heading", blockId: bid, label: (any.review as string) || "Review mode" };
    case "exitedReviewMode": return { type: "summary", blockId: bid, content: (any.review as string) || "Review complete" };
    case "contextCompaction": return { type: "compaction", blockId: bid, summary: "Context compacted", compactedCount: 0 };
    // Defensive: upstream image items (never emitted by this backend today, but
    // decode-tolerated). Render inline when a fetchable URL is present.
    case "imageView":
    case "imageGeneration": {
      const url = (item.url as string) || "";
      if (url) return { type: "image", blockId: bid, url, alt: item.type };
      return { type: "json", blockId: bid, value: item };
    }
    default: return { type: "json", blockId: bid, value: item };
  }
}

// parseUnifiedDiff + countDiff now live in @/lib/diff (shared with DiffBlock).

// ── defensive list mappers (backend list shapes → domain snapshot types) ──────
/* eslint-disable @typescript-eslint/no-explicit-any */
function asArray(x: Json): any[] {
  if (Array.isArray(x)) return x;
  const d = (x as { data?: unknown } | null)?.data;
  return Array.isArray(d) ? d : [];
}
function pick(o: any, ...keys: string[]): string {
  for (const k of keys) if (typeof o?.[k] === "string" && o[k]) return o[k];
  return "";
}
function mapSkills(x: Json): Skill[] {
  return asArray(x).map((o: any, i: number) => ({
    id: pick(o, "id", "name") || `skill-${i}`,
    name: pick(o, "name", "id"),
    description: pick(o, "description", "summary"),
    enabled: o?.enabled !== false,
    source: (o?.source as Skill["source"]) ?? undefined,
  }));
}
function mapMcp(x: Json): McpServer[] {
  return asArray(x).map((o: any, i: number) => {
    const st = pick(o, "status");
    const status: McpServer["status"] =
      st === "ready" || st === "connected" ? "connected"
      : st === "starting" || st === "connecting" ? "connecting"
      : st === "failed" || st === "error" ? "error" : "disabled";
    const tools = Array.isArray(o?.tools) ? o.tools.map((t: any) => (typeof t === "string" ? t : pick(t, "name"))) : undefined;
    return {
      id: pick(o, "id", "name") || `mcp-${i}`,
      name: pick(o, "name", "serverName", "id"),
      command: pick(o, "command", "transport"),
      status,
      toolCount: typeof o?.toolCount === "number" ? o.toolCount : (tools?.length ?? 0),
      tools,
      source: (o?.source as McpServer["source"]) ?? undefined,
    };
  });
}
function mapHooks(x: Json): Hook[] {
  const out: Hook[] = [];
  for (const g of asArray(x)) {
    const hs = Array.isArray(g?.hooks) ? g.hooks : (g?.event || g?.command ? [g] : []);
    for (const h of hs) {
      out.push({
        id: pick(h, "id") || `${pick(h, "event", "eventName")}-${out.length}`,
        event: pick(h, "event", "eventName", "type"),
        command: pick(h, "command", "cmd"),
        enabled: h?.enabled !== false,
      });
    }
  }
  return out;
}
function mapPlugins(list: Json, installed: Json): Plugin[] {
  const installedIds = new Set(asArray(installed).map((o: any) => pick(o, "id", "name")));
  return asArray(list).map((o: any, i: number) => {
    const id = pick(o, "id", "name") || `plugin-${i}`;
    return {
      id,
      name: pick(o, "name", "id"),
      description: pick(o, "description", "summary"),
      icon: pick(o, "icon") || "🧩",
      category: ["All"] as Plugin["category"],
      installed: installedIds.has(id) || o?.installed === true,
    };
  });
}
function mapApps(x: Json): PluginApp[] {
  return asArray(x).map((o: any, i: number) => {
    const name = pick(o, "name", "id") || `App ${i}`;
    return {
      id: pick(o, "id", "name") || `app-${i}`,
      name,
      description: pick(o, "description", "summary"),
      iconLetter: name.charAt(0).toUpperCase() || "A",
      iconBg: "var(--color-surface-hover)",
      enabled: o?.enabled !== false,
    };
  });
}
/* eslint-enable @typescript-eslint/no-explicit-any */
