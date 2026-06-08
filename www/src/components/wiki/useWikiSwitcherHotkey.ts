import * as React from "react";

interface WikiSwitcherHotkey {
  open: boolean;
  setOpen: React.Dispatch<React.SetStateAction<boolean>>;
}

/**
 * Registers a global Cmd/Ctrl-O hotkey that toggles a boolean (mirrors granite's
 * QuickSwitcher Cmd-O affordance). Returns the open state plus its setter so the
 * caller can mount <WikiQuickSwitcher open={open} onOpenChange={setOpen} />.
 *
 * The combo requires meta (macOS ⌘) or ctrl, so it fires even while the user is
 * typing in an input/textarea/contenteditable — per spec, the editable-focus
 * guard only applies to bare-key hotkeys, and this binding never triggers on a
 * bare "o". preventDefault keeps the browser's native "Open file…" dialog from
 * stealing the chord.
 *
 * `enabled` lets the caller scope the binding to the /wiki section (pass false
 * elsewhere so this never shadows other surfaces).
 */
export function useWikiSwitcherHotkey(enabled = true): WikiSwitcherHotkey {
  const [open, setOpen] = React.useState(false);

  React.useEffect(() => {
    if (!enabled) return;
    const onKeyDown = (e: KeyboardEvent) => {
      // Require exactly one of meta/ctrl and no alt/shift, so this is a clean
      // Cmd-O (macOS) / Ctrl-O (elsewhere) and won't clobber larger chords.
      const mod = e.metaKey || e.ctrlKey;
      if (!mod || e.altKey || e.shiftKey) return;
      if (e.key.toLowerCase() !== "o") return;
      e.preventDefault();
      setOpen((v) => !v);
    };
    window.addEventListener("keydown", onKeyDown);
    return () => window.removeEventListener("keydown", onKeyDown);
  }, [enabled]);

  return { open, setOpen };
}
