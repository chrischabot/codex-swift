// react-resizable-panels v4 — the API is named `Group/Panel/Separator`.
// shadcn-style re-exports so consumers can write the conventional names.
//
// AppShell currently uses a hand-rolled resize handle for the left sidebar
// (its layout needs to coexist with the macOS traffic-light spacer). This
// wrapper is here for future split panes inside the main column (eg. the
// thread + diff panel split).
//
// The handle below mirrors the app-shell sidebar resize affordance: a 1px
// divider line that brightens on hover/drag, with an optional centered grip.

import * as React from "react";
import { Group, Panel, Separator } from "react-resizable-panels";
import { GripVertical } from "lucide-react";
import { cn } from "@/lib/utils";

export const ResizablePanelGroup = Group;
export const ResizablePanel = Panel;

export const ResizableHandle = ({
  withHandle,
  className,
  ...props
}: React.ComponentProps<typeof Separator> & { withHandle?: boolean }) => (
  <Separator
    className={cn(
      // A 1px divider line that brightens on hover/drag, with a wider
      // invisible hit-area (::after) so it is easy to grab.
      "relative flex w-px items-center justify-center bg-[color:var(--border)] transition-colors",
      "after:absolute after:inset-y-0 after:left-1/2 after:w-1.5 after:-translate-x-1/2",
      "hover:bg-[color:var(--color-surface-active)] active:bg-[color:var(--ring)]",
      className,
    )}
    {...props}
  >
    {withHandle && (
      <div className="z-10 flex h-4 w-3 items-center justify-center rounded-sm border border-[color:var(--border)] bg-[color:var(--popover)]">
        <GripVertical className="size-2.5 text-[color:var(--color-text-tertiary)]" />
      </div>
    )}
  </Separator>
);
