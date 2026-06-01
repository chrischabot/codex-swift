import * as React from "react";
import { cn } from "@/lib/utils";
import {
  FileText,
  Bot,
  Sparkles,
  Plug,
  MonitorSmartphone,
  AppWindow,
} from "lucide-react";

interface Props {
  open: boolean;
  query: string;
  anchorEl: HTMLElement | null;
  /**
   * Optional caret rect (viewport coords) emitted by the rich editor. When
   * present the popover anchors just above the caret token instead of the
   * input's bottom-left, matching the original inline-mention surface.
   */
  anchorRect?: DOMRect | null;
  onPick: (label: string) => void;
  onClose: () => void;
}

interface MentionItem {
  id: string;
  label: string;
}

interface Section {
  heading: string;
  icon: React.ReactNode;
  /** Shown while async results for this section are still loading. */
  loadingMessage: string;
  loading?: boolean;
  items: MentionItem[];
}

// Anchored @-mention autocomplete. The original renders a cmdk command menu
// (at-mention-list-with-sources.js) keyed off [cmdk-item]; here we mirror its
// visual model (rounded-lg items, opacity .75 -> 1 on selection,
// list-hover-background, per-section loading + "No results" empty state) with a
// lightweight anchored overlay. Sources match use-at-mention-sections.js:
// Files, Agents (Live / Custom), Skills, Plugins, Computer use, Desktop apps.
export function MentionsPopover({ open, query, anchorEl, anchorRect, onPick, onClose }: Props) {
  const ref = React.useRef<HTMLDivElement | null>(null);
  const [pos, setPos] = React.useState<{ top: number; left: number } | null>(null);
  const [active, setActive] = React.useState(0);
  // Simulate the original async file search (debounced "Searching files…").
  const [filesLoading, setFilesLoading] = React.useState(false);

  React.useEffect(() => {
    if (!open) return;
    if (anchorRect) {
      // Anchor above the caret token (clamped to the viewport's left edge).
      setPos({ top: anchorRect.top - 200, left: Math.max(8, anchorRect.left) });
      return;
    }
    if (!anchorEl) return;
    const r = anchorEl.getBoundingClientRect();
    setPos({ top: r.bottom - 200, left: r.left + 24 });
  }, [open, anchorEl, anchorRect]);

  React.useEffect(() => {
    if (!open) return;
    setFilesLoading(true);
    const t = setTimeout(() => setFilesLoading(false), 250);
    return () => clearTimeout(t);
  }, [query, open]);

  const sections = React.useMemo<Section[]>(() => {
    const q = query.toLowerCase();
    const match = (s: string) => !q || s.toLowerCase().includes(q);
    return [
      {
        heading: "Files",
        icon: <FileText className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Searching files…",
        loading: filesLoading,
        items: [
          { id: "f-readme", label: "README.md" },
          { id: "f-types", label: "src/types.ts" },
          { id: "f-pkg", label: "package.json" },
        ].filter((f) => match(f.label)),
      },
      {
        heading: "Live agents",
        icon: <Bot className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading agents…",
        items: [{ id: "a-codex", label: "codex" }].filter((a) => match(a.label)),
      },
      {
        heading: "Custom agents",
        icon: <Bot className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading agents…",
        items: [{ id: "a-reviewer", label: "reviewer" }].filter((a) => match(a.label)),
      },
      {
        heading: "Skills",
        icon: <Sparkles className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading skills…",
        items: [
          { id: "s-verify", label: "verify" },
          { id: "s-review", label: "code-review" },
        ].filter((s) => match(s.label)),
      },
      {
        heading: "Plugins",
        icon: <Plug className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading plugins…",
        items: [{ id: "p-playwright", label: "playwright" }].filter((p) => match(p.label)),
      },
      {
        heading: "Computer use",
        icon: <MonitorSmartphone className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading…",
        items: [{ id: "c-screen", label: "Take screenshot" }].filter((c) => match(c.label)),
      },
      {
        heading: "Desktop apps",
        icon: <AppWindow className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />,
        loadingMessage: "Loading desktop apps…",
        items: [{ id: "d-terminal", label: "Terminal" }].filter((d) => match(d.label)),
      },
    ].filter((s) => s.loading || s.items.length > 0);
  }, [query, filesLoading]);

  // Flatten options so the active index works across sections.
  const flat = React.useMemo(
    () => sections.flatMap((s) => s.items.map((i) => ({ sectionId: s.heading, ...i }))),
    [sections],
  );

  React.useEffect(() => {
    if (!open) return;
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "ArrowDown") {
        e.preventDefault();
        setActive((i) => Math.min(flat.length - 1, i + 1));
      } else if (e.key === "ArrowUp") {
        e.preventDefault();
        setActive((i) => Math.max(0, i - 1));
      } else if (e.key === "Enter" || e.key === "Tab") {
        const pick = flat[active];
        if (pick) {
          e.preventDefault();
          onPick(pick.label);
        }
      } else if (e.key === "Escape") {
        e.preventDefault();
        onClose();
      }
    };
    window.addEventListener("keydown", onKey, true);
    return () => window.removeEventListener("keydown", onKey, true);
  }, [open, flat, active, onPick, onClose]);

  React.useEffect(() => {
    setActive(0);
  }, [query]);

  if (!open || !pos) return null;
  const anyResults = flat.length > 0 || filesLoading;
  return (
    <div
      ref={ref}
      style={{ position: "fixed", top: pos.top, left: pos.left }}
      className="z-50 flex w-[260px] flex-col gap-1 overflow-hidden rounded-2xl border border-[color:var(--border)] bg-popover/95 p-1 text-popover-foreground shadow-[var(--shadow-popover)] backdrop-blur-lg"
    >
      {!anyResults ? (
        <div className="flex min-h-6 items-center px-2 text-sm text-[color:var(--color-text-tertiary)]">
          No results
        </div>
      ) : (
        sections.map((s) => (
          <div key={s.heading}>
            <div className="px-2 py-1 text-xs font-medium text-[color:var(--color-text-tertiary)]">
              {s.heading}
            </div>
            {s.loading && s.items.length === 0 ? (
              <div className="flex min-h-6 items-center px-2 text-sm text-[color:var(--color-text-tertiary)] opacity-60">
                {s.loadingMessage}
              </div>
            ) : (
              s.items.map((it) => {
                const i = flat.findIndex((f) => f.id === it.id);
                return (
                  <button
                    key={it.id}
                    type="button"
                    onMouseEnter={() => setActive(i)}
                    onClick={() => onPick(it.label)}
                    className={cn(
                      "flex min-h-6 w-full items-center gap-2 rounded-lg px-2 text-left text-sm opacity-75",
                      i === active && "bg-[color:var(--color-surface-hover)] opacity-100",
                    )}
                  >
                    {s.icon}
                    <span className="truncate">{it.label}</span>
                  </button>
                );
              })
            )}
          </div>
        ))
      )}
    </div>
  );
}
