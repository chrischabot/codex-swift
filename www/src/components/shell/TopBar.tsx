import * as React from "react";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { Kbd } from "@/components/ui/kbd";
import { PanelLeft, PanelLeftClose, PanelRight, ArrowLeft } from "lucide-react";
import { useLocation, useNavigate } from "react-router-dom";
import { cn } from "@/lib/utils";
import { ConnectionsPopover } from "./ConnectionsPopover";
import { LayoutPopover } from "./LayoutPopover";
import { useSidePanel } from "./SidePanelContext";

interface TopBarProps {
  sidebarOpen: boolean;
  onToggleSidebar: () => void;
}

// Fixed-overlay toolbar height. The TopBar is rendered as an absolute overlay
// (app-shell.js: `app-header-tint draggable ... fixed z-30 ... h-toolbar`), so
// the content area below must reserve this much top padding. Exported so the
// shell stays in sync with the bar's height.
export const TOP_BAR_HEIGHT = 46;

// macOS uses ⌘; everyone else gets Ctrl. The original renders the platform
// keybinding inside each tooltip (app-shell.js `cn` passes b(bt,'toggleSidebar'|
// 'navigateBack'|'navigateForward') as `shortcut`).
const MOD =
  typeof navigator !== "undefined" && /Mac|iPhone|iPad/.test(navigator.platform)
    ? "⌘"
    : "Ctrl";

// React Router v6 stamps a monotonically increasing `idx` onto history.state.
// We mirror it to derive canGoBack / canGoForward so Back/Forward disable at the
// edges like the original (app-shell.js `cn` local_16 = !canGoBack, local_21 =
// !canGoForward passed to the buttons as `disabled`).
function useHistoryPosition() {
  const location = useLocation();
  const [pos, setPos] = React.useState(() => ({
    idx: (window.history.state?.idx as number | undefined) ?? 0,
    len: window.history.length,
  }));
  React.useEffect(() => {
    setPos({
      idx: (window.history.state?.idx as number | undefined) ?? 0,
      len: window.history.length,
    });
  }, [location.key]);
  return {
    canGoBack: pos.idx > 0,
    canGoForward: pos.idx < pos.len - 1,
  };
}

export function TopBar({ sidebarOpen, onToggleSidebar }: TopBarProps) {
  const navigate = useNavigate();
  const sidePanel = useSidePanel();
  const { canGoBack, canGoForward } = useHistoryPosition();

  return (
    <header
      // Fixed overlay across the content pane (app-shell.js top bar:
      // `app-header-tint draggable ... fixed z-30 ... h-toolbar`). Positioned
      // absolute within the `relative` <main> so it spans the content column
      // without overlapping the sidebar. `app-header-tint` paints the blurred
      // titlebar tint; `draggable` makes the empty regions a window drag handle
      // (interactive clusters opt back out with `no-drag`).
      className="app-header-tint draggable absolute inset-x-0 top-0 z-30 flex h-[46px] shrink-0 items-center justify-between pe-3 ps-[max(var(--spacing-token-safe-header-left,0.5rem),0.5rem)]"
    >
      {/* Left cluster: sidebar toggle + nav back/forward */}
      <div className="flex items-center gap-1 no-drag">
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="iconSm"
              onClick={onToggleSidebar}
              aria-label={sidebarOpen ? "Hide sidebar" : "Show sidebar"}
              style={{ viewTransitionName: "sidebar-trigger" }}
            >
              {sidebarOpen ? <PanelLeftClose /> : <PanelLeft />}
            </Button>
          </TooltipTrigger>
          <TooltipContent>
            <span className="flex items-center gap-2">
              Toggle sidebar
              <Kbd>{MOD} B</Kbd>
            </span>
          </TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="iconSm"
              onClick={() => navigate(-1)}
              disabled={!canGoBack}
              aria-label="Back"
              className="text-[color:var(--color-text-tertiary)]"
            >
              <ArrowLeft />
            </Button>
          </TooltipTrigger>
          <TooltipContent>
            <span className="flex items-center gap-2">
              Back
              <Kbd>{MOD} [</Kbd>
            </span>
          </TooltipContent>
        </Tooltip>

        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="iconSm"
              onClick={() => navigate(1)}
              disabled={!canGoForward}
              aria-label="Forward"
              className="text-[color:var(--color-text-tertiary)]"
            >
              {/* Same arrow glyph mirrored, matching the original (app-shell.js
                  `cn`: xt with `-scale-x-100` for forward). */}
              <ArrowLeft className="-scale-x-100" />
            </Button>
          </TooltipTrigger>
          <TooltipContent>
            <span className="flex items-center gap-2">
              Forward
              <Kbd>{MOD} ]</Kbd>
            </span>
          </TooltipContent>
        </Tooltip>
      </div>

      {/* Center — left empty; pages render their own breadcrumbs */}

      {/* Right cluster — link/layout/panel icons */}
      <div className="flex items-center gap-1 no-drag">
        <Tooltip>
          <TooltipTrigger asChild>
            <span><ConnectionsPopover /></span>
          </TooltipTrigger>
          <TooltipContent>Connections</TooltipContent>
        </Tooltip>
        <Tooltip>
          <TooltipTrigger asChild>
            <span><LayoutPopover /></span>
          </TooltipTrigger>
          <TooltipContent>Switch layout</TooltipContent>
        </Tooltip>
        <Tooltip>
          <TooltipTrigger asChild>
            <Button
              variant="ghost"
              size="iconSm"
              onClick={sidePanel.toggle}
              aria-label="Toggle side panel"
              aria-pressed={sidePanel.open}
              className={cn(
                "text-[color:var(--color-text-tertiary)]",
                sidePanel.open && "bg-[color:var(--color-surface-active)] text-foreground",
              )}
            >
              <PanelRight />
            </Button>
          </TooltipTrigger>
          <TooltipContent>
            <span className="flex items-center gap-2">
              Toggle side panel
              <Kbd>{MOD} ⌥ B</Kbd>
            </span>
          </TooltipContent>
        </Tooltip>
      </div>
    </header>
  );
}
