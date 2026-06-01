import * as React from "react";
import { useNavigate, useParams } from "react-router-dom";
import { useHotkeys, type UseHotkeyDefinition } from "@tanstack/react-hotkeys";
import { parseHotkey } from "@tanstack/hotkeys";
import { useAppData, dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";
import { openHotkeyOverlay } from "./HotkeyOverlay";
import { usePalette } from "./PaletteContext";

interface Props {
  onToggleSidebar: () => void;
}

// Single source of truth for the bindings. Each entry carries:
//   keys: the @tanstack/react-hotkeys string (e.g. "Mod+N", "Shift+Mod+A")
//   display: the human label shown in the HotkeyOverlay
//   label: what action it performs
// `Mod` resolves to Cmd on macOS, Ctrl on Windows/Linux automatically.
// `group` mirrors the original command registry's `commandMenuGroupKey`
// taxonomy (thread / navigation / panels / configure) so the overlay can
// render category separators like the source Settings table.
export type HotkeyGroup = "thread" | "navigation" | "panels" | "configure";

export interface HotkeySpec {
  id: string;
  keys: string;
  display: string;
  label: string;
  group: HotkeyGroup;
}

// Display/keys/labels follow the canonical bindings in the original
// webview/electron-menu-shortcuts.js command registry:
//   newThread          CmdOrCtrl+N            (thread)
//   openCommandMenu    CmdOrCtrl+K            (also Shift+P)
//   searchChats        CmdOrCtrl+G            (navigation)
//   searchFiles        CmdOrCtrl+P            (navigation)
//   renameThread       CmdOrCtrl+Alt+R        (thread)
//   toggleThreadPin    CmdOrCtrl+Alt+P        (thread)
//   archiveThread      CmdOrCtrl+Shift+A      (thread)
//   toggleSidebar      CmdOrCtrl+B            (panels)
//   settings           CmdOrCtrl+,            (configure)
//   showKeyboardShortcuts CmdOrCtrl+Shift+/   (configure)
//   thread1..9         CmdOrCtrl+1..9         (navigation)
export const HOTKEYS: HotkeySpec[] = [
  { id: "new-chat",     keys: "Mod+N",         display: "⌘N",        label: "New chat",              group: "thread" },
  { id: "search",       keys: "Mod+K",         display: "⌘K",        label: "Open command menu",     group: "navigation" },
  { id: "search-chats", keys: "Mod+G",         display: "⌘G",        label: "Search chats",          group: "navigation" },
  // ⌘1 … ⌘9 generated below — listed once here for the overlay.
  { id: "jump-pinned",  keys: "Mod+1",         display: "⌘1 … ⌘9",   label: "Jump to pinned / project", group: "navigation" },
  { id: "rename",       keys: "Mod+Alt+R",     display: "⌥⌘R",       label: "Rename chat",           group: "thread" },
  { id: "pin",          keys: "Mod+Alt+P",     display: "⌥⌘P",       label: "Pin/unpin current",     group: "thread" },
  { id: "archive",      keys: "Mod+Shift+A",   display: "⌘⇧A",       label: "Archive current",       group: "thread" },
  { id: "submit",       keys: "Enter",         display: "Enter",     label: "Submit composer",       group: "thread" },
  { id: "newline",      keys: "Shift+Enter",   display: "Shift Enter", label: "Newline in composer", group: "thread" },
  { id: "toggle-side",  keys: "Mod+B",         display: "⌘B",        label: "Toggle sidebar",        group: "panels" },
  { id: "settings",     keys: "Mod+,",         display: "⌘,",        label: "Settings",              group: "configure" },
  { id: "help",         keys: "Mod+Shift+/",   display: "⌘⇧/",       label: "Keyboard shortcuts",    group: "configure" },
];

export function HotkeyManager({ onToggleSidebar }: Props) {
  const navigate = useNavigate();
  const params = useParams();
  const { threads, projects } = useAppData();
  const { setOpen: setPaletteOpen } = usePalette();

  // Concatenate pinned threads then projects so ⌘1..⌘N matches sidebar order.
  const hotkeyTargets = React.useMemo(() => {
    const pinned = threads.filter((t) => t.pinned && t.status === "active");
    const slots: Array<{ kind: "thread" | "project"; id: string }> = [];
    for (const t of pinned) slots.push({ kind: "thread", id: t.id });
    for (const p of projects) slots.push({ kind: "project", id: p.id });
    return slots;
  }, [threads, projects]);

  const currentThreadId = params.threadId as string | undefined;
  const currentThread = currentThreadId
    ? threads.find((t) => t.id === currentThreadId)
    : undefined;

  // Build the registration list. We list all named bindings + nine numeric
  // jump shortcuts. The library handles `ignoreInputs` automatically — single
  // keys and Shift+letter combos are suppressed while typing in an input.
  // Mod-prefixed combos (our globals) always fire.
  const definitions = React.useMemo<UseHotkeyDefinition[]>(
    () => [
      {
        hotkey: "Mod+N",
        callback: () => navigate(`/home/${projects[0]?.id ?? "p-diminuendo"}`),
        options: { meta: { name: "New chat" } },
      },
      {
        // toggleSidebar — CmdOrCtrl+B in the original registry.
        hotkey: "Mod+B",
        callback: onToggleSidebar,
        options: { meta: { name: "Toggle sidebar" } },
      },
      {
        // searchChats — CmdOrCtrl+G. Opens the same command menu palette.
        hotkey: "Mod+G",
        callback: () => setPaletteOpen(true),
        options: { meta: { name: "Search chats" } },
      },
      {
        // settings — CmdOrCtrl+, (punctuation needs the parse escape hatch).
        hotkey: parseHotkey("Mod+,"),
        callback: () => navigate("/settings"),
        options: { meta: { name: "Settings" } },
      },
      {
        // showKeyboardShortcuts — CmdOrCtrl+Shift+/. Punctuation isn't in the
        // typed string union, so use the ParsedHotkey escape hatch.
        hotkey: parseHotkey("Mod+Shift+/"),
        callback: () => openHotkeyOverlay(),
        options: { meta: { name: "Keyboard shortcuts" } },
      },
      {
        // toggleThreadPin — CmdOrCtrl+Alt+P in the original registry.
        hotkey: "Mod+Alt+P",
        callback: () => {
          if (!currentThread) return;
          dispatch.setThreadPinned(currentThread.id, !currentThread.pinned);
          toast(currentThread.pinned ? "Unpinned chat" : "Pinned chat");
        },
        options: { meta: { name: "Pin/unpin current thread" }, enabled: !!currentThread },
      },
      {
        // renameThread — CmdOrCtrl+Alt+R in the original registry. The web
        // port has no inline rename control, so prompt for the new title.
        hotkey: "Mod+Alt+R",
        callback: () => {
          if (!currentThread) return;
          const next = window.prompt("Rename chat", currentThread.title);
          if (next != null && next.trim() && next.trim() !== currentThread.title) {
            dispatch.renameThread(currentThread.id, next.trim());
          }
        },
        options: { meta: { name: "Rename chat" }, enabled: !!currentThread },
      },
      {
        hotkey: "Mod+Shift+A",
        callback: () => {
          if (!currentThreadId) return;
          dispatch.setThreadArchived(currentThreadId, true);
          toast("Archived chat", {
            action: {
              label: "Undo",
              onClick: () => dispatch.setThreadArchived(currentThreadId, false),
            },
          });
        },
        options: { meta: { name: "Archive current thread" }, enabled: !!currentThreadId },
      },
      // ⌘1 … ⌘9 — jump to pinned / project at slot N. We use the parsed-
      // hotkey escape hatch because the typed string form requires literal
      // template-narrowed values and we want a dynamic loop.
      ...Array.from({ length: 9 }, (_, i): UseHotkeyDefinition => ({
        hotkey: parseHotkey(`Mod+${i + 1}`),
        callback: () => {
          const target = hotkeyTargets[i];
          if (!target) return;
          if (target.kind === "thread") navigate(`/thread/${target.id}`);
          else navigate(`/home/${target.id}`);
        },
        options: { meta: { name: `Jump to slot ${i + 1}` } },
      })),
    ],
    [navigate, projects, onToggleSidebar, currentThread, currentThreadId, hotkeyTargets, setPaletteOpen],
  );

  useHotkeys(definitions);
  return null;
}
