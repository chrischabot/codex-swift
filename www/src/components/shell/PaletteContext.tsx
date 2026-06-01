import * as React from "react";
import { useHotkey } from "@tanstack/react-hotkeys";

// Tiny context so any component (e.g. the Sidebar "Search" item) can open the
// ⌘K palette. The keyboard binding itself goes through @tanstack/react-hotkeys
// so it shows up in the same registry as everything else.
const PaletteCtx = React.createContext<{ open: boolean; setOpen: (v: boolean) => void } | null>(null);

export function PaletteProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = React.useState(false);
  // The original `openCommandMenu` command defaults to TWO accelerators:
  // CmdOrCtrl+K and CmdOrCtrl+Shift+P. Bind both so either toggles the palette.
  useHotkey(
    "Mod+K",
    () => setOpen((v) => !v),
    { meta: { name: "Open command menu" } },
  );
  useHotkey(
    "Mod+Shift+P",
    () => setOpen((v) => !v),
    { meta: { name: "Open command menu" } },
  );
  return <PaletteCtx.Provider value={{ open, setOpen }}>{children}</PaletteCtx.Provider>;
}

export function usePalette() {
  const v = React.useContext(PaletteCtx);
  if (!v) throw new Error("usePalette outside PaletteProvider");
  return v;
}
