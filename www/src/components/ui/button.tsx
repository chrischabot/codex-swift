import * as React from "react";
import { Slot } from "@radix-ui/react-slot";
import { cva, type VariantProps } from "class-variance-authority";
import { cn } from "@/lib/utils";

// Spinner mirrors output/webview/spinner.js (24x24 dual-path animate-spin svg).
function Spinner({ className, ...props }: React.SVGProps<SVGSVGElement>) {
  return (
    <svg
      width={24}
      height={24}
      viewBox="0 0 24 24"
      fill="none"
      xmlns="http://www.w3.org/2000/svg"
      className={cn("animate-spin", className)}
      {...props}
    >
      <path
        opacity={0.3}
        d="M18 12C18 8.68629 15.3137 6 12 6C8.68629 6 6 8.68629 6 12C6 15.3137 8.68629 18 12 18C15.3137 18 18 15.3137 18 12ZM20 12C20 16.4183 16.4183 20 12 20C7.58172 20 4 16.4183 4 12C4 7.58172 7.58172 4 12 4C16.4183 4 20 7.58172 20 12Z"
        fill="currentColor"
      />
      <path
        d="M12 4C16.4183 4 20 7.58172 20 12C20 16.4183 16.4183 20 12 20C7.58172 20 4 16.4183 4 12H6C6 15.3137 8.68629 18 12 18C15.3137 18 18 15.3137 18 12C18 8.68629 15.3137 6 12 6V4Z"
        fill="currentColor"
      />
    </svg>
  );
}

// Mirrors output/webview/button.js.
// Base: always a border (often transparent), flex items-center gap-1, opacity-40 when disabled.
const buttonVariants = cva(
  "flex items-center justify-center gap-1 whitespace-nowrap border select-none transition-colors focus:outline-none focus-visible:ring-2 focus-visible:ring-ring disabled:cursor-not-allowed disabled:opacity-40 [&_svg]:pointer-events-none [&_svg]:shrink-0",
  {
    variants: {
      variant: {
        // original `primary`: inverted high-contrast (bg-token-foreground text-token-dropdown-background)
        default:
          "border-transparent bg-primary text-primary-foreground enabled:hover:bg-primary/80 data-[state=open]:bg-primary/80",
        // original `danger`: red/10 tint, red text, transparent border
        destructive:
          "border-transparent bg-[color:var(--color-red-500)]/10 text-[color:var(--color-red-500)]",
        // original `outline`
        outline:
          "border-[color:var(--border)] text-foreground bg-transparent enabled:hover:bg-[color:var(--color-surface-hover)] data-[state=open]:bg-[color:var(--color-surface-hover)]",
        // original `outlineActive`
        outlineActive:
          "border-[color:var(--border)] text-foreground bg-[color:var(--foreground)]/10 enabled:hover:bg-[color:var(--foreground)]/15 data-[state=open]:bg-[color:var(--foreground)]/15",
        // original `secondary`
        secondary:
          "border-transparent text-foreground bg-[color:var(--foreground)]/5 enabled:hover:bg-[color:var(--foreground)]/10 data-[state=open]:bg-[color:var(--foreground)]/10",
        // original `ghost`
        ghost:
          "border-transparent text-[color:var(--color-text-tertiary)] enabled:hover:bg-[color:var(--color-surface-hover)] data-[state=open]:bg-[color:var(--color-surface-hover)]",
        // original `ghostActive`
        ghostActive:
          "border-transparent text-foreground enabled:hover:bg-[color:var(--color-surface-hover)] data-[state=open]:bg-[color:var(--color-surface-hover)]",
        // original `ghostMuted`
        ghostMuted:
          "border-transparent text-[color:var(--color-muted-foreground)] enabled:hover:bg-transparent data-[state=open]:bg-transparent hover:text-foreground",
        // net-new (kept)
        link: "border-transparent text-foreground underline-offset-4 hover:underline",
        subtle:
          "border-transparent bg-transparent text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
      },
      size: {
        // radius map mirrors button.js `i`; size map mirrors `c`
        default: "rounded-full px-2 py-0.5 text-sm leading-[18px]",
        sm: "rounded-lg px-1.5 py-0 text-sm leading-[18px]",
        xs: "rounded-lg px-2 py-0 text-[12px] leading-[18px]",
        lg: "rounded-full px-5 py-2 text-base leading-[18px]",
        medium: "rounded-lg px-4 py-1.5 text-base leading-[18px]",
        icon: "rounded-full flex items-center justify-center p-0.5 [&_svg]:size-4",
        iconSm: "rounded-lg flex h-4 w-4 items-center justify-center p-0.5 [&_svg]:size-3",
        iconXs: "rounded-lg flex h-4 w-4 items-center justify-center p-0.5 [&_svg]:size-3",
      },
    },
    defaultVariants: {
      variant: "default",
      size: "default",
    },
  },
);

export interface ButtonProps
  extends React.ButtonHTMLAttributes<HTMLButtonElement>,
    VariantProps<typeof buttonVariants> {
  asChild?: boolean;
  /** Renders a leading spinner and disables the button while truthy (mirrors button.js `loading`). */
  loading?: boolean;
  /** Square aspect-ratio icon button (mirrors button.js `uniform`). */
  uniform?: boolean;
}

const Button = React.forwardRef<HTMLButtonElement, ButtonProps>(
  (
    {
      className,
      variant,
      size,
      asChild = false,
      loading = false,
      uniform = false,
      disabled,
      children,
      type = "button",
      ...props
    },
    ref,
  ) => {
    const Comp = asChild ? Slot : "button";
    return (
      <Comp
        ref={ref}
        type={asChild ? undefined : type}
        disabled={disabled || loading}
        className={cn(
          buttonVariants({ variant, size }),
          uniform && "aspect-square items-center justify-center !px-0",
          className,
        )}
        {...props}
      >
        {loading && !asChild ? (
          <>
            <Spinner className="size-3" />
            {children}
          </>
        ) : (
          children
        )}
      </Comp>
    );
  },
);
Button.displayName = "Button";

export { Button, buttonVariants };
