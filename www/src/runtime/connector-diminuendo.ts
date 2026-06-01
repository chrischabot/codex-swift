// DiminuendoConnector — adapter for the diminuendo Fabric client. The
// @igentai/dim-shared package only resolves inside the diminuendo monorepo;
// dynamic-import keeps this file compilable everywhere else.
//
// Wiring expectations:
//   import { makeDiminuendoConnector } from "@/runtime/connector-diminuendo";
//   <RuntimeProvider factory={() => makeDiminuendoConnector({
//     gateway: "ws://127.0.0.1:8001",
//     token: process.env.DIM_TOKEN,
//   })}>
//
// The block-kind mapper below covers every variant the survey enumerated
// (text, markdown, thinking, summary, code, code_result, terminal, diff,
// json, ui_spec, tool_call, tool_result, image, audio, video, document,
// resource_ref/file_ref/artifact_ref, citation_list). Approval / Plan /
// Mission / Compaction / Sandbox / SubAgent come through as side events
// (approval/request, plan/update, mission/state, …) and are mapped into the
// matching block kinds so they land in the conversation history.

import type {
  Automation,
  Message,
  MessageBlock,
  Thread,
} from "@/domain/models";
import type {
  BlockDelta,
  Connector,
  ConnectorSnapshot,
  ConnectorStatus,
  DiffViewModel,
  SendOptions,
  ThreadStreamEvent,
} from "./connector";

export interface DiminuendoConnectorOptions {
  gateway: string;     // e.g. "ws://127.0.0.1:8001"
  token?: string;
}

// Minimal structural shape matching the methods we exercise on the real
// `DiminuendoFabricClient`. Keeps this file typed without needing the
// shared package on disk.
interface FabricClientLike {
  connect: (endpoint?: string, token?: string) => Promise<void>;
  disconnect: () => Promise<void>;
  connected: boolean;
  listThreads: (includeArchived?: boolean) => Promise<{ threads: unknown[] }>;
  getThread: (id: string) => Promise<{ thread: unknown }>;
  startTurn: (threadId: string, input: unknown[]) => Promise<unknown>;
  cancelTurn: (threadId: string, turnId: string) => Promise<void>;
  subscribeToThread: (threadId: string, onEvent?: (e: FabricEvent) => void) => Promise<void>;
  unsubscribeFromThread: (threadId: string) => Promise<void>;
  archiveThread: (threadId: string) => Promise<void>;
  unarchiveThread: (threadId: string) => Promise<void>;
  updateThread: (threadId: string, title?: string) => Promise<void>;
  respondToApproval: (approvalId: string, decision: string) => Promise<void>;
  onEvent: (h: (e: FabricEvent) => void) => () => void;
}

interface DimSharedModule {
  DiminuendoFabricClient: new () => FabricClientLike;
}

interface FabricEvent {
  type: string;
  threadId?: string;
  thread_id?: string;
  turnId?: string;
  itemId?: string;
  blockId?: string;
  block?: FabricBlock;
  delta?: { deltaKind?: string; text?: string; json_patch?: unknown };
  payload?: unknown;
  title?: string;
  approvalId?: string;
  decision?: string;
  // Plan / Mission / Token / Model side events
  plan?: { steps: { id: string; content: string; status: string }[]; title?: string };
  mission?: {
    missionId: string;
    status: string;
    features: { id: string; label: string; status: string }[];
    metrics: { elapsed: number; completed: number; failed: number; total: number };
  };
  usage?: { input: number; output: number; cacheRead?: number };
  model?: { from?: string; to: string; reason?: string };
  compaction?: { summary: string; compactedCount: number };
  sandbox?: { event: string; sandboxId: string; cwd?: string; durationMs?: number };
}

interface FabricBlock {
  blockId?: string;
  blockKind: string;
  status?: string;
  text?: string;
  code?: string;
  language?: string;
  content?: string;
  terminalId?: string;
  exitCode?: number | null;
  path?: string;
  oldText?: string | null;
  newText?: string;
  unifiedDiff?: string;
  json?: unknown;
  uri?: string;
  title?: string;
  url?: string;
  blobId?: string;
  filename?: string;
  mimeType?: string;
  citations?: { title?: string; url: string; snippet?: string }[];
  // Tool-call envelope
  toolName?: string;
  args?: Record<string, unknown>;
  result?: string;
}

export async function makeDiminuendoConnector(
  opts: DiminuendoConnectorOptions,
): Promise<Connector> {
  // Dynamic import with `/* @vite-ignore */` so the bundler doesn't try to
  // resolve `@igentai/dim-shared` at build time (it isn't installed outside
  // the diminuendo monorepo). Works under strict CSP — no eval involved.
  const specifier = "@igentai/dim-shared";
  const mod = (await import(/* @vite-ignore */ specifier)) as DimSharedModule;
  const client = new mod.DiminuendoFabricClient();

  let currentStatus: ConnectorStatus = { kind: "connecting" };
  const statusListeners = new Set<(s: ConnectorStatus) => void>();
  const setStatus = (s: ConnectorStatus) => {
    currentStatus = s;
    statusListeners.forEach((l) => l(s));
  };

  let snap: ConnectorSnapshot = {
    projects: [],
    threads: [],
    messages: [],
    plugins: [],
    apps: [],
    automations: [],
    automationTemplates: [],
    mcpServers: [],
    skills: [],
    hooks: [],
  };
  const snapshotListeners = new Set<(s: ConnectorSnapshot) => void>();
  const notifySnapshot = () => snapshotListeners.forEach((l) => l(snap));
  const update = (mut: (s: ConnectorSnapshot) => ConnectorSnapshot) => {
    snap = mut(snap);
    notifySnapshot();
  };

  const threadSubscribers = new Map<string, Set<(e: ThreadStreamEvent) => void>>();
  const emit = (threadId: string, event: ThreadStreamEvent) => {
    threadSubscribers.get(threadId)?.forEach((cb) => cb(event));
  };

  client.onEvent((evt) => {
    const threadId = evt.threadId ?? evt.thread_id;
    if (!threadId) return;

    switch (evt.type) {
      case "presentation.item_created":
      case "presentation.item_updated": {
        // Whole-item snapshot — we treat each item as one assistant message
        // and rebuild its blocks. The MockConnector emits granular block-
        // appended events instead; we accept both shapes here.
        const block = blockToMessageBlock(evt.block);
        if (block && evt.itemId) {
          emit(threadId, { kind: "block-appended", threadId, messageId: evt.itemId, block });
        }
        break;
      }
      case "presentation.block_started": {
        const block = blockToMessageBlock(evt.block);
        if (block && evt.itemId) {
          emit(threadId, { kind: "block-appended", threadId, messageId: evt.itemId, block });
        }
        break;
      }
      case "presentation.block_delta": {
        if (evt.itemId && evt.blockId && evt.delta) {
          const delta = mapDelta(evt.delta);
          if (delta) {
            emit(threadId, { kind: "block-delta", threadId, messageId: evt.itemId, blockId: evt.blockId, delta });
          }
        }
        break;
      }
      case "presentation.block_completed": {
        if (evt.itemId && evt.blockId) {
          const status = (evt.block?.status as "ok" | "error" | "cancelled") ?? "ok";
          emit(threadId, { kind: "block-status", threadId, messageId: evt.itemId, blockId: evt.blockId, status });
        }
        break;
      }
      case "presentation.item_completed":
      case "conversation.turn_ended": {
        if (evt.itemId) {
          emit(threadId, { kind: "message-complete", threadId, messageId: evt.itemId });
        }
        break;
      }
      case "thread.title":
      case "thread/title": {
        if (evt.title) emit(threadId, { kind: "title-update", threadId, title: evt.title });
        break;
      }
      case "approval.request":
      case "approval/request": {
        const messageId = evt.itemId ?? "";
        const block = blockToMessageBlock(evt.block);
        if (block && block.type === "approval") {
          emit(threadId, { kind: "approval-pending", threadId, messageId, block });
        }
        break;
      }
      case "approval.decided":
      case "conversation.approval_responded": {
        if (evt.approvalId && evt.decision) {
          emit(threadId, {
            kind: "approval-decided",
            threadId,
            approvalId: evt.approvalId,
            decision: normaliseDecision(evt.decision),
          });
        }
        break;
      }
      case "plan.update":
      case "plan/update": {
        if (evt.plan && evt.itemId) {
          const block: Extract<MessageBlock, { type: "plan" }> = {
            type: "plan",
            blockId: evt.blockId,
            title: evt.plan.title,
            steps: evt.plan.steps.map((s) => ({
              id: s.id,
              content: s.content,
              status:
                s.status === "completed" ? "completed" :
                s.status === "in_progress" ? "in_progress" : "pending",
            })),
          };
          emit(threadId, { kind: "plan-update", threadId, messageId: evt.itemId, block });
        }
        break;
      }
      case "mission.update":
      case "mission/state": {
        if (evt.mission && evt.itemId) {
          const block: Extract<MessageBlock, { type: "mission" }> = {
            type: "mission",
            blockId: evt.blockId,
            missionId: evt.mission.missionId,
            status: (evt.mission.status as Extract<MessageBlock, { type: "mission" }>["status"]) ?? "running",
            features: evt.mission.features.map((f) => ({
              id: f.id,
              label: f.label,
              status: f.status as Extract<MessageBlock, { type: "mission" }>["features"][number]["status"],
            })),
            metrics: evt.mission.metrics,
          };
          emit(threadId, { kind: "mission-update", threadId, messageId: evt.itemId, block });
        }
        break;
      }
      case "compaction.applied":
      case "compaction": {
        if (evt.compaction && evt.itemId) {
          const block: Extract<MessageBlock, { type: "compaction" }> = {
            type: "compaction",
            blockId: evt.blockId,
            summary: evt.compaction.summary,
            compactedCount: evt.compaction.compactedCount,
          };
          emit(threadId, { kind: "compaction", threadId, messageId: evt.itemId, block });
        }
        break;
      }
      case "sandbox.event":
      case "sandbox": {
        if (evt.sandbox) {
          emit(threadId, {
            kind: "sandbox",
            threadId,
            event: (evt.sandbox.event as "starting" | "ready" | "stopped" | "crashed") ?? "ready",
            sandboxId: evt.sandbox.sandboxId,
            cwd: evt.sandbox.cwd,
            durationMs: evt.sandbox.durationMs,
          });
        }
        break;
      }
      case "token-usage":
      case "conversation.token_usage": {
        if (evt.usage) emit(threadId, { kind: "token-usage", threadId, usage: evt.usage });
        break;
      }
      case "model.switch":
      case "model-switch": {
        if (evt.model) emit(threadId, { kind: "model-switch", threadId, from: evt.model.from, to: evt.model.to, reason: evt.model.reason });
        break;
      }
      default:
        // Forwards thread_sync_*, sdk_connected, voice_*, etc. — not part of
        // our UI surface (yet).
        break;
    }
  });

  const refreshThreads = async () => {
    const { threads } = await client.listThreads(false);
    update((s) => ({ ...s, threads: threads.map(mapThread) }));
  };

  await (async () => {
    try {
      await client.connect(opts.gateway, opts.token);
      setStatus({ kind: "connected", clientId: "diminuendo" });
      await refreshThreads();
    } catch (err) {
      setStatus({ kind: "error", message: String(err) });
      throw err;
    }
  })();

  return {
    connect: async () => {
      if (!client.connected) await client.connect(opts.gateway, opts.token);
    },
    disconnect: async () => {
      await client.disconnect();
      setStatus({ kind: "offline" });
    },
    onStatus: (cb) => {
      statusListeners.add(cb);
      cb(currentStatus);
      return () => { statusListeners.delete(cb); };
    },
    status: () => currentStatus,

    snapshot: async () => snap,
    onSnapshot: (cb) => {
      snapshotListeners.add(cb);
      cb(snap);
      return () => { snapshotListeners.delete(cb); };
    },

    subscribeThread: (threadId, cb) => {
      let set = threadSubscribers.get(threadId);
      if (!set) {
        set = new Set();
        threadSubscribers.set(threadId, set);
      }
      set.add(cb);
      void client.subscribeToThread(threadId).catch(() => {});
      return async () => {
        set!.delete(cb);
        if (set!.size === 0) {
          threadSubscribers.delete(threadId);
          await client.unsubscribeFromThread(threadId).catch(() => {});
        }
      };
    },

    sendMessage: async (threadId, text) => {
      await client.startTurn(threadId, [{ kind: "text", text }]);
    },
    interruptTurn: async (threadId) => {
      await client.cancelTurn(threadId, "active").catch(() => {});
    },

    setThreadPinned: async () => { /* server-side flag pending */ },
    setThreadArchived: async (id, archived) => {
      if (archived) await client.archiveThread(id);
      else await client.unarchiveThread(id);
      await refreshThreads();
    },
    setThreadUnread: async (id, unread) =>
      update((s) => ({
        ...s,
        threads: s.threads.map((t) => (t.id === id ? { ...t, unread } : t)),
      })),
    renameThread: async (id, title) => {
      await client.updateThread(id, title);
      await refreshThreads();
    },
    deleteThread: async (id) => {
      // Server delete pending; remove locally so the UI stays consistent.
      update((s) => ({
        ...s,
        threads: s.threads.filter((t) => t.id !== id),
        messages: s.messages.filter((m) => m.threadId !== id),
      }));
    },
    openThreadInNewWindow: async (id) => {
      if (typeof window !== "undefined") {
        window.open(`${window.location.origin}/thread/${id}`, "_blank", "noopener");
      }
    },
    forkThread: async (id) => id,
    togglePlugin: async () => { /* plugins live in integrations store; phase 4 */ },
    addAutomation: async (name, schedule) => {
      const auto: Automation = { id: `auto-${Date.now()}`, name, schedule };
      update((s) => ({ ...s, automations: [...s.automations, auto] }));
      return auto;
    },
    deleteAutomation: async (id) =>
      update((s) => ({ ...s, automations: s.automations.filter((a) => a.id !== id) })),
    updateAutomation: async (id, patch) =>
      update((s) => ({
        ...s,
        automations: s.automations.map((a) => (a.id === id ? { ...a, ...patch } : a)),
      })),

    createThread: async (projectId, title) => {
      const resp = await (client as unknown as { createThread: (input: unknown[], meta?: unknown) => Promise<{ threadId?: string; id?: string }> })
        .createThread([{ kind: "text", text: title }], { projectId });
      const t: Thread = {
        id: resp.threadId ?? resp.id ?? `t-${Date.now()}`,
        projectId,
        title,
        status: "active",
        updatedAt: Date.now(),
      };
      update((s) => ({ ...s, threads: [...s.threads, t] }));
      return t;
    },

    respondToApproval: async (approvalId, decision) => {
      const dim =
        decision === "allowed" ? "allow_once" :
        decision === "denied"  ? "deny_once"  :
        "cancel";
      await client.respondToApproval(approvalId, dim);
    },

    getDiff: async (): Promise<DiffViewModel | null> => null,

    getTimeline: async () => [],
  };
}

// ────────────────────────────── mapping helpers ──────────────────────────────

function mapThread(t: unknown): Thread {
  const r = t as { id?: string; threadId?: string; projectId?: string; project_id?: string; title?: string; name?: string; status?: string; pinned?: boolean; updatedAt?: number; updated_at?: number };
  return {
    id: r.id ?? r.threadId ?? "",
    projectId: r.projectId ?? r.project_id ?? null,
    title: r.title ?? r.name ?? "Untitled",
    status: r.status === "archived" ? "archived" : "active",
    pinned: !!r.pinned,
    updatedAt: r.updatedAt ?? r.updated_at ?? Date.now(),
  };
}

function mapDelta(d: NonNullable<FabricEvent["delta"]>): BlockDelta | null {
  if (d.deltaKind === "text" || d.text != null) return { kind: "text-append", text: d.text ?? "" };
  if (d.deltaKind === "stdout") return { kind: "stdout-append", text: d.text ?? "" };
  if (d.deltaKind === "json_replace") return { kind: "json-replace", value: d.json_patch };
  return null;
}

function normaliseDecision(d: string): "allowed" | "denied" | "cancelled" {
  if (d.startsWith("allow")) return "allowed";
  if (d === "cancel") return "cancelled";
  return "denied";
}

function blockToMessageBlock(b?: FabricBlock): MessageBlock | null {
  if (!b) return null;
  const blockId = b.blockId;
  switch (b.blockKind) {
    case "text":
    case "markdown":
      return { type: "markdown", blockId, content: b.text ?? b.content ?? "" };
    case "thinking":
      return { type: "thinking", blockId, content: b.text ?? b.content ?? "", status: mapStatus(b.status) };
    case "summary":
      return { type: "summary", blockId, content: b.text ?? b.content ?? "" };
    case "code":
      return { type: "code", blockId, language: b.language ?? "text", content: b.code ?? b.content ?? "" };
    case "code_result":
      return { type: "code-result", blockId, language: b.language, content: b.code ?? b.content ?? "", exitCode: b.exitCode ?? undefined, status: mapStatus(b.status) };
    case "terminal":
      // Terminal is conceptually a streaming shell block — render as such.
      return { type: "shell", blockId, cmd: "", output: b.content ?? "", exitCode: b.exitCode ?? undefined, status: mapStatus(b.status) };
    case "diff":
      return { type: "diff", blockId, path: b.path ?? "", oldText: b.oldText, newText: b.newText, unifiedDiff: b.unifiedDiff };
    case "json":
      return { type: "json", blockId, value: b.json };
    case "ui_spec":
      return { type: "json", blockId, value: b.json };
    case "tool_call":
      return {
        type: "tool-call",
        blockId,
        tool: b.toolName ?? "Tool",
        args: b.args ?? {},
        result: b.result,
        status: mapStatus(b.status),
      };
    case "tool_result":
      return {
        type: "tool-result",
        blockId,
        tool: b.toolName ?? "Tool",
        output: b.json ?? b.result ?? b.content ?? "",
        status: mapStatus(b.status),
      };
    case "image":
      return { type: "image", blockId, url: b.url ?? "", alt: b.title, mime: b.mimeType };
    case "audio":
      return { type: "audio", blockId, url: b.url ?? "", filename: b.filename };
    case "video":
      return { type: "video", blockId, url: b.url ?? "", filename: b.filename };
    case "document":
      return { type: "document", blockId, url: b.url ?? "", filename: b.filename ?? "document", mime: b.mimeType };
    case "resource_ref":
      return { type: "ref", blockId, uri: b.uri ?? "", title: b.title, refKind: "resource" };
    case "file_ref":
      return { type: "ref", blockId, uri: b.uri ?? "", title: b.title, refKind: "file" };
    case "artifact_ref":
      return { type: "ref", blockId, uri: b.uri ?? "", title: b.title, refKind: "artifact" };
    case "citation_list":
      return { type: "citations", blockId, items: b.citations ?? [] };
    default:
      // Unknown kind — best-effort render as JSON.
      return { type: "json", blockId, value: b };
  }
}

function mapStatus(s?: string): "streaming" | "ok" | "error" | "cancelled" | undefined {
  if (!s) return undefined;
  if (s === "streaming" || s === "in_progress" || s === "pending") return "streaming";
  if (s === "completed" || s === "ok") return "ok";
  if (s === "error" || s === "failed") return "error";
  if (s === "cancelled") return "cancelled";
  return undefined;
}

export type _DiminuendoConnectorOptions = DiminuendoConnectorOptions;
