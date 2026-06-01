import * as React from "react";
import * as SwitchPrimitives from "@radix-ui/react-switch";
import { cn } from "@/lib/utils";

// Mirrors output/webview/toggle.js:
//   track a = { default: "h-5 w-8", sm: "h-4 w-7" }
//   thumb o = { default: "h-4 w-4 ...translate-x-[14px]", sm: "h-3 w-3 ...translate-x-[14px]" }
//   checked: bg-token-charts-blue, unchecked: bg-token-foreground/10
//   thumb: rounded-full border border-[gray-0] bg-[gray-0] shadow-sm
//   disabled: opacity-60; transitions: duration-200 ease-out
const trackSizes = {
  default: "h-5 w-8",
  sm: "h-4 w-7",
} as const;

const thumbSizes = {
  default:
    "h-4 w-4 data-[state=unchecked]:translate-x-[2px] data-[state=checked]:translate-x-[14px]",
  sm: "h-3 w-3 data-[state=unchecked]:translate-x-[2px] data-[state=checked]:translate-x-[14px]",
} as const;

export interface SwitchProps
  extends React.ComponentPropsWithoutRef<typeof SwitchPrimitives.Root> {
  size?: "default" | "sm";
}

const Switch = React.forwardRef<
  React.ElementRef<typeof SwitchPrimitives.Root>,
  SwitchProps
>(({ className, size = "default", ...props }, ref) => (
  <SwitchPrimitives.Root
    className={cn(
      "relative inline-flex shrink-0 cursor-pointer items-center rounded-full transition-colors duration-200 ease-out focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-60 data-[state=checked]:bg-[color:var(--color-blue-400)] data-[state=unchecked]:bg-[color:var(--foreground)]/10",
      trackSizes[size],
      className,
    )}
    {...props}
    ref={ref}
  >
    <SwitchPrimitives.Thumb
      className={cn(
        "pointer-events-none block rounded-full border border-[color:var(--color-gray-0)] bg-[color:var(--color-gray-0)] shadow-sm transition-transform duration-200 ease-out",
        thumbSizes[size],
      )}
    />
  </SwitchPrimitives.Root>
));
Switch.displayName = SwitchPrimitives.Root.displayName;

export { Switch };
