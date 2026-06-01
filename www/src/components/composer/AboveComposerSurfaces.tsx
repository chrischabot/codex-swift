import * as React from "react";
import { cn } from "@/lib/utils";
import { Target, Pencil, Pause, Play, X, Bot, Square, AtSign } from "lucide-react";

// ---------------------------------------------------------------------------
// Above-composer surfaces (prop-gated, default off).
//
// Mirrors the original "panel row" chrome that floats directly above the
// composer (above-composer-panel-row.js / above-composer-suggestions.js /
// composer-external-footer.js): a translucent, backdrop-blurred row with a
// top + side border that visually merges into the composer's rounded top.
//
// We reproduce the original's PanelRow primitive (icon + title + meta on the
// left; trailing + actions on the right) and use it to render two surfaces:
//   1. ThreadGoalPanel        — goal text + Edit / Pause / Resume / Clear goal
//   2. BackgroundSubagentsRow — aggregate diff stat, "Stop all", "@ to tag agents"
// ---------------------------------------------------------------------------

// PanelRow container — the bg-token-input-background/70 border-x border-t
// backdrop-blur surface from above-composer-panel-row.js (entity `m`),
// mapped onto the shadcn token set. `first` rounds the top corners to merge
// with the composer below.
function PanelRowSurface({
  first,
  className,
  children,
}: {
  first?: boolean;
  className?: string;
  children: React.ReactNode;
}) {
  return (
    <div
      className={cn(
        "relative min-w-0 overflow-clip border-x border-t border-[color:var(--border)]/80",
        "bg-background/70 text-foreground backdrop-blur-sm",
        first && "first:rounded-t-2xl rounded-t-2xl",
        className,
      )}
    >
      {children}
    </div>
  );
}

// The PanelRow itself — `C` in above-composer-panel-row.js: a flex row with a
// leading icon, a title (with optional meta), and a trailing/actions cluster.
function PanelRow({
  icon,
  title,
  meta,
  actions,
  className,
}: {
  icon?: React.ReactNode;
  title: React.ReactNode;
  meta?: React.ReactNode;
  actions?: React.ReactNode;
  className?: string;
}) {
  return (
    <div
      className={cn(
        "group flex min-w-0 items-center justify-between gap-2 px-3 py-1 text-sm",
        className,
      )}
    >
      <div className="flex min-w-0 flex-1 items-center gap-1.5">
        {icon != null && (
          <span className="flex h-4 shrink-0 items-center justify-center text-[color:var(--color-text-secondary)]">
            {icon}
          </span>
        )}
        <div className="min-w-0 flex-1 leading-4">
          <span className="truncate">{title}</span>
          {meta != null && (
            <span className="ml-1 text-[color:var(--color-text-tertiary)]">{meta}</span>
          )}
        </div>
      </div>
      {actions != null && (
        <div className="flex shrink-0 items-center gap-1">{actions}</div>
      )}
    </div>
  );
}

// Small ghost action button shared by the surfaces.
function PanelAction({
  icon,
  label,
  onClick,
  tone,
}: {
  icon?: React.ReactNode;
  label: string;
  onClick?: () => void;
  tone?: "danger";
}) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "inline-flex h-6 items-center gap-1 rounded-md px-1.5 text-xs font-medium",
        "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        tone === "danger" &&
          "text-[color:var(--color-red-500)] hover:bg-[color:var(--color-red-500)]/8 hover:text-[color:var(--color-red-500)]",
      )}
    >
      {icon}
      {label}
    </button>
  );
}

export interface ThreadGoalPanelProps {
  goal: string;
  /** "active" shows Pause; "paused" shows Resume. */
  status?: "active" | "paused";
  onEdit?: () => void;
  onPause?: () => void;
  onResume?: () => void;
  onClear?: () => void;
  /** Rounds the top corners (use when this is the topmost above-composer row). */
  first?: boolean;
}

// Thread-goal panel row: the persistent goal the agent is working toward, with
// Edit / Pause|Resume / Clear goal controls.
export function ThreadGoalPanel({
  goal,
  status = "active",
  onEdit,
  onPause,
  onResume,
  onClear,
  first = true,
}: ThreadGoalPanelProps) {
  return (
    <PanelRowSurface first={first}>
      <PanelRow
        icon={<Target className="size-3.5" />}
        title={<span className="font-medium">{goal}</span>}
        meta={status === "paused" ? "Paused" : undefined}
        actions={
          <>
            <PanelAction icon={<Pencil className="size-3" />} label="Edit" onClick={onEdit} />
            {status === "paused" ? (
              <PanelAction icon={<Play className="size-3" />} label="Resume" onClick={onResume} />
            ) : (
              <PanelAction icon={<Pause className="size-3" />} label="Pause" onClick={onPause} />
            )}
            <PanelAction
              icon={<X className="size-3" />}
              label="Clear goal"
              onClick={onClear}
              tone="danger"
            />
          </>
        }
      />
    </PanelRowSurface>
  );
}

export interface BackgroundSubagentsRowProps {
  /** Number of running background subagents. */
  count: number;
  /** Aggregate diff stat across the subagents. */
  added: number;
  removed: number;
  onStopAll?: () => void;
  /** Inserts an "@" into the composer so the user can tag an agent. */
  onTag?: () => void;
  /** Rounds the top corners (use when this is the topmost above-composer row). */
  first?: boolean;
}

// Background-subagents summary row: aggregate diff stat, a "Stop all" action,
// and an "@ to tag agents" affordance.
export function BackgroundSubagentsRow({
  count,
  added,
  removed,
  onStopAll,
  onTag,
  first = true,
}: BackgroundSubagentsRowProps) {
  return (
    <PanelRowSurface first={first}>
      <PanelRow
        icon={<Bot className="size-3.5" />}
        title={
          <span className="font-medium">
            {count} {count === 1 ? "agent" : "agents"} working in the background
          </span>
        }
        meta={
          added || removed ? (
            <span className="font-mono">
              <span className="text-[color:var(--color-charts-green)]">+{added}</span>{" "}
              <span className="text-[color:var(--color-charts-red)]">-{removed}</span>
            </span>
          ) : undefined
        }
        actions={
          <>
            <button
              type="button"
              onClick={onTag}
              className="inline-flex h-6 items-center gap-1 rounded-md px-1.5 text-xs text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground"
            >
              <AtSign className="size-3" />
              to tag agents
            </button>
            <PanelAction
              icon={<Square className="size-3 fill-current" />}
              label="Stop all"
              onClick={onStopAll}
              tone="danger"
            />
          </>
        }
      />
    </PanelRowSurface>
  );
}
