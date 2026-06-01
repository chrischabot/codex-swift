import * as React from "react";
import { cn } from "@/lib/utils";

export const Kbd: React.FC<React.HTMLAttributes<HTMLSpanElement>> = ({
  className,
  children,
  ...props
}) => (
  // The only confirmed original `kbd` styling (app-main css) is the monospace
  // font reset; the original hotkey UI renders bare key text, not bordered caps.
  <kbd
    className={cn(
      "inline-flex items-center justify-center font-mono text-[11px] leading-none text-[color:var(--color-text-quaternary)]",
      className,
    )}
    {...props}
  >
    {children}
  </kbd>
);
