import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Button } from "@/components/ui/button";
import { Link, ChevronDown, Github, Mail, Calendar, FileText, Plus } from "lucide-react";
import { useAppData } from "@/state/store";
import { useRuntime } from "@/runtime/RuntimeProvider";

// NET-NEW (no original counterpart): the original Codex top-right cluster
// (app-shell.js `Fn` end slot) is a generic page-registered action area, not a
// connections menu. This popover is an intentional addition for this app — it
// lists which integrations are wired up for the current workspace/identity and
// links to /plugins/manage. It is NOT a port of any original module.
export function ConnectionsPopover() {
  const { apps } = useAppData();
  const { status } = useRuntime();
  const connected = apps.filter((a) => a.enabled);
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="iconSm" aria-label="Connections" className="text-[color:var(--color-blue-400)]">
          <Link />
          <ChevronDown className="!size-2.5 opacity-60" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" sideOffset={8} className="w-[320px] p-2">
        <div className="flex items-center justify-between px-2 pb-1.5 pt-1 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
          <span>Connections</span>
          <span className="flex items-center gap-1.5">
            <span
              className={
                status.kind === "connected"
                  ? "size-2 rounded-full bg-[color:var(--color-green-500)]"
                  : "size-2 rounded-full bg-[color:var(--color-text-quaternary)]"
              }
            />
            {status.kind === "connected" ? status.clientId ?? "Connected" : status.kind}
          </span>
        </div>

        <div className="space-y-px">
          {connected.length === 0 ? (
            <div className="px-2 py-2 text-[12.5px] text-[color:var(--color-text-tertiary)]">
              No apps connected. <a className="text-[color:var(--color-blue-400)] hover:underline" href="/plugins/manage">Manage</a>
            </div>
          ) : (
            connected.map((a) => (
              <div key={a.id} className="flex items-center gap-2 rounded-md px-2 py-1.5 hover:bg-[color:var(--color-surface-hover)]">
                <div
                  className="flex size-6 items-center justify-center rounded text-[11px] font-semibold text-white"
                  style={{ background: a.iconBg }}
                >
                  {iconFor(a.iconLetter)}
                </div>
                <div className="min-w-0 flex-1 truncate text-[13px]">{a.name}</div>
                <span className="text-[11px] text-[color:var(--color-green-500)]">Connected</span>
              </div>
            ))
          )}
        </div>

        <div className="mt-1 border-t border-[color:var(--color-divider)] pt-1">
          <a
            href="/plugins"
            className="flex h-7 items-center gap-2 rounded-md px-2 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
          >
            <Plus className="size-3.5" /> Connect another app
          </a>
        </div>
      </PopoverContent>
    </Popover>
  );
}

function iconFor(letter: string) {
  switch (letter) {
    case "G":
      return <Github className="size-3.5" />;
    case "✉":
      return <Mail className="size-3.5" />;
    case "📅":
      return <Calendar className="size-3.5" />;
    default:
      return <FileText className="size-3.5" />;
  }
}
