import * as React from "react";
import { dispatch } from "@/state/store";

// Settings sections backed by live backend reads (account/read,
// account/rateLimits/read, experimentalFeature/list, memory/reset).

function useAsync<T>(fn: () => Promise<T>, initial: T): T {
  const [v, setV] = React.useState<T>(initial);
  React.useEffect(() => { let a = true; fn().then((r) => { if (a) setV(r); }).catch(() => {}); return () => { a = false; }; }, []);
  return v;
}

function Row({ k, v }: { k: string; v: React.ReactNode }) {
  return (
    <div className="flex justify-between gap-4 border-b border-[color:var(--color-divider)] py-2 text-[13px]">
      <span className="text-[color:var(--color-text-secondary)]">{k}</span>
      <span className="min-w-0 truncate text-right text-foreground">{v}</span>
    </div>
  );
}

export function ProfileSection() {
  const acct = useAsync<{ account?: unknown; requiresOpenaiAuth?: boolean }>(() => dispatch.readAccount(), {});
  const a = (acct.account ?? {}) as Record<string, unknown>;
  return (
    <div>
      <Row k="Signed in" v={acct.requiresOpenaiAuth === false ? "Yes" : "Authentication required"} />
      {typeof a.email === "string" && <Row k="Email" v={a.email} />}
      {typeof a.planType === "string" && <Row k="Plan" v={a.planType} />}
      {typeof a.accountId === "string" && <Row k="Account" v={a.accountId} />}
      {Object.keys(a).length === 0 && <div className="py-3 text-[13px] text-[color:var(--color-text-secondary)]">No account details available.</div>}
    </div>
  );
}

export function UsageSection() {
  const limits = useAsync<Record<string, unknown>>(() => dispatch.readRateLimits(), {});
  const rl = (limits.rate_limits ?? limits) as Record<string, unknown>;
  const entries = Object.entries(rl);
  return (
    <div>
      {entries.length === 0
        ? <div className="py-3 text-[13px] text-[color:var(--color-text-secondary)]">No usage data available.</div>
        : entries.map(([k, v]) => <Row key={k} k={k} v={typeof v === "object" ? JSON.stringify(v) : String(v)} />)}
    </div>
  );
}

export function ExperimentalSection() {
  const [flags, setFlags] = React.useState<{ id: string; enabled: boolean }[]>([]);
  React.useEffect(() => { let a = true; dispatch.listExperimentalFeatures().then((f) => { if (a) setFlags(f); }).catch(() => {}); return () => { a = false; }; }, []);
  return (
    <div>
      {flags.length === 0 && <div className="py-3 text-[13px] text-[color:var(--color-text-secondary)]">No experimental features.</div>}
      {flags.map((f) => (
        <label key={f.id} className="flex items-center justify-between border-b border-[color:var(--color-divider)] py-2 text-[13px]">
          <span>{f.id}</span>
          <input type="checkbox" checked={f.enabled} onChange={(e) => {
            // Capture the new value BEFORE any await — a controlled checkbox is
            // reverted to its state value on the next render, so reading
            // e.target.checked after the await would see the stale (old) value
            // and the toggle would never stick in the UI.
            const next = e.target.checked;
            setFlags((cur) => cur.map((x) => (x.id === f.id ? { ...x, enabled: next } : x)));
            void dispatch.setExperimentalFeature(f.id, next);
          }} />
        </label>
      ))}
    </div>
  );
}
