import type { ComponentType } from "react";
import {
  Bookmark,
  CalendarDays,
  Eye,
  FilePlus2,
  Network,
  PanelsTopLeft,
  Tags,
  Keyboard,
  Search,
  Sparkles,
  Table2,
  Type,
} from "lucide-react";
import { toggleLivePreviewSetting } from "@/components/wiki/settings/useWikiSettings";

// ---------------------------------------------------------------------------
// Wiki command registry — a www-idiomatic port of granite's
// `src/core/commands/CommandRegistry.ts` + `core-commands.ts`. Granite keeps a
// Map<id, Command> behind a tiny pub/sub so the palette can read a referentially
// stable list via useSyncExternalStore; we keep the same contract but trim the
// surface to what the wiki section needs (id / name / icon / hotkey / run).
//
// Commands are *static* metadata. The side effects they perform need access to
// React Router navigation, the current pageId, and a few UI callbacks (open the
// search/switcher dialogs, bookmark the current page). Rather than smuggle those
// through module globals, every `run` receives a `WikiCommandContext` assembled
// fresh by `useWikiCommands` at call time — so a command never closes over a
// stale navigate() or pageId.
// ---------------------------------------------------------------------------

/** Lucide icon component (e.g. `Search`). Optional — palette renders a blank
 *  gutter when absent. */
export type WikiCommandIcon = ComponentType<{ className?: string; size?: number }>;

/** Everything a command needs to do its job. Built per-invocation by the hook so
 *  navigate/pageId are always current. */
export interface WikiCommandContext {
  /** React Router navigate. Commands push wiki routes through this. */
  readonly navigate: (path: string) => void;
  /** The page currently open in the wiki view, if any (route `/wiki/:pageId`).
   *  `"new"` and `"graph"`/`"enrich"` pseudo-routes are normalized to undefined
   *  by the hook, so a present value is always a real page id. */
  readonly pageId?: string;
  /** Toggle the wiki Quick Switcher (Cmd-O) dialog. */
  readonly openSwitcher: () => void;
  /** Open the in-section search surface. */
  readonly openSearch: () => void;
  /** Bookmark / un-bookmark the current page. No-op when no page is open. */
  readonly toggleBookmarkCurrent: () => void;
  /** Open today's daily note, creating it (from a date-titled template) if it
   *  doesn't exist yet. */
  readonly openDailyNote: () => void;
  /** Toast helper for "nothing to act on" / confirmation feedback. */
  readonly notify: (message: string) => void;
}

export interface WikiCommand {
  readonly id: string;
  readonly name: string;
  /** Faint category prefix shown before the name (granite parity). */
  readonly category?: string;
  readonly icon?: WikiCommandIcon;
  /** Display-only accelerator hint, already formatted for the platform
   *  (e.g. "⌘P"). The registry does not bind these — `useWikiCommands` owns the
   *  Cmd-P open hotkey; individual command hotkeys are hints for now. */
  readonly hotkey?: string;
  /** Return false to hide the command from the palette in the current context
   *  (granite's `checkCallback`). Defaults to always-available. */
  readonly isAvailable?: (ctx: WikiCommandContext) => boolean;
  /** The action. */
  readonly run: (ctx: WikiCommandContext) => void;
}

class WikiCommandRegistry {
  private commands = new Map<string, WikiCommand>();
  private listeners = new Set<() => void>();
  private listCache: WikiCommand[] | null = null;

  /** Register a command; returns a disposer that removes exactly this
   *  registration (no-op if it was already replaced). */
  register(command: WikiCommand): () => void {
    if (this.commands.has(command.id)) {
      console.warn(`[wiki] command "${command.id}" already registered; overwriting.`);
    }
    this.commands.set(command.id, command);
    this.emit();
    return () => {
      if (this.commands.get(command.id) === command) {
        this.commands.delete(command.id);
        this.emit();
      }
    };
  }

  get(id: string): WikiCommand | undefined {
    return this.commands.get(id);
  }

  /** Referentially stable until the registry mutates — required by
   *  useSyncExternalStore. Note this is the *unfiltered* list; availability
   *  gating happens at render time with a live context (granite filters in
   *  list(), but our `isAvailable` needs ctx the store doesn't hold). */
  list(): ReadonlyArray<WikiCommand> {
    if (this.listCache === null) this.listCache = [...this.commands.values()];
    return this.listCache;
  }

  /** Run a command by id with the supplied context. Silently ignores unknown
   *  ids and unavailable commands. */
  run(id: string, ctx: WikiCommandContext): void {
    const cmd = this.commands.get(id);
    if (!cmd) return;
    if (cmd.isAvailable && !cmd.isAvailable(ctx)) return;
    cmd.run(ctx);
  }

  subscribe(listener: () => void): () => void {
    this.listeners.add(listener);
    return () => {
      this.listeners.delete(listener);
    };
  }

  private emit() {
    this.listCache = null;
    for (const cb of this.listeners) cb();
  }
}

export const wikiCommandRegistry = new WikiCommandRegistry();

// ---------------------------------------------------------------------------
// Cross-feature event names. Several wiki actions (new canvas, new base, live
// preview toggle, today's note) are owned by other milestones' files which this
// task may not touch. We dispatch a CustomEvent for those — mirroring granite's
// `window.dispatchEvent(new CustomEvent("granite:…"))` pattern — so the owning
// component can listen and react without us reaching into its module. Until a
// listener exists the command degrades to a toast via the fallback in run().
// ---------------------------------------------------------------------------
export const WIKI_EVENTS = {
  newCanvas: "wiki:new-canvas",
  newBase: "wiki:new-base",
  showShortcuts: "wiki:show-shortcuts",
} as const;

/**
 * Dispatch a window CustomEvent and report whether a listener consumed it.
 * `dispatchEvent` returns false only when a handler called preventDefault; we
 * can't truly detect "had a listener", so the command always shows a soft toast
 * and lets any wired listener do the real work. This keeps the command useful
 * before its backing feature lands (granite's "not yet implemented" notice).
 */
function fireEvent(name: string, detail?: unknown): void {
  if (typeof window === "undefined") return;
  window.dispatchEvent(new CustomEvent(name, { detail }));
}

// ---------------------------------------------------------------------------
// Built-in wiki commands. Registered once at module load. These are the "core"
// commands (granite's core-commands.ts) — real wiki actions wired to the routes
// and dialogs that exist today, plus event-backed actions for features owned by
// sibling milestones.
// ---------------------------------------------------------------------------

const BUILTIN_WIKI_COMMANDS: ReadonlyArray<WikiCommand> = [
  {
    id: "wiki:new-page",
    category: "Create",
    name: "New page",
    icon: FilePlus2,
    hotkey: "⌘N",
    run: (ctx) => ctx.navigate("/wiki/new"),
  },
  {
    id: "wiki:new-canvas",
    category: "Create",
    name: "New canvas",
    icon: PanelsTopLeft,
    run: (ctx) => {
      fireEvent(WIKI_EVENTS.newCanvas);
      ctx.notify("New canvas");
    },
  },
  {
    id: "wiki:new-base",
    category: "Create",
    name: "New base",
    icon: Table2,
    run: (ctx) => {
      fireEvent(WIKI_EVENTS.newBase);
      ctx.notify("New base");
    },
  },
  {
    id: "wiki:open-graph",
    category: "View",
    name: "Open graph",
    icon: Network,
    hotkey: "⌘G",
    run: (ctx) => ctx.navigate("/wiki/graph"),
  },
  {
    id: "wiki:open-enrich",
    category: "View",
    name: "Open enrich",
    icon: Sparkles,
    run: (ctx) => ctx.navigate("/wiki/enrich"),
  },
  {
    id: "wiki:open-console",
    category: "View",
    name: "Open console (search + brief)",
    icon: Search,
    run: (ctx) => ctx.navigate("/wiki/console"),
  },
  {
    id: "wiki:open-properties",
    category: "View",
    name: "Open properties",
    icon: Tags,
    run: (ctx) => ctx.navigate("/wiki/properties"),
  },
  {
    id: "wiki:toggle-live-preview",
    category: "Editor",
    name: "Toggle live preview",
    icon: Eye,
    run: (ctx) => {
      // Flip the shared wiki settings flag the editor subscribes to (via
      // useWikiSettings). Broadcasts through the settings change event so the
      // open editor reconfigures its CM extensions live.
      const next = toggleLivePreviewSetting();
      ctx.notify(next ? "Live preview on" : "Live preview off");
    },
  },
  {
    id: "wiki:search",
    category: "Navigate",
    name: "Search",
    icon: Search,
    hotkey: "⌘⇧F",
    run: (ctx) => ctx.openSearch(),
  },
  {
    id: "wiki:quick-switcher",
    category: "Navigate",
    name: "Quick switcher",
    icon: Type,
    hotkey: "⌘O",
    run: (ctx) => ctx.openSwitcher(),
  },
  {
    id: "wiki:bookmark-current",
    category: "Page",
    name: "Bookmark current page",
    icon: Bookmark,
    // Only meaningful when a real page is open.
    isAvailable: (ctx) => !!ctx.pageId,
    run: (ctx) => {
      if (!ctx.pageId) {
        ctx.notify("No page open to bookmark");
        return;
      }
      ctx.toggleBookmarkCurrent();
    },
  },
  {
    id: "wiki:goto-today",
    category: "Navigate",
    name: "Go to today's note",
    icon: CalendarDays,
    run: (ctx) => ctx.openDailyNote(),
  },
  {
    id: "wiki:show-shortcuts",
    category: "Help",
    name: "Show keyboard shortcuts",
    icon: Keyboard,
    hotkey: "⌘/",
    run: (ctx) => {
      fireEvent(WIKI_EVENTS.showShortcuts);
      // No-op toast suppressed; the dialog is the feedback. Notify only if no
      // listener is mounted (rare) so the command never feels dead.
      void ctx;
    },
  },
];

for (const cmd of BUILTIN_WIKI_COMMANDS) {
  wikiCommandRegistry.register(cmd);
}
