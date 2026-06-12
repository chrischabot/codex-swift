import * as React from "react";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { RotateCcw } from "lucide-react";
import { wikiCommandRegistry, WIKI_EVENTS, type WikiCommand } from "./commandRegistry";
import { formatHotkey } from "./hotkeyMatch";
import {
  useHotkeyOverrides,
  setHotkeyOverride,
  resetHotkeyOverrides,
} from "./hotkeyOverrides";

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

/** A rebindable accelerator chip: click to capture a new chord, Esc cancels,
 *  Backspace/Delete clears the override (restores the built-in). */
function HotkeyChip({ command, custom }: { command: WikiCommand; custom?: string }) {
  const [capturing, setCapturing] = React.useState(false);
  const accel = custom ?? command.hotkey ?? "";

  React.useEffect(() => {
    if (!capturing) return;
    const onKey = (e: KeyboardEvent) => {
      e.preventDefault();
      e.stopPropagation();
      if (e.key === "Escape") {
        setCapturing(false);
        return;
      }
      if (e.key === "Backspace" || e.key === "Delete") {
        setHotkeyOverride(command.id, ""); // clear → built-in restored
        setCapturing(false);
        return;
      }
      const next = formatHotkey(e);
      if (!next) return; // bare modifier — keep waiting
      setHotkeyOverride(command.id, next);
      setCapturing(false);
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [capturing, command.id]);

  return (
    <span className="flex shrink-0 items-center gap-1">
      <button
        type="button"
        onClick={() => setCapturing((v) => !v)}
        title="Click to rebind"
        className="rounded border border-[color:var(--border)] bg-[color:var(--code-surface)] px-1.5 py-0.5 font-mono text-[12px] text-[color:var(--color-text-secondary)] hover:border-[color:var(--text-link)]"
      >
        {capturing ? "press keys…" : accel || "—"}
      </button>
      {custom ? (
        <button
          type="button"
          onClick={() => setHotkeyOverride(command.id, "")}
          title="Reset to default"
          className="text-[color:var(--color-text-quaternary)] hover:text-foreground"
        >
          <RotateCcw className="size-3" />
        </button>
      ) : null}
    </span>
  );
}

export function WikiShortcutsDialog() {
  const [open, setOpen] = React.useState(false);
  const overrides = useHotkeyOverrides();

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
                  <HotkeyChip command={c} custom={overrides[c.id]} />
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
          <div className="mt-3 flex items-center justify-between border-t border-[color:var(--border)] pt-2 text-[11px] text-[color:var(--color-text-quaternary)]">
            <span>Click a shortcut to rebind · Esc cancels · ⌫ clears</span>
            {Object.keys(overrides).length > 0 ? (
              <button
                type="button"
                onClick={() => resetHotkeyOverrides()}
                className="inline-flex items-center gap-1 hover:text-foreground"
              >
                <RotateCcw className="size-3" /> Reset all
              </button>
            ) : null}
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}
