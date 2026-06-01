import * as React from "react";
import { ChevronRight, Server, Wrench } from "lucide-react";
import { cn } from "@/lib/utils";
import { useAppData } from "@/state/store";
import { Switch } from "@/components/ui/switch";
import type { McpServer } from "@/domain/models";

// Side-panel MCP_APP tab (app-shell-tab-controller.js MCP_APP). Lists the
// registered MCP servers from useAppData().mcpServers with a status dot, tool
// count, the launch command (mono, truncated), an expandable tool list, and an
// enable/disable switch — mirroring mcp-settings.js's per-server rows.
//
// There is no connector mutation for MCP enable/disable yet, so the toggle is
// tracked as local optimistic state keyed by server id (additive, internal —
// DiffPanel's public props are untouched).
export function McpAppTab() {
  const { mcpServers } = useAppData();

  // Local enable/disable overrides keyed by server id. Seeded "disabled"
  // servers start disabled; everything else starts enabled.
  const [overrides, setOverrides] = React.useState<Record<string, boolean>>({});

  const isEnabled = React.useCallback(
    (s: McpServer) => overrides[s.id] ?? s.status !== "disabled",
    [overrides],
  );

  if (mcpServers.length === 0) {
    return (
      <div className="flex flex-1 flex-col items-center justify-center px-8 text-center">
        <Server className="size-5 text-[color:var(--color-text-tertiary)]" />
        <div className="mt-2 text-[13px] font-medium text-foreground">No MCP servers connected</div>
        <div className="mt-1 text-[12px] text-[color:var(--color-text-secondary)]">
          Add a server in Settings to use its tools.
        </div>
      </div>
    );
  }

  return (
    <div className="min-w-0 flex-1 overflow-y-auto">
      <div className="px-panel py-3 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
        MCP servers
      </div>
      <div className="space-y-px pb-3">
        {mcpServers.map((s) => (
          <ServerRow
            key={s.id}
            server={s}
            enabled={isEnabled(s)}
            onToggle={(next) => setOverrides((m) => ({ ...m, [s.id]: next }))}
          />
        ))}
      </div>
    </div>
  );
}

function StatusDot({ status, enabled }: { status: McpServer["status"]; enabled: boolean }) {
  // text-charts-green connected / text-charts-red error / muted disabled.
  const color = !enabled
    ? "bg-[color:var(--color-text-quaternary)]"
    : status === "connected"
      ? "bg-[color:var(--color-charts-green)]"
      : status === "error"
        ? "bg-[color:var(--color-charts-red)]"
        : status === "connecting"
          ? "bg-[color:var(--color-charts-orange)]"
          : "bg-[color:var(--color-text-quaternary)]";
  return (
    <span
      className={cn("size-2 shrink-0 rounded-full", color, status === "connecting" && enabled && "animate-pulse")}
      aria-hidden
    />
  );
}

function ServerRow({
  server,
  enabled,
  onToggle,
}: {
  server: McpServer;
  enabled: boolean;
  onToggle: (next: boolean) => void;
}) {
  const [open, setOpen] = React.useState(false);
  const tools = server.tools ?? [];
  const effectiveStatus: McpServer["status"] = enabled ? server.status : "disabled";

  return (
    <div className="px-panel">
      <div className="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-[color:var(--color-surface-hover)]">
        <button
          type="button"
          onClick={() => tools.length > 0 && setOpen((v) => !v)}
          className="flex min-w-0 flex-1 items-center gap-2 text-left"
          aria-expanded={open}
          disabled={tools.length === 0}
        >
          <ChevronRight
            className={cn(
              "size-3.5 shrink-0 text-[color:var(--color-text-tertiary)] transition-transform",
              open && "rotate-90",
              tools.length === 0 && "opacity-0",
            )}
          />
          <StatusDot status={effectiveStatus} enabled={enabled} />
          <span className="truncate text-[13px] font-medium text-foreground">{server.name}</span>
          <span className="shrink-0 text-[11.5px] text-[color:var(--color-text-tertiary)]">
            {server.toolCount} {server.toolCount === 1 ? "tool" : "tools"}
          </span>
        </button>
        <Switch
          size="sm"
          checked={enabled}
          onCheckedChange={onToggle}
          aria-label={`${enabled ? "Disable" : "Enable"} ${server.name}`}
        />
      </div>

      {/* Launch command — monospace, truncated to one line. */}
      <div
        className="ml-[1.65rem] truncate rounded bg-[color:var(--color-code-surface)] px-2 py-0.5 font-mono text-[11px] text-[color:var(--color-text-secondary)]"
        title={server.command}
      >
        {server.command}
      </div>

      {open && tools.length > 0 && (
        <ul className="ml-[1.65rem] mt-1 space-y-px pb-1">
          {tools.map((t) => (
            <li
              key={t}
              className="flex items-center gap-2 rounded px-2 py-1 text-[12px] text-[color:var(--color-text-secondary)]"
            >
              <Wrench className="size-3 shrink-0 text-[color:var(--color-text-tertiary)]" />
              <span className="truncate font-mono">{t}</span>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}
