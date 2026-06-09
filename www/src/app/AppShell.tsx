import { Outlet, useLocation } from "react-router-dom";
import { isPopoutWindow } from "@/components/wiki/workspace/popout";
import { Sidebar } from "@/components/sidebar/Sidebar";
import { TopBar, TOP_BAR_HEIGHT } from "@/components/shell/TopBar";
import { CommandPalette } from "@/components/shell/CommandPalette";
import { PaletteProvider } from "@/components/shell/PaletteContext";
import { HotkeyManager } from "@/components/shell/HotkeyManager";
import { HotkeyOverlay } from "@/components/shell/HotkeyOverlay";
import { SidePanelProvider } from "@/components/shell/SidePanelContext";
import { Toaster } from "@/components/ui/sonner";
import * as React from "react";
import { cn } from "@/lib/utils";

export function AppShell() {
  const [sidebarOpen, setSidebarOpen] = React.useState(true);
  const location = useLocation();

  // Pop-out windows (?popout=1) render chrome-less: just the routed page, no
  // sidebar / top bar / palette. The wiki page itself drops its workspace +
  // rail in this mode (see WikiPage).
  if (isPopoutWindow()) {
    return (
      <div className="flex h-full w-full overflow-hidden bg-background">
        <main className="flex h-full min-w-0 flex-1 flex-col">
          <Outlet />
        </main>
        <Toaster />
      </div>
    );
  }

  return (
    <PaletteProvider>
    <SidePanelProvider>
    <div className="flex h-full w-full overflow-hidden bg-background">
      <ResizableSidebar visible={sidebarOpen} onClose={() => setSidebarOpen(false)} />
      <main className="relative flex h-full min-w-0 flex-1 flex-col">
        {/* Fixed-overlay toolbar (absolute within this relative main). */}
        <TopBar
          sidebarOpen={sidebarOpen}
          onToggleSidebar={() => setSidebarOpen((v) => !v)}
        />
        {/* Reserve the toolbar's height so page content (home/thread/settings)
            starts below the overlay instead of underneath it. */}
        <div
          key={location.pathname}
          className="flex min-h-0 flex-1 flex-col"
          style={{ paddingTop: TOP_BAR_HEIGHT }}
        >
          <Outlet />
        </div>
      </main>
      <CommandPalette />
      <HotkeyManager onToggleSidebar={() => setSidebarOpen((v) => !v)} />
      <HotkeyOverlay />
      <Toaster />
    </div>
    </SidePanelProvider>
    </PaletteProvider>
  );
}

const SIDEBAR_W_KEY = "dim-shadcn:sidebar-width";
// Match the original Codex shell clamp (app-shell.js `vn`): min 240, max 520,
// default 300.
const SIDEBAR_MIN = 240;
const SIDEBAR_MAX = 520;
const SIDEBAR_DEFAULT = 300;

function clampSidebarWidth(v: number): number {
  return Number.isFinite(v) ? Math.min(Math.max(v, SIDEBAR_MIN), SIDEBAR_MAX) : SIDEBAR_DEFAULT;
}

function ResizableSidebar({ visible, onClose }: { visible: boolean; onClose: () => void }) {
  const [width, setWidth] = React.useState<number>(() => {
    const v = Number(localStorage.getItem(SIDEBAR_W_KEY));
    return Number.isFinite(v) && v >= SIDEBAR_MIN && v <= SIDEBAR_MAX ? v : SIDEBAR_DEFAULT;
  });
  const [dragging, setDragging] = React.useState(false);
  const draggingRef = React.useRef(false);

  const startDrag = (e: React.MouseEvent) => {
    e.preventDefault();
    draggingRef.current = true;
    setDragging(true);
    const startX = e.clientX;
    const startW = width;
    const onMove = (ev: MouseEvent) => {
      if (!draggingRef.current) return;
      setWidth(clampSidebarWidth(startW + (ev.clientX - startX)));
    };
    const onUp = () => {
      draggingRef.current = false;
      setDragging(false);
      window.removeEventListener("mousemove", onMove);
      window.removeEventListener("mouseup", onUp);
      localStorage.setItem(SIDEBAR_W_KEY, String(width));
    };
    window.addEventListener("mousemove", onMove);
    window.addEventListener("mouseup", onUp);
  };

  // Apply a global col-resize cursor while dragging (original `cursor-col-resize`
  // class is toggled on the panel during drag in app-shell.js `Hn`).
  React.useEffect(() => {
    if (!dragging) return;
    const prev = document.body.style.cursor;
    document.body.style.cursor = "col-resize";
    return () => {
      document.body.style.cursor = prev;
    };
  }, [dragging]);

  React.useEffect(() => {
    localStorage.setItem(SIDEBAR_W_KEY, String(width));
  }, [width]);

  return (
    <aside
      className={cn(
        "relative flex h-full shrink-0 flex-col border-r border-[color:var(--sidebar-border)] bg-[color:var(--sidebar)] transition-[width,opacity] duration-200",
        dragging && "cursor-col-resize",
      )}
      style={{
        width: visible ? width : 0,
        opacity: visible ? 1 : 0,
        overflow: visible ? "visible" : "hidden",
      }}
    >
      <Sidebar onToggle={onClose} />
      {visible && (
        <div
          role="separator"
          aria-orientation="vertical"
          onMouseDown={startDrag}
          className="absolute right-0 top-0 z-10 h-full w-1 cursor-col-resize hover:bg-[color:var(--color-text-tertiary)]/30"
        />
      )}
    </aside>
  );
}
