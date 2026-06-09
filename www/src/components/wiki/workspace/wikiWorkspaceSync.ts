// Cross-window workspace synchronization (granite parity, M23d).
//
// Every wiki window opens a BroadcastChannel keyed `wiki:workspace`. A window
// that mutates its layout `postWorkspaceUpdated`s a serialized snapshot stamped
// with `Date.now()`; peers that have `subscribe`d compare the inbound timestamp
// to their own last-known one and re-hydrate when it's newer. A per-instance
// `writerId` lets a window ignore its own echo (BroadcastChannel doesn't deliver
// to the sender, but the in-process test hub does, so the guard is required).
//
// The channel abstraction is injectable so tests drive an in-process hub
// (createInProcessChannelHub) without a real BroadcastChannel.

import type { SerializedWorkspace } from "./wikiWorkspace";

export interface WorkspaceUpdatedMessage {
  readonly type: "workspaceUpdated";
  readonly writerId: string;
  readonly updatedMs: number;
  readonly snapshot: SerializedWorkspace | null;
}

export type WorkspaceSyncMessage = WorkspaceUpdatedMessage;
export type WorkspaceSyncListener = (message: WorkspaceSyncMessage) => void;

/** The subset of `BroadcastChannel` we use (so tests can inject a fake). */
export interface SyncChannel {
  postMessage(data: unknown): void;
  addEventListener(type: "message", handler: (event: MessageEvent) => void): void;
  removeEventListener(type: "message", handler: (event: MessageEvent) => void): void;
  close(): void;
}

export interface WorkspaceSync {
  readonly writerId: string;
  postWorkspaceUpdated(snapshot: SerializedWorkspace | null, updatedMs: number): void;
  subscribe(listener: WorkspaceSyncListener): () => void;
  close(): void;
}

export const CHANNEL_NAME = "wiki:workspace";

function defaultChannelFactory(name: string): SyncChannel | null {
  if (typeof BroadcastChannel === "undefined") return null;
  try {
    return new BroadcastChannel(name) as unknown as SyncChannel;
  } catch {
    return null;
  }
}

let writerCounter = 0;
function freshWriterId(): string {
  writerCounter += 1;
  const rand =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID().slice(0, 8)
      : Math.random().toString(36).slice(2, 10);
  return `w-${rand}-${writerCounter.toString(36)}`;
}

export interface CreateWorkspaceSyncOptions {
  readonly channelFactory?: (name: string) => SyncChannel | null;
  readonly writerId?: string;
}

export function createWorkspaceSync(options: CreateWorkspaceSyncOptions = {}): WorkspaceSync {
  const factory = options.channelFactory ?? defaultChannelFactory;
  const writerId = options.writerId ?? freshWriterId();
  const channel = factory(CHANNEL_NAME);
  const listeners = new Set<WorkspaceSyncListener>();

  const onMessage = (event: MessageEvent) => {
    const data = event.data as WorkspaceSyncMessage | null;
    if (!data || typeof data !== "object" || data.type !== "workspaceUpdated") return;
    if (data.writerId === writerId) return; // ignore our own echo
    for (const listener of listeners) {
      try {
        listener(data);
      } catch {
        /* one bad subscriber shouldn't kill the bus */
      }
    }
  };
  channel?.addEventListener("message", onMessage);

  return {
    writerId,
    postWorkspaceUpdated(snapshot, updatedMs) {
      if (!channel) return;
      try {
        channel.postMessage({ type: "workspaceUpdated", writerId, updatedMs, snapshot });
      } catch {
        /* detached document / private mode — drop */
      }
    },
    subscribe(listener) {
      listeners.add(listener);
      return () => listeners.delete(listener);
    },
    close() {
      listeners.clear();
      channel?.removeEventListener("message", onMessage);
      channel?.close();
    },
  };
}

// ── in-process channel hub (tests) ──────────────────────────────────────────

export interface InProcessChannelHub {
  factory: (name: string) => SyncChannel;
  flush: () => Promise<void>;
  postCount: (name: string) => number;
}

/** Simulates BroadcastChannel endpoints sharing a name in one realm: a post
 *  delivers to all OTHER channels on that name asynchronously (sender excluded,
 *  matching real BC). Lets tests prove reconciliation + echo-suppression. */
export function createInProcessChannelHub(): InProcessChannelHub {
  const channels = new Map<string, Set<InProcessChannel>>();
  const pending: Array<() => void> = [];
  const counts = new Map<string, number>();

  class InProcessChannel implements SyncChannel {
    private handlers = new Set<(event: MessageEvent) => void>();
    private closed = false;
    constructor(public readonly name: string) {
      const set = channels.get(name) ?? new Set();
      set.add(this);
      channels.set(name, set);
    }
    postMessage(data: unknown): void {
      if (this.closed) return;
      counts.set(this.name, (counts.get(this.name) ?? 0) + 1);
      const cloned = JSON.parse(JSON.stringify(data));
      const peers = channels.get(this.name);
      if (!peers) return;
      for (const peer of [...peers].filter((c) => c !== this && !c.closed)) {
        pending.push(() => {
          if (peer.closed) return;
          for (const h of peer.handlers) h({ data: cloned } as MessageEvent);
        });
      }
    }
    addEventListener(_t: "message", handler: (event: MessageEvent) => void): void {
      this.handlers.add(handler);
    }
    removeEventListener(_t: "message", handler: (event: MessageEvent) => void): void {
      this.handlers.delete(handler);
    }
    close(): void {
      this.closed = true;
      this.handlers.clear();
      channels.get(this.name)?.delete(this);
    }
  }

  return {
    factory: (name) => new InProcessChannel(name),
    flush: async () => {
      while (pending.length > 0) {
        pending.shift()?.();
        await Promise.resolve();
      }
    },
    postCount: (name) => counts.get(name) ?? 0,
  };
}
