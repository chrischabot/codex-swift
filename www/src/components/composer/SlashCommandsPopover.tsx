import * as React from "react";
import { cn } from "@/lib/utils";
import {
  Share,
  Eraser,
  Pencil,
  Download,
  ScanSearch,
  CircleCheck,
  CircleHelp,
  type LucideIcon,
} from "lucide-react";

export interface Command {
  id: string;
  name: string;            // "/share"
  hint: string;            // short description
  Icon: LucideIcon;
}

// NET-NEW (mock only): the original sources the slash-command set from the
// controller. This is a representative mock list.
const COMMANDS: Command[] = [
  { id: "share",   name: "/share",   hint: "Share this thread to a link", Icon: Share },
  { id: "clear",   name: "/clear",   hint: "Start a fresh turn (keep history)", Icon: Eraser },
  { id: "title",   name: "/title",   hint: "Rename the current chat", Icon: Pencil },
  { id: "export",  name: "/export",  hint: "Download transcript as Markdown", Icon: Download },
  { id: "review",  name: "/review",  hint: "Run a code-review pass on the diff", Icon: ScanSearch },
  { id: "verify",  name: "/verify",  hint: "Run the verify skill on the change", Icon: CircleCheck },
  { id: "help",    name: "/help",    hint: "Show available slash commands", Icon: CircleHelp },
];

interface Props {
  open: boolean;
  query: string;
  anchorEl: HTMLElement | null;
  /** Optional caret rect (viewport coords) from the rich editor; see MentionsPopover. */
  anchorRect?: DOMRect | null;
  onPick: (cmd: Command) => void;
  onClose: () => void;
}

// Anchored slash-command autocomplete. Mirrors the original cmdk command menu
// (slash-command-item.js): rounded-lg items at opacity .75 -> 1 on selection,
// list-hover-background, a leading icon-xs icon, and an `ml-auto` trailing meta
// region with opacity-80. Renders a "No results" empty state when nothing
// matches.
export function SlashCommandsPopover({ open, query, anchorEl, anchorRect, onPick, onClose }: Props) {
  const [active, setActive] = React.useState(0);
  const [pos, setPos] = React.useState<{ top: number; left: number } | null>(null);

  React.useEffect(() => {
    if (!open) return;
    if (anchorRect) {
      setPos({ top: anchorRect.top - 220, left: Math.max(8, anchorRect.left) });
      return;
    }
    if (!anchorEl) return;
    const r = anchorEl.getBoundingClientRect();
    setPos({ top: r.bottom - 220, left: r.left + 24 });
  }, [open, anchorEl, anchorRect]);

  const filtered = React.useMemo(() => {
    const q = query.toLowerCase();
    return COMMANDS.filter((c) => !q || c.name.toLowerCase().startsWith("/" + q.replace(/^\//, "")));
  }, [query]);

  React.useEffect(() => setActive(0), [query]);

  React.useEffect(() => {
    if (!open) return;
    const handler = (e: KeyboardEvent) => {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setActive((i) => Math.min(filtered.length - 1, i + 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setActive((i) => Math.max(0, i - 1));
      } else if (e.key === "Enter" || e.key === "Tab") {
        const pick = filtered[active];
        if (pick) {
          e.preventDefault();
          onPick(pick);
        }
      } else if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", handler, true);
    return () => window.removeEventListener("keydown", handler, true);
  }, [open, filtered, active, onPick, onClose]);

  if (!open || !pos) return null;
  return (
    <div
      style={{ position: "fixed", top: pos.top, left: pos.left }}
      className="z-50 flex w-[280px] flex-col gap-1 overflow-hidden rounded-2xl border border-[color:var(--border)] bg-popover/95 p-1 text-popover-foreground shadow-[var(--shadow-popover)] backdrop-blur-lg"
    >
      <div className="px-2 py-1 text-xs font-medium text-[color:var(--color-text-tertiary)]">
        Slash commands
      </div>
      {filtered.length === 0 ? (
        <div className="flex min-h-6 items-center px-2 text-sm text-[color:var(--color-text-tertiary)]">
          No results
        </div>
      ) : (
        filtered.map((c, i) => (
          <button
            key={c.id}
            onMouseEnter={() => setActive(i)}
            onClick={() => onPick(c)}
            className={cn(
              "flex min-h-6 w-full min-w-0 items-center gap-2 rounded-lg px-2 text-left text-sm opacity-75",
              i === active && "bg-[color:var(--color-surface-hover)] opacity-100",
            )}
          >
            <c.Icon className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" />
            <span className="truncate">{c.name}</span>
            <span className="ml-auto flex min-w-0 items-center gap-2">
              <span className="shrink-0 truncate text-sm text-[color:var(--color-text-tertiary)] opacity-80">{c.hint}</span>
            </span>
          </button>
        ))
      )}
    </div>
  );
}
