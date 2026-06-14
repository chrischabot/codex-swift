// Connector — the seam between the diminuendo-shadcn UI and any backend that
// drives it. The UI never talks to Diminuendo (or any other source) directly;
// it talks to a Connector. Two implementations ship in the box:
//
//   - MockConnector       (in `connector-mock.ts`): in-memory seed data with a
//     realistic streaming simulator (blocks added with deltas + status
//     transitions, matching the Fabric presentation event model).
//   - DiminuendoConnector (in `connector-diminuendo.ts`): wraps the
//     @igentai/dim-shared client — only resolvable inside the diminuendo
//     monorepo.

import type {
  Automation,
  AutomationTemplate,
  DiffEnvironment,
  DiffFile,
  Hook,
  McpServer,
  Message,
  MessageBlock,
  Model,
  Plugin,
  PluginApp,
  Project,
  Skill,
  Thread,
  TimelineEvent,
} from "@/domain/models";

export type ConnectorStatus =
  | { kind: "offline" }
  | { kind: "connecting" }
  | { kind: "connected"; latencyMs?: number; clientId?: string }
  | { kind: "reconnecting" }
  | { kind: "error"; message: string };

export interface ConnectorSnapshot {
  projects: Project[];
  threads: Thread[];
  messages: Message[];
  plugins: Plugin[];
  apps: PluginApp[];
  automations: Automation[];
  automationTemplates: AutomationTemplate[];
  mcpServers: McpServer[];
  skills: Skill[];
  hooks: Hook[];
}

// ─────────────────────────────────────────────────────────────────────────────
// Stream events — mirror Fabric's `presentation.*` and `conversation.*`
// surface so that the DiminuendoConnector can pass them through with minimal
// translation, and the MockConnector can emit a realistic sequence.
// ─────────────────────────────────────────────────────────────────────────────

export type ThreadStreamEvent =
  // A new block was appended to an in-progress assistant message
  | {
      kind: "block-appended";
      threadId: string;
      messageId: string;
      block: MessageBlock;
    }
  // A delta arrived for an existing block (markdown text append, JSON patch, …)
  | {
      kind: "block-delta";
      threadId: string;
      messageId: string;
      blockId: string;
      delta: BlockDelta;
    }
  // A block reached a terminal status (ok | error | cancelled)
  | {
      kind: "block-status";
      threadId: string;
      messageId: string;
      blockId: string;
      status: "ok" | "error" | "cancelled";
    }
  // The whole assistant turn finished
  | { kind: "message-complete"; threadId: string; messageId: string; preamble?: string }
  // Thread metadata changed (title, archived, pinned, …)
  | { kind: "title-update"; threadId: string; title: string }
  // Approval surfaced (the inbox tab also picks this up)
  | { kind: "approval-pending"; threadId: string; messageId: string; block: Extract<MessageBlock, { type: "approval" }> }
  | { kind: "approval-decided"; threadId: string; approvalId: string; decision: "allowed" | "denied" | "cancelled" }
  // Plan / mission / token / model events
  | { kind: "plan-update"; threadId: string; messageId: string; block: Extract<MessageBlock, { type: "plan" }> }
  | { kind: "mission-update"; threadId: string; messageId: string; block: Extract<MessageBlock, { type: "mission" }> }
  | { kind: "token-usage"; threadId: string; usage: { input: number; output: number; cacheRead?: number } }
  | { kind: "model-switch"; threadId: string; from?: string; to: string; reason?: string }
  // Compaction / context management
  | { kind: "compaction"; threadId: string; messageId: string; block: Extract<MessageBlock, { type: "compaction" }> }
  // Sandbox lifecycle
  | { kind: "sandbox"; threadId: string; event: "starting" | "ready" | "stopped" | "crashed"; sandboxId: string; cwd?: string; durationMs?: number };

export type BlockDelta =
  | { kind: "text-append"; text: string }
  | { kind: "json-replace"; value: unknown }
  // Append output text to a streaming shell / code-result block
  | { kind: "stdout-append"; text: string }
  // Append a step (or update an existing one) on a streaming plan block
  | { kind: "plan-step"; step: { id: string; content: string; status: "pending" | "in_progress" | "completed" } };

export interface SendOptions {
  approval?: "full-access" | "approval-required" | "read-only";
  modelLabel?: string;
  modelTier?: "Low" | "Medium" | "High";
}

/** Scope of an approval grant: one-shot ("once") or remembered for the session
 *  ("session", → backend `acceptForSession`). */
export type ApprovalScope = "once" | "session";

/** Output events from a realtime voice session (transcript + audio). */
export type RealtimeEvent =
  | { kind: "started" }
  | { kind: "transcript-delta"; role: string; delta: string }
  | { kind: "transcript-done"; role: string; text: string }
  | { kind: "audio"; audio: unknown }
  | { kind: "closed"; reason?: string };

/** A thread goal/mission (thread/goal/*). */
export interface ThreadGoalVM {
  objective: string;
  status: string;
  tokenBudget?: number;
  tokensUsed?: number;
}

/** Result of uploading a file to the agent gateway. */
export interface UploadedAttachment {
  blobId: string;
  /** Signed, same-origin URL to fetch the blob back (`/media/...`). */
  url: string;
  /** Absolute server-side staged path (used as a turn-input part). */
  path: string;
  name: string;
  mime: string;
}

export interface DiffViewModel {
  env: DiffEnvironment;
  files: DiffFile[];
}

// ── Wiki (Memory Wiki browse surface; a "page" is a backend DocumentRow) ─────
/** Lightweight row for lists (sidebar recents, search results, index). */
export interface WikiPageSummary {
  id: string;
  title: string;
  excerpt?: string;
  source?: string;
  updatedAt?: number; // epoch ms (connector normalizes)
}
/** An entity connection of a page (from the entity/edge graph). */
export interface WikiConnection {
  entityId: string;
  canonical: string;
  kind: string;
  relation: string;
  weight?: number;
}
/** Full page payload for the reading view. */
export interface WikiPage extends WikiPageSummary {
  content: string;
  tags?: string[];
  connections?: WikiConnection[];
}
export interface WikiTag {
  tag: string;
  count: number;
}
/**
 * One page's contribution to the vault link + property index (wiki/index).
 * `links` are the bare outgoing `[[wikilink]]` targets (alias/heading/block
 * suffixes stripped); `props` are flat parsed frontmatter key→value pairs.
 * Pages with neither links nor props are omitted from the index payload.
 */
export interface WikiIndexEntry {
  id: string;
  title: string;
  links: string[];
  props: Record<string, string>;
}
export interface WikiGraphNode {
  id: string;
  title: string;
  kind?: string;
  weight?: number;
}
export interface WikiGraphEdge {
  source: string;
  target: string;
  relation?: string;
}
export interface WikiGraph {
  nodes: WikiGraphNode[];
  edges: WikiGraphEdge[];
}

// ── Enrich: a lexical, cited synthesis brief (wiki/brief) ───────────────────
export interface WikiCitation {
  id: string;
  doc_uri: string;
  source_kind?: string;
  score?: number;
  snippet: string;
}
export interface WikiCitedPoint {
  text: string;
  citation_ids: string[];
}
export interface WikiBrief {
  status?: string;
  topic?: string;
  summary?: string;
  key_points?: WikiCitedPoint[];
  citations?: WikiCitation[];
  confidence?: string;
  novelty_rationale?: WikiCitedPoint[];
  what_would_change_my_mind?: string[];
  limitations?: string[];
}

// ── Status: the dashboard / view-logs surface (wiki/status) ──────────────────
export interface WikiIngestJob {
  jobID: string;
  input: string;
  status: string; // running | done | failed | cancelled
  adapter?: string;
  candidates: number;
  written: number;
  skipped: number;
  failed: number;
  startedAt?: number; // epoch ms (connector normalizes)
}
export interface WikiStatus {
  documents: number;
  pages: number;
  flaggedStale: number;
  recentJobs: WikiIngestJob[];
}
export interface WikiWatchSource {
  id: string;        // the handle/URL
  cadence: string;   // hot | warm | cold
  status: string;    // active | paused | error | disabled
  nextDueAt?: number; // epoch ms
  errorCount: number;
  due: boolean;
}

export interface Connector {
  /** Lifecycle. Mock implementations may be no-ops. */
  connect(): Promise<void>;
  disconnect(): Promise<void>;

  /** Status observation. Returns an unsubscribe handle. */
  onStatus(cb: (s: ConnectorStatus) => void): () => void;
  status(): ConnectorStatus;

  /** Snapshot of everything the sidebar needs. Reactive via onSnapshot. */
  snapshot(): Promise<ConnectorSnapshot>;
  onSnapshot(cb: (s: ConnectorSnapshot) => void): () => void;

  /** Thread-scoped live event stream. Returns an unsubscribe handle. */
  subscribeThread(threadId: string, cb: (e: ThreadStreamEvent) => void): () => Promise<void>;

  /** Mutations. */
  sendMessage(threadId: string, text: string, opts?: SendOptions): Promise<void>;
  interruptTurn(threadId: string): Promise<void>;
  setThreadPinned(id: string, pinned: boolean): Promise<void>;
  setThreadArchived(id: string, archived: boolean): Promise<void>;
  setThreadUnread(id: string, unread: boolean): Promise<void>;
  renameThread(id: string, title: string): Promise<void>;
  /** Permanently remove a thread (Archive page "Delete" / context menu). */
  deleteThread(id: string): Promise<void>;
  /** Open the thread in a new host window. Mock logs + resolves. */
  openThreadInNewWindow(id: string): Promise<void>;
  forkThread(id: string, target: "local" | "worktree" | "same-worktree" | "new-worktree"): Promise<string>;
  togglePlugin(id: string, enabled: boolean): Promise<void>;
  addAutomation(name: string, schedule: string): Promise<Automation>;
  deleteAutomation(id: string): Promise<void>;
  /** Patch the editable fields of an automation. The connector decides which
   *  fields it actually persists; mock keeps the lot. */
  updateAutomation(id: string, patch: Partial<Pick<Automation, "name" | "schedule">>): Promise<void>;
  createThread(projectId: string | null, title: string): Promise<Thread>;
  /** Respond to an approval surfaced via approval-pending or the Inbox tab.
   *  `scope: "session"` maps to the backend `acceptForSession` (don't ask again
   *  this session); omit/"once" for a one-shot grant. */
  respondToApproval(approvalId: string, decision: "allowed" | "denied" | "cancelled", scope?: ApprovalScope): Promise<void>;
  /** Reply to an MCP-server elicitation request ({action, content} channel). */
  answerElicitation?(requestId: string, accept: boolean, content?: Record<string, unknown>): Promise<void>;

  /** Upload a file to the agent. Staged server-side; included as a turn-input
   *  part on the next sendMessage for this thread. Optional (mock omits it). */
  uploadFile?(threadId: string | null, file: File): Promise<UploadedAttachment>;

  // ── Extended capabilities wired to existing backend endpoints. Optional so
  //    the MockConnector need not implement them; the live codex connector does.
  listModels?(): Promise<Model[]>;
  readConfig?(): Promise<Record<string, unknown>>;
  writeConfig?(keyPath: string, value: unknown): Promise<void>;
  readAccount?(): Promise<{ account?: unknown; requiresOpenaiAuth?: boolean }>;
  readRateLimits?(): Promise<Record<string, unknown>>;
  searchFiles?(query: string, roots?: string[]): Promise<string[]>;
  getGoal?(threadId: string): Promise<ThreadGoalVM | null>;
  setGoal?(threadId: string, objective: string, tokenBudget?: number): Promise<void>;
  clearGoal?(threadId: string): Promise<void>;
  rollbackTurns?(threadId: string, numTurns: number): Promise<void>;
  steerTurn?(threadId: string, text: string): Promise<void>;
  runShell?(threadId: string, command: string): Promise<void>;
  startReview?(threadId: string, target: string): Promise<string | null>;
  setMemoryMode?(threadId: string, enabled: boolean): Promise<void>;
  resetMemory?(): Promise<void>;
  injectContext?(threadId: string, text: string): Promise<void>;
  remoteControlStatus?(): Promise<Record<string, unknown>>;
  enableRemoteControl?(): Promise<void>;
  disableRemoteControl?(): Promise<void>;
  addEnvironment?(environmentId: string, execServerUrl: string): Promise<void>;
  listExperimentalFeatures?(): Promise<{ id: string; enabled: boolean }[]>;
  setExperimentalFeature?(id: string, enabled: boolean): Promise<void>;
  reloadMcpServers?(): Promise<void>;
  gitAction?(threadId: string, action: string, opts?: { message?: string; title?: string; body?: string }): Promise<{ ok: boolean; output: string; branch?: string }>;
  runAutomation?(id: string): Promise<void>;
  answerQuestion?(requestId: string, values: Record<string, unknown>): Promise<void>;
  listVoices?(): Promise<string[]>;
  startRealtime?(threadId: string, voice?: string): Promise<void>;
  sendRealtimeText?(threadId: string, text: string): Promise<void>;
  /** Stream a chunk of base64 PCM16 mic audio to the realtime session. */
  sendRealtimeAudio?(threadId: string, data: string, sampleRate: number, numChannels: number): Promise<void>;
  stopRealtime?(threadId: string): Promise<void>;
  /** Subscribe to realtime-session output (transcript + audio). */
  onRealtime?(threadId: string, cb: (e: RealtimeEvent) => void): () => void;

  /** Diff for the side panel. Mock returns the seed diminuendo TTL diff. */
  getDiff(threadId: string): Promise<DiffViewModel | null>;

  /** Timeline of events for the side-panel TIMELINE tab. */
  getTimeline(threadId: string): Promise<TimelineEvent[]>;

  // ── Wiki (optional: mock skips; live codex connector wires to wiki/*). ──
  listWikiPages?(opts?: { limit?: number }): Promise<WikiPageSummary[]>;
  getWikiPage?(pageId: string): Promise<WikiPage | null>;
  searchWiki?(query: string, opts?: { limit?: number }): Promise<WikiPageSummary[]>;
  // seedEntityId is an ENTITY id (e.g. a WikiConnection.entityId), NOT a page
  // id — the backend graph is the entity/edge graph. Omit it for the whole graph.
  getWikiGraph?(opts?: { seedEntityId?: string; depth?: number }): Promise<WikiGraph>;
  getWikiTags?(): Promise<WikiTag[]>;
  /** Pages that MENTION an entity (entity→page backlinks). `entityId` is an
   *  ENTITY id (e.g. a WikiConnection.entityId), not a page id. */
  getWikiEntityBacklinks?(entityId: string): Promise<WikiPageSummary[]>;
  /** Vault link + property index: per-page outgoing `[[wikilinks]]` + parsed
   *  frontmatter props. Powers backlinks / unlinked-mentions / property-catalog
   *  and rename link-rewrite from a single read. */
  getWikiIndex?(): Promise<WikiIndexEntry[]>;
  /** Create (id omitted) or overwrite a wiki page. Returns the page id. */
  saveWikiPage?(input: { id?: string; title?: string; body: string }): Promise<{ id: string } | null>;
  /** Delete a wiki page (and its derived chunks / index rows). Returns whether a
   *  page actually existed (false = already gone), or null on transport failure. */
  deleteWikiPage?(pageId: string): Promise<{ deleted: boolean } | null>;
  /** Rename a wiki page (title only — preserves source/body/index). Returns
   *  whether a page was renamed (false = not found), or null on transport failure. */
  renameWikiPage?(pageId: string, title: string): Promise<{ renamed: boolean } | null>;
  /** Lexical, zero-spend cited synthesis brief on a topic (the "enrich" surface). */
  getWikiBrief?(topic: string, opts?: { k?: number }): Promise<WikiBrief | null>;
  /** Dashboard: doc/page counts, flagged-stale count, recent ingest-job log. */
  getWikiStatus?(): Promise<WikiStatus | null>;
  /** Watched sources + their cadence / due status (the Watch tab). */
  getWikiWatch?(): Promise<WikiWatchSource[]>;
}
