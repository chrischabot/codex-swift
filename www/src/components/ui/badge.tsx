import * as React from "react";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

// Mirrors output/webview/badge.js default:
// `bg-token-badge-background text-token-badge-foreground inline-flex items-center
//  rounded-sm px-2 py-1 text-sm leading-none`. No font-weight or gap in the original.
const badgeVariants = cva(
  "inline-flex items-center rounded-sm px-2 py-1 text-sm leading-none",
  {
    variants: {
      variant: {
        default: "bg-[color:var(--color-surface-hover)] text-[color:var(--color-text-secondary)]",
        // net-new variants kept from the reimplementation
        outline: "border border-[color:var(--border)] text-[color:var(--color-text-secondary)]",
        success: "bg-[color:var(--color-green-500)]/12 text-[color:var(--color-green-500)]",
        warning: "bg-[color:var(--color-orange-500)]/12 text-[color:var(--color-orange-500)]",
        danger: "bg-[color:var(--color-red-500)]/10 text-[color:var(--color-red-500)]",
      },
    },
    defaultVariants: { variant: "default" },
  },
);

export interface BadgeProps
  extends React.HTMLAttributes<HTMLSpanElement>,
    VariantProps<typeof badgeVariants> {}

function Badge({ className, variant, ...props }: BadgeProps) {
  return <span className={cn(badgeVariants({ variant }), className)} {...props} />;
}

export { Badge, badgeVariants };
