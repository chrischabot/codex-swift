import * as React from "react";
import { useParams } from "react-router-dom";
import {
  GitCommit,
  GitBranch,
  MessageSquare,
  ShieldCheck,
  Box,
  FileText,
  Circle,
} from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { TimelineEvent } from "@/domain/models";

// Side-panel TIMELINE tab (app-shell-tab-controller.js TIMELINE). Renders the
// per-thread event stream from connector.getTimeline(threadId) as a vertical
// timeline (icon per kind, title, optional detail, relative time).
//
// The active thread id is read internally from the route so DiffPanel's public
// props stay unchanged (ThreadPage passes the same props as before).
export function TimelineTab() {
  const { threadId } = useParams();
  const { connector } = useRuntime();
  const [events, setEvents] = React.useState<TimelineEvent[] | null>(null);

  React.useEffect(() => {
    if (!threadId) {
      setEvents([]);
      return;
    }
    let alive = true;
    const load = () => {
      connector
        .getTimeline(threadId)
        .then((e) => {
          // Only update when the event set actually changed, so the 2s poll
          // doesn't force a re-render + re-sort (and disrupt scroll/selection)
          // every tick when nothing is new.
          if (!alive) return;
          setEvents((cur) =>
            cur && cur.length === e.length && cur[0]?.id === e[0]?.id ? cur : e);
        })
        .catch(() => { if (alive) setEvents((cur) => cur ?? []); });
    };
    load();
    // Timeline events accumulate from the live stream; poll while the tab is
    // open so it stays current without a manual refresh.
    const t = setInterval(load, 2000);
    return () => {
      alive = false;
      clearInterval(t);
    };
  }, [threadId, connector]);

  if (events == null) {
    return (
      <div className="flex flex-1 items-center justify-center text-[12px] text-[color:var(--color-text-tertiary)]">
        Loading timeline…
      </div>
    );
  }

  if (events.length === 0) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center px-8 text-center">
        <Circle className="size-5 text-[color:var(--color-text-tertiary)]" />
        <div className="mt-2 text-[13px] font-medium text-foreground">No timeline events</div>
        <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
          Turns, commits, and approvals for this thread will appear here.
        </div>
      </div>
    );
  }

  // Sort most-recent-first to match the original event stream.
  const ordered = [...events].sort((a, b) => b.at - a.at);

  return (
    <div className="min-w-0 flex-1 overflow-y-auto px-panel py-3">
      <ol className="relative ml-2 space-y-0">
        {ordered.map((ev, i) => (
          <TimelineRow key={ev.id} event={ev} last={i === ordered.length - 1} />
        ))}
      </ol>
    </div>
  );
}

function TimelineRow({ event, last }: { event: TimelineEvent; last: boolean }) {
  const { Icon, color } = iconFor(event.kind);
  return (
    <li className="relative flex gap-3 pb-4">
      {/* Connector rail */}
      {!last && (
        <span
          aria-hidden
          className="absolute left-[11px] top-6 bottom-0 w-px bg-[color:var(--color-divider)]"
        />
      )}
      <span
        className="relative z-10 flex size-6 shrink-0 items-center justify-center rounded-full border border-[color:var(--color-divider)] bg-background"
      >
        <Icon className={cnColor(color)} />
      </span>
      <div className="min-w-0 flex-1 pt-0.5">
        <div className="flex items-baseline gap-2">
          <span className="truncate text-[12.5px] font-medium text-foreground">{event.title}</span>
          <time className="ml-auto shrink-0 text-[11px] text-[color:var(--color-text-tertiary)]">
            {relativeTime(event.at)}
          </time>
        </div>
        {event.detail && (
          <div className="mt-0.5 truncate text-[11.5px] text-[color:var(--color-text-secondary)]">
            {event.detail}
          </div>
        )}
      </div>
    </li>
  );
}

function cnColor(color: string) {
  return `size-3.5 ${color}`;
}

function iconFor(kind: TimelineEvent["kind"]): {
  Icon: React.ComponentType<{ className?: string }>;
  color: string;
} {
  switch (kind) {
    case "commit":
      return { Icon: GitCommit, color: "text-charts-purple" };
    case "branch":
      return { Icon: GitBranch, color: "text-charts-blue" };
    case "approval":
      return { Icon: ShieldCheck, color: "text-charts-green" };
    case "sandbox":
      return { Icon: Box, color: "text-charts-orange" };
    case "file":
      return { Icon: FileText, color: "text-[color:var(--color-text-secondary)]" };
    case "turn":
    default:
      return { Icon: MessageSquare, color: "text-[color:var(--color-text-secondary)]" };
  }
}

// Compact relative time ("3m", "2h", "5d"), falling back to a date for older
// events — mirroring the original timeline's relative-time formatting.
function relativeTime(at: number): string {
  const diff = Date.now() - at;
  const sec = Math.round(diff / 1000);
  if (sec < 60) return "now";
  const min = Math.round(sec / 60);
  if (min < 60) return `${min}m`;
  const hr = Math.round(min / 60);
  if (hr < 24) return `${hr}h`;
  const day = Math.round(hr / 24);
  if (day < 7) return `${day}d`;
  return new Date(at).toLocaleDateString(undefined, { month: "short", day: "numeric" });
}
