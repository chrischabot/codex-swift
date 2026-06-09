import * as React from "react";
import { Command } from "cmdk";
import { Search } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { cn } from "@/lib/utils";
import type { WikiCommand } from "./commandRegistry";

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
  /** Commands to list — already availability-filtered by useWikiCommands. */
  commands: ReadonlyArray<WikiCommand>;
  /** Run the selected command by id. */
  onRun: (id: string) => void;
}

const itemClass =
  "flex h-9 items-center gap-2 rounded-md px-2 text-[13px] text-foreground aria-selected:bg-[color:var(--color-surface-hover)]";

// Hotkey hint chip — mirrors the shell CommandPalette's Kbd component so the
// two palettes look identical.
function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center rounded-md border-0 bg-current/10 px-1.5 py-0.5 font-sans text-xs leading-none text-current shadow-none">
      {children}
    </kbd>
  );
}

/**
 * Wiki Command Palette — granite's Command Palette ported onto www's cmdk +
 * shadcn Dialog stack (the same pattern as `components/shell/CommandPalette`
 * and `WikiQuickSwitcher`). Opened via Cmd-P from `useWikiCommands`, which also
 * owns the open state and the command list. cmdk supplies the fuzzy scorer;
 * selecting an item runs the command and closes the dialog.
 *
 * Commands are grouped by their `category` so the list reads like granite's
 * categorized palette. The first hotkey hint, if any, renders as a trailing
 * kbd chip.
 */
export function WikiCommandPalette({ open, onOpenChange, commands, onRun }: Props) {
  // Group commands by category, preserving registration order within a group
  // and first-seen order across groups. Uncategorized commands fall into a
  // trailing "Other" bucket.
  const groups = React.useMemo(() => {
    const order: string[] = [];
    const byCategory = new Map<string, WikiCommand[]>();
    for (const cmd of commands) {
      const key = cmd.category ?? "Other";
      if (!byCategory.has(key)) {
        byCategory.set(key, []);
        order.push(key);
      }
      byCategory.get(key)!.push(cmd);
    }
    return order.map((key) => ({ heading: key, items: byCategory.get(key)! }));
  }, [commands]);

  const select = (id: string) => {
    onOpenChange(false);
    // Defer so the dialog's close (focus restore) doesn't race a navigate.
    setTimeout(() => onRun(id), 0);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[560px] p-0" showClose={false}>
        <DialogTitle className="sr-only">Wiki command menu</DialogTitle>
        <DialogDescription className="sr-only">
          Search and run wiki commands
        </DialogDescription>
        <Command label="Wiki command menu">
          <div className="flex items-center gap-2 border-b border-[color:var(--border)] px-3">
            <Search className="size-4 text-[color:var(--color-text-tertiary)]" />
            <Command.Input
              autoFocus
              placeholder="Run a command…"
              className="h-11 flex-1 bg-transparent text-foreground outline-none placeholder:text-[color:var(--color-text-quaternary)]"
            />
          </div>
          <Command.List className="max-h-[400px] overflow-y-auto p-2">
            <Command.Empty className="px-3 py-6 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
              No matching commands
            </Command.Empty>
            {groups.map((group) => (
              <Command.Group
                key={group.heading}
                heading={group.heading}
                className={cn(
                  "[&_[cmdk-group-heading]]:px-2 [&_[cmdk-group-heading]]:py-1.5",
                  "[&_[cmdk-group-heading]]:text-[11px] [&_[cmdk-group-heading]]:font-medium",
                  "[&_[cmdk-group-heading]]:uppercase [&_[cmdk-group-heading]]:tracking-wide",
                  "[&_[cmdk-group-heading]]:text-[color:var(--color-text-tertiary)]",
                )}
              >
                {group.items.map((cmd) => {
                  const Icon = cmd.icon;
                  return (
                    <Command.Item
                      key={cmd.id}
                      // value drives cmdk's fuzzy match; include the category so a
                      // search like "create page" ranks the right item.
                      value={`${cmd.category ?? ""} ${cmd.name} ${cmd.id}`}
                      onSelect={() => select(cmd.id)}
                      className={itemClass}
                    >
                      {Icon ? (
                        <Icon className="size-4 shrink-0 text-[color:var(--color-text-tertiary)]" />
                      ) : (
                        <span className="size-4 shrink-0" aria-hidden />
                      )}
                      <span className="flex-1 truncate">{cmd.name}</span>
                      {cmd.hotkey ? <Kbd>{cmd.hotkey}</Kbd> : null}
                    </Command.Item>
                  );
                })}
              </Command.Group>
            ))}
          </Command.List>
        </Command>
      </DialogContent>
    </Dialog>
  );
}
