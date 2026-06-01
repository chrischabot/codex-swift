import * as React from "react";
import * as TooltipPrimitive from "@radix-ui/react-tooltip";
import { cn } from "@/lib/utils";

const TooltipProvider = TooltipPrimitive.Provider;
const Tooltip = TooltipPrimitive.Root;
const TooltipTrigger = TooltipPrimitive.Trigger;

const TooltipContent = React.forwardRef<
  React.ElementRef<typeof TooltipPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof TooltipPrimitive.Content>
>(({ className, sideOffset = 6, collisionPadding = 8, ...props }, ref) => (
  <TooltipPrimitive.Content
    ref={ref}
    sideOffset={sideOffset}
    collisionPadding={collisionPadding}
    className={cn(
      "z-50 w-fit max-w-[min(20rem,var(--radix-tooltip-content-available-width),calc(100vw-16px))] select-none whitespace-normal break-words rounded-lg border border-[color:var(--border)] bg-[var(--popover)] px-2 py-1 text-sm text-popover-foreground shadow-[var(--shadow-popover)]",
      "data-[state=delayed-open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=delayed-open]:fade-in-0",
      className,
    )}
    {...props}
  />
));
TooltipContent.displayName = TooltipPrimitive.Content.displayName;

/**
 * Keyboard-hint chip for use inside a tooltip (e.g. shortcut badges). Mirrors
 * the original tooltip Kbd sub-style: a soft current-colour-tinted pill.
 */
const TooltipKbd = ({ className, ...props }: React.HTMLAttributes<HTMLElement>) => (
  <kbd
    className={cn(
      "ml-1 inline-flex items-center justify-center rounded-md border-0 bg-current/10 px-1.5 py-0.5 font-sans text-xs leading-none text-current shadow-none",
      className,
    )}
    {...props}
  />
);
TooltipKbd.displayName = "TooltipKbd";

export { Tooltip, TooltipTrigger, TooltipContent, TooltipProvider, TooltipKbd };
