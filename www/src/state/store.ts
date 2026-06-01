// Compatibility shim. The original Effect-backed store stayed in place during
// phase 1; phase 3 swapped the substrate for a Connector. This file keeps the
// import surface the rest of the app uses (`useAppData`, `dispatch`,
// `diminuendoDiffFiles`) intact.
//
// The dispatch surface is callable BEFORE the RuntimeProvider has finished
// connecting — early calls get queued and flushed on bind so callers don't
// have to thread a "is the connector ready" check through every component.

import { useRuntime } from "@/runtime/RuntimeProvider";
import type { AppData } from "@/domain/services";
import type { Automation } from "@/domain/models";
import { diminuendoDiffFiles } from "@/domain/seed";
import type { ApprovalScope, Connector, SendOptions } from "@/runtime/connector";

export const useAppData = (): AppData => useRuntime().snapshot;

// ─────────────────────────────────────────────────────────────────────────
// Pre-bind queue. Calls made before _bindConnector fires are buffered and
// flushed in registration order once the connector is available.
// ─────────────────────────────────────────────────────────────────────────

type Pending = (c: Connector) => Promise<unknown>;
let _connector: Connector | null = null;
const _pending: Pending[] = [];

function run<R>(fn: (c: Connector) => Promise<R>): Promise<R> {
  if (_connector) return fn(_connector);
  return new Promise<R>((resolve, reject) => {
    _pending.push((c) => fn(c).then(resolve, reject));
  });
}

export function _bindConnector(rt: ReturnType<typeof useRuntime>) {
  _connector = rt.connector;
  // Drain any calls that landed before bind.
  while (_pending.length > 0) {
    const next = _pending.shift()!;
    void next(rt.connector);
  }
}

export const dispatch = {
  setThreadPinned: (id: string, pinned: boolean) =>
    run((c) => c.setThreadPinned(id, pinned)),
  setThreadArchived: (id: string, archived: boolean) =>
    run((c) => c.setThreadArchived(id, archived)),
  setThreadUnread: (id: string, unread: boolean) =>
    run((c) => c.setThreadUnread(id, unread)),
  renameThread: (id: string, title: string) => run((c) => c.renameThread(id, title)),
  deleteThread: (id: string) => run((c) => c.deleteThread(id)),
  openThreadInNewWindow: (id: string) => run((c) => c.openThreadInNewWindow(id)),
  forkThread: (id: string, target: "local" | "worktree" | "same-worktree" | "new-worktree") =>
    run((c) => c.forkThread(id, target)),
  togglePlugin: (id: string, enabled: boolean) =>
    run((c) => c.togglePlugin(id, enabled)),
  addAutomation: (name: string, schedule: string) =>
    run((c) => c.addAutomation(name, schedule)),
  deleteAutomation: (id: string) => run((c) => c.deleteAutomation(id)),
  updateAutomation: (id: string, patch: Partial<Pick<Automation, "name" | "schedule">>) =>
    run((c) => c.updateAutomation(id, patch)),
  sendMessage: (threadId: string, text: string, opts?: SendOptions) => run((c) => c.sendMessage(threadId, text, opts)),
  createThread: (projectId: string | null, title: string) =>
    run((c) => c.createThread(projectId, title)),
  interruptTurn: (threadId: string) => run((c) => c.interruptTurn(threadId)),
  listModels: () => run((c) => c.listModels?.() ?? Promise.resolve([])),
  setGoal: (threadId: string, objective: string, tokenBudget?: number) =>
    run((c) => c.setGoal?.(threadId, objective, tokenBudget) ?? Promise.resolve()),
  getGoal: (threadId: string) => run((c) => c.getGoal?.(threadId) ?? Promise.resolve(null)),
  clearGoal: (threadId: string) => run((c) => c.clearGoal?.(threadId) ?? Promise.resolve()),
  rollbackTurns: (threadId: string, n: number) => run((c) => c.rollbackTurns?.(threadId, n) ?? Promise.resolve()),
  steerTurn: (threadId: string, text: string) => run((c) => c.steerTurn?.(threadId, text) ?? Promise.resolve()),
  runShell: (threadId: string, command: string) => run((c) => c.runShell?.(threadId, command) ?? Promise.resolve()),
  startReview: (threadId: string, target: string) => run((c) => c.startReview?.(threadId, target) ?? Promise.resolve(null)),
  setMemoryMode: (threadId: string, enabled: boolean) => run((c) => c.setMemoryMode?.(threadId, enabled) ?? Promise.resolve()),
  resetMemory: () => run((c) => c.resetMemory?.() ?? Promise.resolve()),
  readConfig: () => run((c) => c.readConfig?.() ?? Promise.resolve({})),
  writeConfig: (keyPath: string, value: unknown) => run((c) => c.writeConfig?.(keyPath, value) ?? Promise.resolve()),
  readAccount: () => run((c) => c.readAccount?.() ?? Promise.resolve({})),
  readRateLimits: () => run((c) => c.readRateLimits?.() ?? Promise.resolve({})),
  searchFiles: (query: string, roots?: string[]) => run((c) => c.searchFiles?.(query, roots) ?? Promise.resolve([])),
  listExperimentalFeatures: () => run((c) => c.listExperimentalFeatures?.() ?? Promise.resolve([])),
  setExperimentalFeature: (id: string, enabled: boolean) => run((c) => c.setExperimentalFeature?.(id, enabled) ?? Promise.resolve()),
  remoteControlStatus: () => run((c) => c.remoteControlStatus?.() ?? Promise.resolve({})),
  enableRemoteControl: () => run((c) => c.enableRemoteControl?.() ?? Promise.resolve()),
  disableRemoteControl: () => run((c) => c.disableRemoteControl?.() ?? Promise.resolve()),
  addEnvironment: (id: string, url: string) => run((c) => c.addEnvironment?.(id, url) ?? Promise.resolve()),
  reloadMcpServers: () => run((c) => c.reloadMcpServers?.() ?? Promise.resolve()),
  injectContext: (threadId: string, text: string) => run((c) => c.injectContext?.(threadId, text) ?? Promise.resolve()),
  gitAction: (threadId: string, action: string, opts?: { message?: string; title?: string; body?: string }) =>
    run((c) => c.gitAction?.(threadId, action, opts) ?? Promise.resolve({ ok: false, output: "git not supported" })),
  runAutomation: (id: string) => run((c) => c.runAutomation?.(id) ?? Promise.resolve()),
  answerQuestion: (requestId: string, values: Record<string, unknown>) =>
    run((c) => c.answerQuestion?.(requestId, values) ?? Promise.resolve()),
  listVoices: () => run((c) => c.listVoices?.() ?? Promise.resolve([])),
  startRealtime: (threadId: string, voice?: string) => run((c) => c.startRealtime?.(threadId, voice) ?? Promise.resolve()),
  sendRealtimeText: (threadId: string, text: string) => run((c) => c.sendRealtimeText?.(threadId, text) ?? Promise.resolve()),
  sendRealtimeAudio: (threadId: string, data: string, sampleRate: number, numChannels: number) =>
    run((c) => c.sendRealtimeAudio?.(threadId, data, sampleRate, numChannels) ?? Promise.resolve()),
  stopRealtime: (threadId: string) => run((c) => c.stopRealtime?.(threadId) ?? Promise.resolve()),
  uploadFile: (threadId: string | null, file: File) =>
    run((c) => c.uploadFile?.(threadId, file) ?? Promise.reject(new Error("uploads not supported by this connector"))),
  respondToApproval: (
    approvalId: string,
    decision: "allowed" | "denied" | "cancelled",
    scope?: ApprovalScope,
  ) => run((c) => c.respondToApproval(approvalId, decision, scope)),
  answerElicitation: (requestId: string, accept: boolean, content?: Record<string, unknown>) =>
    run((c) => c.answerElicitation?.(requestId, accept, content) ?? Promise.resolve()),
};

export { diminuendoDiffFiles };
