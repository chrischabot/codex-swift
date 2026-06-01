import * as React from "react";

// Side-panel state lives at the shell level so the top bar's PanelRight icon
// and the thread page's PanelRight icon stay in sync.
//
// The original Codex shell only tracks side-panel open/closed (plus an animated
// panel width in app-shell.js). This is a single global boolean, defaulting
// open=true; it is NOT keyed per-route and does not persist or animate width —
// a deliberate simplification of the original per-thread panel state.
//
// `layout` / LayoutMode is NET-NEW: the original has no Stack/Side-by-side/Wide
// layout-mode enum. It exists only to drive the (also net-new) LayoutPopover.

type LayoutMode = "stack" | "side-by-side" | "wide";

interface SidePanelCtxValue {
  open: boolean;
  setOpen: (v: boolean) => void;
  toggle: () => void;
  layout: LayoutMode;
  setLayout: (m: LayoutMode) => void;
}

const SidePanelCtx = React.createContext<SidePanelCtxValue | null>(null);

export function SidePanelProvider({ children }: { children: React.ReactNode }) {
  const [open, setOpen] = React.useState(true);
  const [layout, setLayout] = React.useState<LayoutMode>("side-by-side");
  return (
    <SidePanelCtx.Provider
      value={{ open, setOpen, toggle: () => setOpen((v) => !v), layout, setLayout }}
    >
      {children}
    </SidePanelCtx.Provider>
  );
}

export function useSidePanel() {
  const v = React.useContext(SidePanelCtx);
  if (!v) throw new Error("useSidePanel outside provider");
  return v;
}

export type { LayoutMode };
