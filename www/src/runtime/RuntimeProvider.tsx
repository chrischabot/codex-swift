// Runtime provider — owns the Connector lifetime, holds the latest snapshot
// in component state, and exposes the dispatch surface the rest of the app
// imports from `@/state/store`. The Effect-backed AppStore stays around as
// the *MockConnector's* internal substrate; if you want a fully Effect
// dispatch chain in front of any connector, you can move makeMockConnector's
// closures into AppStore service methods.

import * as React from "react";
import type {
  Connector,
  ConnectorSnapshot,
  ConnectorStatus,
  DiffViewModel,
} from "./connector";
import { makeMockConnector } from "./connector-mock";
import { _bindConnector } from "@/state/store";

type ConnectorFactory = () => Promise<Connector> | Connector;

interface RuntimeCtxValue {
  connector: Connector;
  status: ConnectorStatus;
  snapshot: ConnectorSnapshot;
  refreshDiff: (threadId: string) => Promise<DiffViewModel | null>;
}

const RuntimeCtx = React.createContext<RuntimeCtxValue | null>(null);

interface ProviderProps {
  factory?: ConnectorFactory;
  children: React.ReactNode;
}

export function RuntimeProvider({ factory, children }: ProviderProps) {
  const [connector, setConnector] = React.useState<Connector | null>(null);
  const [status, setStatus] = React.useState<ConnectorStatus>({ kind: "connecting" });
  const [snapshot, setSnapshot] = React.useState<ConnectorSnapshot>({
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
  });

  React.useEffect(() => {
    let alive = true;
    let unsubSnap: (() => void) | undefined;
    let unsubStatus: (() => void) | undefined;
    let local: Connector | null = null;
    (async () => {
      const c = await (factory ?? makeMockConnector)();
      if (!alive) return;
      local = c;
      setConnector(c);
      unsubSnap = c.onSnapshot((s) => setSnapshot(s));
      unsubStatus = c.onStatus((s) => setStatus(s));
      await c.connect();
    })().catch((err) => {
      if (alive) setStatus({ kind: "error", message: String(err) });
    });
    return () => {
      alive = false;
      unsubSnap?.();
      unsubStatus?.();
      local?.disconnect().catch(() => {});
    };
  }, [factory]);

  const value: RuntimeCtxValue | null = connector
    ? {
        connector,
        status,
        snapshot,
        refreshDiff: (id) => connector.getDiff(id),
      }
    : null;

  // Side-channel binding so legacy `dispatch.X(...)` calls work outside React.
  React.useEffect(() => {
    if (value) _bindConnector(value);
  }, [value]);

  // Render once we have a connector. The bootstrap is fast (synchronous for
  // the mock) so there's no perceptible flash.
  if (!value) return null;
  return <RuntimeCtx.Provider value={value}>{children}</RuntimeCtx.Provider>;
}

export function useRuntime(): RuntimeCtxValue {
  const v = React.useContext(RuntimeCtx);
  if (!v) throw new Error("useRuntime outside RuntimeProvider");
  return v;
}
