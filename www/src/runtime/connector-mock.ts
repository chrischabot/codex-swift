// MockConnector — the in-memory implementation used in dev. Now produces a
// realistic stream that exercises every block kind: thinking → plan →
// sandbox start → tool-call (Read/Edit) → diff → compaction → sub-agent →
// approval → completion. This is the reference behaviour the
// DiminuendoConnector should match when mapping Fabric events.

import type {
  Automation,
  Message,
  MessageBlock,
  Thread,
} from "@/domain/models";
import {
  diminuendoDiffFiles,
  ingressDiffFiles,
  seedApps,
  seedAutomationTemplates,
  seedAutomations,
  seedHooks,
  seedMcpServers,
  seedMessages,
  seedPluginsFeatured,
  seedProjects,
  seedSkills,
  seedThreads,
  seedTimeline,
} from "@/domain/seed";
import type {
  BlockDelta,
  Connector,
  ConnectorSnapshot,
  ConnectorStatus,
  DiffViewModel,
  SendOptions,
  ThreadStreamEvent,
  WikiJobLine,
} from "./connector";

let counter = 1;
const id = (prefix: string) => `${prefix}-${Date.now().toString(36)}-${counter++}`;

export function makeMockConnector(): Connector {
  let snap: ConnectorSnapshot = {
    projects: [...seedProjects],
    threads: [...seedThreads],
    messages: [...seedMessages],
    plugins: [...seedPluginsFeatured],
    apps: [...seedApps],
    automations: [...seedAutomations],
    automationTemplates: [...seedAutomationTemplates],
    mcpServers: [...seedMcpServers],
    skills: [...seedSkills],
    hooks: [...seedHooks],
  };

  const snapshotListeners = new Set<(s: ConnectorSnapshot) => void>();
  const statusListeners = new Set<(s: ConnectorStatus) => void>();
  let currentStatus: ConnectorStatus = { kind: "connected", latencyMs: 0, clientId: "mock" };

  const notifySnapshot = () => {
    for (const l of snapshotListeners) l(snap);
  };
  const update = (mut: (s: ConnectorSnapshot) => ConnectorSnapshot) => {
    snap = mut(snap);
    notifySnapshot();
  };

  const threadSubscribers = new Map<string, Set<(e: ThreadStreamEvent) => void>>();
  const emit = (threadId: string, event: ThreadStreamEvent) => {
    threadSubscribers.get(threadId)?.forEach((cb) => cb(event));
  };

  // Apply a block delta to the in-memory message and re-broadcast snapshot.
  const applyDelta = (messageId: string, blockId: string, delta: BlockDelta) => {
    update((s) => ({
      ...s,
      messages: s.messages.map((m) => {
        if (m.id !== messageId) return m;
        return {
          ...m,
          blocks: m.blocks.map((b) => mergeDelta(b, blockId, delta)),
        };
      }),
    }));
  };

  // Append a new block to a streaming assistant message.
  const appendBlock = (messageId: string, block: MessageBlock) => {
    update((s) => ({
      ...s,
      messages: s.messages.map((m) =>
        m.id === messageId ? { ...m, blocks: [...m.blocks, block] } : m,
      ),
    }));
  };

  // Mark a block done (status: ok | error | cancelled)
  const finalizeBlock = (
    messageId: string,
    blockId: string,
    status: "ok" | "error" | "cancelled",
  ) => {
    update((s) => ({
      ...s,
      messages: s.messages.map((m) => {
        if (m.id !== messageId) return m;
        return {
          ...m,
          blocks: m.blocks.map((b) =>
            (b as { blockId?: string }).blockId === blockId
              ? ({ ...b, status } as MessageBlock)
              : b,
          ),
        };
      }),
    }));
  };

  const interruptedRef = { current: new Set<string>() };
  // Per-thread set of pending sleep-cancellers. interruptTurn() drains them so
  // any in-flight `await abortableSleep(...)` resolves immediately.
  const pendingSleeps = new Map<string, Set<() => void>>();

  const abortableSleep = (threadId: string, ms: number) =>
    new Promise<void>((resolve) => {
      let bucket = pendingSleeps.get(threadId);
      if (!bucket) {
        bucket = new Set<() => void>();
        pendingSleeps.set(threadId, bucket);
      }
      const cancellers = bucket; // narrowed; can't be undefined past here
      const cancel = () => {
        clearTimeout(timer);
        cancellers.delete(cancel);
        resolve();
      };
      const timer = setTimeout(() => {
        cancellers.delete(cancel);
        resolve();
      }, ms);
      cancellers.add(cancel);
    });

  // Returns true if the script ran to completion, false if it was interrupted.
  // sendMessage uses the return to decide whether to write the post-hoc
  // "Worked for Xs" preamble. We must NOT overwrite "Interrupted" with that.
  const runScript = async (threadId: string, messageId: string, script: StreamScript): Promise<boolean> => {
    const bail = () => {
      interruptedRef.current.delete(threadId);
      finalizeMessagePreamble(messageId, "Interrupted");
      emit(threadId, { kind: "message-complete", threadId, messageId, preamble: "Interrupted" });
    };
    for (const step of script) {
      if (interruptedRef.current.has(threadId)) { bail(); return false; }
      await abortableSleep(threadId, step.afterMs ?? 90);
      if (interruptedRef.current.has(threadId)) { bail(); return false; }
      step.run({ threadId, messageId, appendBlock, applyDelta, finalizeBlock, emit });
    }
    return true;
  };

  const finalizeMessagePreamble = (messageId: string, preamble?: string) => {
    update((s) => ({
      ...s,
      messages: s.messages.map((m) => (m.id === messageId ? { ...m, preamble } : m)),
    }));
  };

  return {
    connect: async () => {
      currentStatus = { kind: "connected", latencyMs: 0, clientId: "mock" };
      statusListeners.forEach((l) => l(currentStatus));
    },
    disconnect: async () => {
      currentStatus = { kind: "offline" };
      statusListeners.forEach((l) => l(currentStatus));
    },
    onStatus: (cb) => {
      statusListeners.add(cb);
      cb(currentStatus);
      return () => {
        statusListeners.delete(cb);
      };
    },
    status: () => currentStatus,

    snapshot: async () => snap,
    onSnapshot: (cb) => {
      snapshotListeners.add(cb);
      cb(snap);
      return () => {
        snapshotListeners.delete(cb);
      };
    },

    subscribeThread: (threadId, cb) => {
      let set = threadSubscribers.get(threadId);
      if (!set) {
        set = new Set();
        threadSubscribers.set(threadId, set);
      }
      set.add(cb);
      return async () => {
        set!.delete(cb);
        if (set!.size === 0) threadSubscribers.delete(threadId);
      };
    },

    sendMessage: async (threadId, text, opts) => {
      const userMsg: Message = {
        id: id("m-user"),
        threadId,
        role: "user",
        blocks: [{ type: "markdown", content: text }],
        createdAt: Date.now(),
      };
      update((s) => ({ ...s, messages: [...s.messages, userMsg] }));
      emit(threadId, { kind: "message-complete", threadId, messageId: userMsg.id });

      const assistantId = id("m-assistant");
      const assistantMsg: Message = {
        id: assistantId,
        threadId,
        role: "assistant",
        preamble: "Working",
        blocks: [],
        createdAt: Date.now(),
        model: `${opts?.modelLabel ?? "5.5"} ${opts?.modelTier ?? "High"}`,
      };
      update((s) => ({ ...s, messages: [...s.messages, assistantMsg] }));

      // Build a realistic script tailored to the user's prompt. Only finalize
      // with "Worked for Xs" if the script ran to completion — runScript has
      // already written "Interrupted" if the user hit Stop.
      const completed = await runScript(threadId, assistantId, buildScript(text, opts ?? {}));
      if (completed) {
        finalizeMessagePreamble(assistantId, "Worked for 12s");
        emit(threadId, { kind: "message-complete", threadId, messageId: assistantId, preamble: "Worked for 12s" });
      }
    },
    interruptTurn: async (threadId) => {
      interruptedRef.current.add(threadId);
      // Wake any pending abortableSleep on this thread.
      const cancellers = pendingSleeps.get(threadId);
      if (cancellers) {
        for (const c of cancellers) c();
      }
    },

    setThreadPinned: async (id, pinned) =>
      update((s) => ({
        ...s,
        threads: s.threads.map((t) => (t.id === id ? { ...t, pinned } : t)),
      })),
    setThreadArchived: async (id, archived) =>
      update((s) => ({
        ...s,
        threads: s.threads.map((t) =>
          t.id === id ? { ...t, status: archived ? "archived" : "active" } : t,
        ),
      })),
    setThreadUnread: async (id, unread) =>
      update((s) => ({
        ...s,
        threads: s.threads.map((t) => (t.id === id ? { ...t, unread } : t)),
      })),
    renameThread: async (id, title) =>
      update((s) => ({
        ...s,
        threads: s.threads.map((t) => (t.id === id ? { ...t, title } : t)),
      })),
    deleteThread: async (id) =>
      update((s) => ({
        ...s,
        threads: s.threads.filter((t) => t.id !== id),
        messages: s.messages.filter((m) => m.threadId !== id),
      })),
    openThreadInNewWindow: async (id) => {
      // Host bridge would spawn a BrowserWindow; in the web mock we open the
      // route in a new browser tab so the action is observably real.
      if (typeof window !== "undefined") {
        window.open(`${window.location.origin}/thread/${id}`, "_blank", "noopener");
      }
    },
    forkThread: async (id, target) => {
      const src = snap.threads.find((t) => t.id === id);
      if (!src) throw new Error(`No thread ${id}`);
      const isWorktree = target === "worktree" || target === "new-worktree" || target === "same-worktree";
      const suffix =
        target === "new-worktree" ? "-nwt" :
        target === "same-worktree" ? "-swt" :
        target === "worktree" ? "-wt" : "-fork";
      const fork: Thread = {
        ...src,
        id: id + suffix,
        title: `${src.title} (fork)`,
        pinned: false,
        unread: false,
        envKind: isWorktree ? "worktree" : src.envKind ?? "local",
        updatedAt: Date.now(),
      };
      update((s) => ({ ...s, threads: [...s.threads, fork] }));
      return fork.id;
    },
    togglePlugin: async (id, enabled) =>
      update((s) => ({
        ...s,
        apps: s.apps.map((a) => (a.id === id ? { ...a, enabled } : a)),
      })),
    addAutomation: async (name, schedule) => {
      const auto: Automation = { id: id("auto"), name, schedule };
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
      const t: Thread = {
        id: id("t"),
        projectId,
        title,
        status: "active",
        updatedAt: Date.now(),
      };
      update((s) => ({ ...s, threads: [...s.threads, t] }));
      return t;
    },
    respondToApproval: async (approvalId, decision) => {
      update((s) => ({
        ...s,
        messages: s.messages.map((m) => ({
          ...m,
          blocks: m.blocks.map((b) =>
            b.type === "approval" && b.approvalId === approvalId
              ? { ...b, decided: decision }
              : b,
          ),
        })),
      }));
    },

    getDiff: async (threadId): Promise<DiffViewModel | null> => {
      if (threadId === "t-dim-projection") {
        return {
          env: {
            changes: { added: 1835, removed: 111 },
            local: true,
            branch: "main",
            hasCommit: false,
            sources: [
              { id: "dim-readme", label: "diminuendo/README.md" },
              { id: "web", label: "Web search" },
            ],
          },
          files: diminuendoDiffFiles,
        };
      }
      if (threadId === "t-pin-fabric-server") {
        return {
          env: {
            changes: { added: 18, removed: 4 },
            local: false,
            branch: "fabric/ingress-auth",
            hasCommit: true,
            sources: [{ id: "ingress", label: "server/ingress.ts" }],
          },
          files: ingressDiffFiles,
        };
      }
      return null;
    },

    getTimeline: async (threadId) => seedTimeline[threadId] ?? [],

    // ── Memory Wiki (mock) — enough for the Console + E2E to exercise every tab.
    searchWiki: async (query) => [
      { id: "1", title: `Result for “${query}”`, excerpt: "A mock wiki page about " + query, source: "web" },
      { id: "2", title: "Vector Databases", excerpt: "FAISS, HNSW, IVF…", source: "arxiv" },
    ],
    getWikiBrief: async (topic) => ({
      topic, summary: `A concise, cited synthesis about ${topic}.`, confidence: "medium",
      key_points: [{ text: `${topic} is well-studied.`, citation_ids: ["c1"] }],
      citations: [{ id: "c1", doc_uri: "https://example.com/" + encodeURIComponent(topic), snippet: "…" }],
    }),
    getWikiStatus: async () => ({
      documents: 4986, pages: 2, flaggedStale: 1,
      recentJobs: [
        { jobID: "j1", input: "https://github.com/openai", status: "done",
          candidates: 4, written: 4, skipped: 0, failed: 0 },
      ],
    }),
    getWikiWatch: async () => [
      { id: "https://github.com/openai", cadence: "hot", status: "active", errorCount: 0, due: true },
      { id: "https://blog.example.com/feed", cadence: "warm", status: "paused", errorCount: 0, due: false },
    ],
    getLibrarianReport: async () => ({
      pages: 3,
      flagged: 2,
      stalest: [
        { documentID: 12, volatility: "hot", staleness: 18.4, needsTier2: true, sourceCount: 1, depthProxy: 2 },
        { documentID: 7, volatility: "warm", staleness: 41.2, needsTier2: true, sourceCount: 3, depthProxy: 3 },
        { documentID: 3, volatility: "cold", staleness: 92.0, needsTier2: false, sourceCount: 6, depthProxy: 4 },
      ],
    }),
    getAuditReport: async () => ({
      pages: 3,
      drifted: 1,
      indirectlyDrifted: 1,
      pagesDetail: [
        { id: 7, status: "drifted" },
        { id: 12, status: "indirectlyDrifted" },
        { id: 3, status: "current" },
      ],
    }),
    getWikiInventory: async () => [
      { slug: "rag", kind: "item", status: "active", priority: "p0", title: "RAG", summary: "retrieval-augmented generation" },
      { slug: "ingest-arxiv", kind: "ingest-candidate", status: "proposed", priority: "p2", title: "arXiv cs.AI feed", nextAction: "wire FeedAdapter" },
      { slug: "open-q-eval", kind: "question", status: "blocked", priority: "p1", title: "How to eval retrieval NDCG?" },
    ],
    getWikiDatasets: async () => [
      { datasetID: "imagenet", title: "ImageNet", status: "external", storage: "remote", recordCount: 1281167 },
      { datasetID: "local-notes", title: "Local notes", status: "active", storage: "local", sizeBytes: 40960, recordCount: 312 },
    ],
    getWikiCollect: async () => [
      { slug: "memes", count: 24 },
      { slug: "agent-tools", count: 8 },
    ],
    startWikiResearch: async (params, onEvent) => {
      const seq: Array<[WikiJobLine, boolean]> = [
        [{ type: "event", kind: "started", mode: params.mode || "topic" }, false],
        [{ type: "event", kind: "round_started", round: 1 }, false],
        [{ type: "event", kind: "sources", round: 1, count: 3 }, false],
        [{ type: "event", kind: "compiled", round: 1, written: 2, claims: 8 }, false],
        [{ type: "event", kind: "round_completed", round: 1, score: 44 }, false],
        [{ type: "result", status: "completed", rounds: 1, sources: 3, pages: 2, finalScore: 44 }, true],
      ];
      seq.forEach(([line, done], i) => setTimeout(() => onEvent(line, done), 120 * (i + 1)));
      return { jobId: "mock-research", cancel: () => {} };
    },
    startWikiIngest: async (_params, onEvent) => {
      const seq: Array<[WikiJobLine, boolean]> = [
        [{ type: "event", kind: "candidate", seq: 1, status: "written", uri: "https://github.com/o/r1" }, false],
        [{ type: "event", kind: "candidate", seq: 2, status: "written", uri: "https://github.com/o/r2" }, false],
        [{ type: "result", status: "done", written: 2, skipped: 0, failed: 0 }, true],
      ];
      seq.forEach(([line, done], i) => setTimeout(() => onEvent(line, done), 120 * (i + 1)));
      return { jobId: "mock-ingest", cancel: () => {} };
    },
  };
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream-script utilities. A script is a list of timed steps; each step runs
// against the snapshot and emits a corresponding ThreadStreamEvent. The
// shape of these scripts is the contract the DiminuendoConnector should
// reproduce when it forwards events from the wire.
// ─────────────────────────────────────────────────────────────────────────────

interface StepCtx {
  threadId: string;
  messageId: string;
  appendBlock: (messageId: string, block: MessageBlock) => void;
  applyDelta: (messageId: string, blockId: string, delta: BlockDelta) => void;
  finalizeBlock: (messageId: string, blockId: string, status: "ok" | "error" | "cancelled") => void;
  emit: (threadId: string, event: ThreadStreamEvent) => void;
}

interface Step {
  afterMs?: number;
  run: (ctx: StepCtx) => void;
}

type StreamScript = Step[];

function appendBlockStep(block: MessageBlock, afterMs = 80): Step {
  return {
    afterMs,
    run: ({ threadId, messageId, appendBlock, emit }) => {
      appendBlock(messageId, block);
      emit(threadId, { kind: "block-appended", threadId, messageId, block });
    },
  };
}

function deltaStep(blockId: string, delta: BlockDelta, afterMs = 40): Step {
  return {
    afterMs,
    run: ({ threadId, messageId, applyDelta, emit }) => {
      applyDelta(messageId, blockId, delta);
      emit(threadId, { kind: "block-delta", threadId, messageId, blockId, delta });
    },
  };
}

function finalizeStep(blockId: string, status: "ok" | "error" | "cancelled" = "ok", afterMs = 30): Step {
  return {
    afterMs,
    run: ({ threadId, messageId, finalizeBlock, emit }) => {
      finalizeBlock(messageId, blockId, status);
      emit(threadId, { kind: "block-status", threadId, messageId, blockId, status });
    },
  };
}

function buildScript(prompt: string, opts: SendOptions): StreamScript {
  const planId = "blk-plan";
  const thinkingId = "blk-thinking";
  const sandboxStartId = "blk-sandbox-start";
  const fetchId = "blk-fetch";
  const readId = "blk-read";
  const editId = "blk-edit";
  const diffSummaryId = "blk-diff";
  const subAgentId = "blk-subagent";
  const approvalId = "blk-approval";
  const compactionId = "blk-compaction";
  const markdownId = "blk-md";
  const modelSwitchId = "blk-model";
  const tokensId = "blk-tokens";

  return [
    // 1. Compaction: pretend we just rolled up some history
    appendBlockStep({
      type: "compaction",
      blockId: compactionId,
      summary: `Earlier discussion focused on the projection store. The previous turn introduced TTL eviction and added a Vitest case. The user has now asked: "${truncate(prompt, 80)}"`,
      compactedCount: 7,
    }, 60),

    // 2. Thinking shimmer
    appendBlockStep({ type: "thinking", blockId: thinkingId, content: "", status: "streaming" }, 80),
    deltaStep(thinkingId, { kind: "text-append", text: "Inspect the request, decide whether to fetch any sources, then plan the change.\n" }, 90),
    deltaStep(thinkingId, { kind: "text-append", text: "Likely a small refactor — keep the existing TTL knob shape stable.\n" }, 80),
    finalizeStep(thinkingId),

    // 3. Plan checklist
    appendBlockStep({
      type: "plan",
      blockId: planId,
      title: "Plan",
      steps: [
        { id: "p1", content: "Fetch relevant docs", status: "pending" },
        { id: "p2", content: "Open projection store", status: "pending" },
        { id: "p3", content: "Apply edits", status: "pending" },
        { id: "p4", content: "Run tests", status: "pending" },
      ],
    }, 60),

    // 4. Model switch (e.g. up-tier for code edits)
    appendBlockStep({
      type: "model-switch",
      blockId: modelSwitchId,
      from: opts.modelLabel ? `${opts.modelLabel} ${opts.modelTier}` : "5.5 Medium",
      to: "5.5 High",
      reason: "code edit",
    }, 80),

    // 5. Sandbox starting
    appendBlockStep({
      type: "sandbox",
      blockId: sandboxStartId,
      event: "starting",
      sandboxId: "sbx-9f2",
      cwd: "~/Projects/fabric/diminuendo",
    }, 80),
    // Step 1: "Fetch relevant docs" → in progress (delta the existing plan
    // block; the renderer reads from state, the emit is the wire signal).
    deltaStep(planId, { kind: "plan-step", step: { id: "p1", content: "Fetch relevant docs", status: "in_progress" } }, 120),

    // 6. Web fetch
    appendBlockStep({
      type: "web-fetch",
      blockId: fetchId,
      url: "https://bun.sh/docs/test/fake-timers",
      title: "Bun test — fake timers",
      status: "fetching",
      contentSnippet: "Use bun:test fake timers for TTL-based eviction without flaky setTimeout-based tests.",
    }, 100),
    {
      afterMs: 200,
      run: ({ threadId, messageId, emit }) => {
        // No granular delta API for web-fetch in mock; we just emit a block-
        // status to mark it complete.
        emit(threadId, { kind: "block-status", threadId, messageId, blockId: fetchId, status: "ok" });
      },
    },
    // Plan: step 1 done, step 2 in progress
    deltaStep(planId, { kind: "plan-step", step: { id: "p1", content: "Fetch relevant docs", status: "completed" } }, 60),
    deltaStep(planId, { kind: "plan-step", step: { id: "p2", content: "Open projection store", status: "in_progress" } }, 30),

    // 7. Sub-agent invocation (research)
    appendBlockStep({
      type: "sub-agent",
      blockId: subAgentId,
      agentId: "research-agent",
      agentName: "Research",
      goal: "find prior TTL implementations in fabric/* repos",
      status: "running",
    }, 70),
    {
      afterMs: 250,
      run: ({ threadId, messageId, emit, appendBlock }) => {
        // Emit a status transition + summary
        emit(threadId, { kind: "block-status", threadId, messageId, blockId: subAgentId, status: "ok" });
        appendBlock(messageId, {
          type: "markdown",
          blockId: markdownId,
          content: `Plan is clear. I'll patch \`src/projection/store.ts\` to add a configurable TTL and rely on bun:test fake timers in the new test.\n\n`,
        });
      },
    },

    // 8. Markdown streaming, token-by-token
    ...chunkString("Adding the TTL field and an `evictExpired` pass keeps the change scoped — no breaking changes to ", 18).map((c) =>
      deltaStep(markdownId, { kind: "text-append", text: c }, 35),
    ),
    deltaStep(markdownId, { kind: "text-append", text: "`PresentationItem`. " }, 30),
    ...chunkString("Then the Vitest case uses fake timers so it's not flaky.\n\n", 24).map((c) =>
      deltaStep(markdownId, { kind: "text-append", text: c }, 35),
    ),

    // 9. Tool-calls (Read → Edit)
    appendBlockStep({
      type: "tool-call",
      blockId: readId,
      tool: "Read",
      args: { file_path: "src/projection/store.ts" },
      status: "streaming",
    }, 60),
    finalizeStep(readId),

    // Plan: step 2 done, step 3 in progress (applying edits)
    deltaStep(planId, { kind: "plan-step", step: { id: "p2", content: "Open projection store", status: "completed" } }, 30),
    deltaStep(planId, { kind: "plan-step", step: { id: "p3", content: "Apply edits", status: "in_progress" } }, 30),

    appendBlockStep({
      type: "tool-call",
      blockId: editId,
      tool: "Edit",
      args: {
        file_path: "src/projection/store.ts",
        old_string: "// TODO: TTL eviction",
        new_string: "private readonly itemAddedAt = new Map<string, number>();\nprivate readonly ttlMs: number;",
      },
      summary: "Replaced 1 occurrence.",
      status: "streaming",
    }, 80),
    finalizeStep(editId),

    // Plan: step 3 done, step 4 in progress (running tests)
    deltaStep(planId, { kind: "plan-step", step: { id: "p3", content: "Apply edits", status: "completed" } }, 30),
    deltaStep(planId, { kind: "plan-step", step: { id: "p4", content: "Run tests", status: "in_progress" } }, 30),

    // 10. Approval request (network)
    appendBlockStep({
      type: "approval",
      blockId: approvalId,
      approvalId: id("appr"),
      kind: "network",
      title: "Fetch projection-store benchmark suite",
      detail: "Required to compare TTL eviction with the previous unbounded baseline.",
      risk: "network",
      command: ["curl", "-sSL", "https://internal.fabric/benchmarks/projection.json"],
      cwd: "~/Projects/fabric/diminuendo",
      decisions: ["deny_once", "allow_once", "allow_always"],
    }, 70),

    // 11. Shell with PASS output
    appendBlockStep({
      type: "shell",
      blockId: "blk-shell",
      cwd: "bash",
      cmd: "bun test src/projection",
      output: "pass  src/projection/store.test.ts\nTests:  4 passed, 4 total\nTime:   0.42s\nALL SUITES: PASS",
      status: "ok",
    }, 200),
    // Plan: step 4 done — all four steps now completed.
    deltaStep(planId, { kind: "plan-step", step: { id: "p4", content: "Run tests", status: "completed" } }, 30),

    // 12. Diff summary card
    appendBlockStep({
      type: "diff-summary",
      blockId: diffSummaryId,
      label: "Edited 2 files",
      added: 66,
      removed: 8,
      files: [
        { path: "src/projection/store.ts", delta: "+42 -8" },
        { path: "src/projection/store.test.ts", delta: "+24 -0" },
      ],
    }, 80),

    // 13. Sandbox stopped
    appendBlockStep({
      type: "sandbox",
      blockId: "blk-sandbox-stop",
      event: "stopped",
      sandboxId: "sbx-9f2",
      durationMs: 11_900,
    }, 60),

    // 14. Token-usage chip
    appendBlockStep({
      type: "token-usage",
      blockId: tokensId,
      input: 4_812,
      output: 2_103,
      cacheRead: 18_440,
      cost: 0.0231,
    }, 50),
  ];
}

function mergeDelta(b: MessageBlock, blockId: string, delta: BlockDelta): MessageBlock {
  if ((b as { blockId?: string }).blockId !== blockId) return b;
  if (delta.kind === "text-append") {
    if (b.type === "markdown" || b.type === "thinking") {
      return { ...b, content: b.content + delta.text } as MessageBlock;
    }
  }
  if (delta.kind === "stdout-append") {
    if (b.type === "shell") {
      return { ...b, output: (b.output ?? "") + delta.text };
    }
    if (b.type === "code-result") {
      return { ...b, content: b.content + delta.text };
    }
  }
  if (delta.kind === "plan-step" && b.type === "plan") {
    const exists = b.steps.find((s) => s.id === delta.step.id);
    return {
      ...b,
      steps: exists
        ? b.steps.map((s) => (s.id === delta.step.id ? delta.step : s))
        : [...b.steps, delta.step],
    };
  }
  if (delta.kind === "json-replace" && (b.type === "json" || b.type === "tool-result")) {
    return b.type === "json" ? { ...b, value: delta.value } : { ...b, output: delta.value };
  }
  return b;
}

function sleep(ms: number) {
  return new Promise((r) => setTimeout(r, ms));
}

function chunkString(s: string, n: number): string[] {
  const out: string[] = [];
  for (let i = 0; i < s.length; i += n) out.push(s.slice(i, i + n));
  return out;
}

function truncate(s: string, n: number) {
  const oneLine = s.replace(/\n/g, " ").trim();
  return oneLine.length > n ? oneLine.slice(0, n - 1) + "…" : oneLine;
}
