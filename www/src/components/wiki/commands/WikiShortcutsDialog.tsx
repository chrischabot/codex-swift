import * as React from "react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { wikiCommandRegistry, WIKI_EVENTS, type WikiCommand } from "./commandRegistry";

// M29 keyboard-shortcuts help overlay. Opened by the "Show keyboard shortcuts"
// command (⌘/, dispatched by useWikiCommands) via a window CustomEvent, so any
// surface that mounts this once gets the overlay without prop-threading. Lists
// every registered command that carries an accelerator hint, grouped by
// category — a single source of truth with the palette + dispatcher.

function groupByCategory(commands: ReadonlyArray<WikiCommand>): Array<[string, WikiCommand[]]> {
  const groups = new Map<string, WikiCommand[]>();
  for (const c of commands) {
    if (!c.hotkey) continue;
    const cat = c.category ?? "General";
    const arr = groups.get(cat) ?? [];
    arr.push(c);
    groups.set(cat, arr);
  }
  return Array.from(groups.entries());
}

export function WikiShortcutsDialog() {
  const [open, setOpen] = React.useState(false);

  React.useEffect(() => {
    const onShow = () => setOpen(true);
    window.addEventListener(WIKI_EVENTS.showShortcuts, onShow);
    return () => window.removeEventListener(WIKI_EVENTS.showShortcuts, onShow);
  }, []);

  // Snapshot the registry each time the dialog opens (commands are static, but a
  // late-registered one should still appear).
  const groups = React.useMemo(
    () => (open ? groupByCategory(wikiCommandRegistry.list()) : []),
    [open],
  );

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent className="sm:max-w-[460px]">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
          <DialogDescription>Wiki commands and their accelerators.</DialogDescription>
        </DialogHeader>
        <div className="max-h-[60vh] overflow-y-auto pr-1">
          {groups.map(([category, cmds]) => (
            <div key={category} className="mb-3 last:mb-0">
              <div className="mb-1 text-[11px] font-semibold uppercase tracking-[0.06em] text-[color:var(--color-text-tertiary)]">
                {category}
              </div>
              {cmds.map((c) => (
                <div
                  key={c.id}
                  className="flex items-center justify-between gap-3 rounded-md px-2 py-1.5 text-[13px] hover:bg-[color:var(--color-surface-hover)]"
                >
                  <span className="min-w-0 truncate text-foreground">{c.name}</span>
                  <kbd className="shrink-0 rounded border border-[color:var(--border)] bg-[color:var(--code-surface)] px-1.5 py-0.5 font-mono text-[12px] text-[color:var(--color-text-secondary)]">
                    {c.hotkey}
                  </kbd>
                </div>
              ))}
            </div>
          ))}
          {/* Bindings owned outside the registry, surfaced for completeness. */}
          <div className="mb-0 mt-1 border-t border-[color:var(--border)] pt-2">
            <div className="mb-1 text-[11px] font-semibold uppercase tracking-[0.06em] text-[color:var(--color-text-tertiary)]">
              Palette
            </div>
            <div className="flex items-center justify-between gap-3 rounded-md px-2 py-1.5 text-[13px]">
              <span className="text-foreground">Command palette</span>
              <kbd className="shrink-0 rounded border border-[color:var(--border)] bg-[color:var(--code-surface)] px-1.5 py-0.5 font-mono text-[12px] text-[color:var(--color-text-secondary)]">
                ⌘P
              </kbd>
            </div>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
