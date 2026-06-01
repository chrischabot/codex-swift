import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { Button } from "@/components/ui/button";
import { LayoutGrid, Columns, Rows, Maximize2 } from "lucide-react";
import { useSidePanel, type LayoutMode } from "./SidePanelContext";
import { cn } from "@/lib/utils";

// NET-NEW (no original counterpart): the original Codex shell exposes only a
// single "Toggle side panel" button (thread-app-shell-chrome.js
// `thread.sidePanel.toggle`), NOT a multi-mode layout switcher. This
// Stack / Side-by-side / Wide selector is an intentional addition for this app
// and is not a port of any original module. Stack = composer-centered (no side
// panel), side-by-side = thread on the left with the diff/browser panel docked
// right, wide = full-width composer for plain-text first turns.
const options: { id: LayoutMode; label: string; icon: React.ReactNode; description: string }[] = [
  { id: "stack",         label: "Stack",          icon: <Rows className="size-4" />,     description: "Composer centered" },
  { id: "side-by-side",  label: "Side-by-side",   icon: <Columns className="size-4" />,  description: "Thread + side panel" },
  { id: "wide",          label: "Wide",           icon: <Maximize2 className="size-4" />, description: "Full-width composer" },
];

export function LayoutPopover() {
  const { layout, setLayout, open: panelOpen, setOpen: setPanelOpen } = useSidePanel();
  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="ghost" size="iconSm" aria-label="Switch layout" className="text-[color:var(--color-text-tertiary)]">
          <LayoutGrid />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="end" sideOffset={8} className="w-[260px] p-1.5">
        <div className="px-1.5 pb-1.5 pt-1 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
          Switch layout
        </div>
        <div className="space-y-px">
          {options.map((o) => (
            <button
              key={o.id}
              onClick={() => {
                setLayout(o.id);
                setPanelOpen(o.id !== "wide" && o.id !== "stack" ? true : panelOpen);
              }}
              className={cn(
                "flex w-full items-center gap-2.5 rounded-md px-2 py-1.5 text-left",
                layout === o.id ? "bg-[color:var(--color-surface-active)]" : "hover:bg-[color:var(--color-surface-hover)]",
              )}
            >
              <span className="text-[color:var(--color-text-secondary)]">{o.icon}</span>
              <div className="flex-1">
                <div className="text-[13px] font-medium">{o.label}</div>
                <div className="text-[11.5px] text-[color:var(--color-text-tertiary)]">{o.description}</div>
              </div>
            </button>
          ))}
        </div>
      </PopoverContent>
    </Popover>
  );
}
