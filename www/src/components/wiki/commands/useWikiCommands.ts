import * as React from "react";
import { useNavigate, useParams } from "react-router-dom";
import { toast } from "@/components/ui/sonner";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { useBookmarks } from "@/components/wiki/panels/useBookmarks";
import { dailyNoteTitle, dailyNoteBody, findDailyNoteId } from "./dailyNote";
import {
  wikiCommandRegistry,
  type WikiCommand,
  type WikiCommandContext,
} from "./commandRegistry";
import { parseHotkey, matchesHotkey, isEditableTarget } from "./hotkeyMatch";

// Chords owned by dedicated bindings elsewhere — the dispatcher must NOT also
// fire them or they'd double-toggle. Cmd-P (palette) lives in this hook; Cmd-O
// (quick switcher) lives in useWikiSwitcherHotkey.
const DISPATCH_RESERVED = new Set(["wiki:quick-switcher"]);

interface UseWikiCommandsArgs {
  /** Scope the Cmd-P hotkey to the wiki section. Pass false elsewhere so the
   *  palette never opens outside /wiki. Defaults to true. */
  enabled?: boolean;
  /** Open the wiki Quick Switcher (Cmd-O). Wired by WikiPage which owns that
   *  dialog's state. */
  onOpenSwitcher?: () => void;
  /** Open the in-section search surface. Defaults to navigating to the search
   *  route (`/wiki?q=`) so the command works even without a callback. */
  onOpenSearch?: () => void;
}

export interface UseWikiCommands {
  /** Palette open state. */
  open: boolean;
  setOpen: React.Dispatch<React.SetStateAction<boolean>>;
  /** Live snapshot of registered commands, already filtered by availability for
   *  the current context. Referentially recomputed only when the registry
   *  changes or the context inputs (pageId) change. */
  commands: ReadonlyArray<WikiCommand>;
  /** Run a command by id with the current context (used by the palette on
   *  select). */
  run: (id: string) => void;
}

/**
 * Wiki command-palette controller — the glue between the static
 * `wikiCommandRegistry` and the live React surface. Mirrors granite's split:
 * the registry holds command metadata; this hook owns (a) the Cmd-P open
 * hotkey, (b) the open state, and (c) the per-invocation `WikiCommandContext`
 * built from router + bookmarks so no command closes over stale navigate/pageId.
 *
 * Cmd-P (or Cmd-Shift-P, matching granite's two default bindings) toggles the
 * palette. The chord requires meta/ctrl, so it fires even while typing in an
 * input and never collides with a bare "p". We preventDefault to stop the
 * browser's native print dialog from stealing Cmd-P.
 */
export function useWikiCommands({
  enabled = true,
  onOpenSwitcher,
  onOpenSearch,
}: UseWikiCommandsArgs = {}): UseWikiCommands {
  const [open, setOpen] = React.useState(false);
  const navigate = useNavigate();
  const params = useParams();
  const { connector, status } = useRuntime();
  const { toggle: toggleBookmark } = useBookmarks();

  // Open today's daily note, creating it (date-titled, from a template) when it
  // doesn't exist yet. Fire-and-forget from the sync command context.
  // An in-flight ref prevents a same-tab double-fire from creating duplicates.
  const dailyBusyRef = React.useRef(false);
  const openDailyNote = React.useCallback(() => {
    if (status.kind !== "connected" || !connector.listWikiPages) {
      toast.error("Not connected");
      return;
    }
    if (dailyBusyRef.current) return;
    dailyBusyRef.current = true;
    void (async () => {
      try {
        const date = new Date();
        const title = dailyNoteTitle(date);
        // Find an existing daily note. Prefer searchWiki: the note's body carries
        // a `# <date>` heading that IS in the FTS index, so it ranks regardless
        // of corpus size — avoiding the silent daily-duplicate a fixed-limit
        // listWikiPages would cause past its cap. Fall back to listing.
        let existing: string | null = null;
        if (connector.searchWiki) {
          existing = findDailyNoteId(await connector.searchWiki(title, { limit: 25 }), date);
        }
        if (!existing && connector.listWikiPages) {
          existing = findDailyNoteId(await connector.listWikiPages({ limit: 1000 }), date);
        }
        if (existing) {
          navigate(`/wiki/${existing}`);
          return;
        }
        if (!connector.saveWikiPage) {
          toast.error("Can't create a daily note with this connection");
          return;
        }
        const res = await connector.saveWikiPage({ title, body: dailyNoteBody(date) });
        if (res) {
          toast.success("Created today's note");
          navigate(`/wiki/${res.id}`);
        } else {
          toast.error("Failed to create today's note");
        }
      } catch {
        toast.error("Failed to open today's note");
      } finally {
        dailyBusyRef.current = false;
      }
    })();
  }, [connector, status.kind, navigate]);

  // Normalize the route param: only a *real* page id should surface as
  // ctx.pageId. The wiki routes reuse `/wiki/:pageId` for the `new` create
  // surface; graph/enrich are their own routes so they never land here, but we
  // guard `new` explicitly.
  const rawPageId = params.pageId;
  const pageId = rawPageId && rawPageId !== "new" ? rawPageId : undefined;

  // Subscribe to the registry so the command list re-renders on
  // register/unregister. useSyncExternalStore gives us the stable list().
  const registered = React.useSyncExternalStore(
    React.useCallback((cb) => wikiCommandRegistry.subscribe(cb), []),
    () => wikiCommandRegistry.list(),
    () => wikiCommandRegistry.list(),
  );

  // Build the context fresh whenever its inputs change. Callbacks default to
  // sensible router-only behavior so the hook is usable without wiring.
  const buildContext = React.useCallback((): WikiCommandContext => {
    return {
      navigate,
      pageId,
      openSwitcher: () => onOpenSwitcher?.(),
      openSearch: () => {
        if (onOpenSearch) onOpenSearch();
        else navigate("/wiki?q=");
      },
      toggleBookmarkCurrent: () => {
        if (!pageId) return;
        const nowBookmarked = toggleBookmark(pageId);
        toast(nowBookmarked ? "Bookmarked page" : "Removed bookmark");
      },
      openDailyNote,
      notify: (message: string) => toast(message),
    };
  }, [navigate, pageId, onOpenSwitcher, onOpenSearch, toggleBookmark, openDailyNote]);

  // Availability filter needs a context; recompute when the registry list or
  // the context-shaping inputs change.
  const commands = React.useMemo(() => {
    const ctx = buildContext();
    return registered.filter((c) => !c.isAvailable || c.isAvailable(ctx));
  }, [registered, buildContext]);

  const run = React.useCallback(
    (id: string) => {
      wikiCommandRegistry.run(id, buildContext());
    },
    [buildContext],
  );

  // Cmd-P / Cmd-Shift-P toggles the palette, scoped by `enabled`.
  React.useEffect(() => {
    if (!enabled) return;
    const onKeyDown = (e: KeyboardEvent) => {
      const mod = e.metaKey || e.ctrlKey;
      if (!mod || e.altKey) return; // allow shift (Cmd-Shift-P)
      if (e.key.toLowerCase() !== "p") return;
      e.preventDefault();
      setOpen((v) => !v);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled]);

  // M29 hotkey dispatcher: bind every registered command's accelerator hint so
  // the SAME string both displays in the palette and fires the action. Skips
  // reserved chords (owned elsewhere) and unavailable commands; a bare-key chord
  // (no modifier) is suppressed while a text field has focus.
  React.useEffect(() => {
    if (!enabled) return;
    // Precompute (command, parsed-chord) pairs once per registry/enabled change.
    const bound = registered
      .filter((c) => c.hotkey && !DISPATCH_RESERVED.has(c.id))
      .map((c) => ({ c, hk: parseHotkey(c.hotkey!) }))
      .filter((b): b is { c: WikiCommand; hk: NonNullable<typeof b.hk> } => b.hk !== null);
    if (bound.length === 0) return;
    const onKeyDown = (e: KeyboardEvent) => {
      for (const { c, hk } of bound) {
        if (!matchesHotkey(e, hk)) continue;
        const bareKey = !hk.mod && !hk.ctrl && !hk.alt;
        if (bareKey && isEditableTarget(e.target)) return;
        const ctx = buildContext();
        if (c.isAvailable && !c.isAvailable(ctx)) return;
        e.preventDefault();
        c.run(ctx);
        return;
      }
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled, registered, buildContext]);

  return { open, setOpen, commands, run };
}
