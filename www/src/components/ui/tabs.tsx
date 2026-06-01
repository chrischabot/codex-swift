import * as React from "react";
import * as TabsPrimitive from "@radix-ui/react-tabs";
import { X } from "lucide-react";
import { cn } from "@/lib/utils";

type TabsVariant = "segmented" | "toolbar" | "underline";

const TabsVariantContext = React.createContext<TabsVariant>("segmented");

const Tabs = TabsPrimitive.Root;

const TabsList = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.List>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.List> & {
    variant?: TabsVariant;
  }
>(({ className, variant = "segmented", ...props }, ref) => {
  // Container styling mirrors tabs.js:59-61.
  //  - segmented: a bordered, rounded pill rail (token-surface-secondary)
  //  - toolbar:   a tight gap-0.5 row of buttons
  //  - underline: a bottom-bordered row of text triggers
  const listClass =
    variant === "toolbar"
      ? "flex min-w-0 items-center gap-0.5"
      : variant === "underline"
        ? "flex min-w-0 items-start gap-8 border-b border-[color:var(--border)]"
        : "flex items-center rounded-lg border border-[color:var(--border)] bg-[color:var(--secondary)]";

  return (
    <TabsVariantContext.Provider value={variant}>
      <TabsPrimitive.List
        ref={ref}
        className={cn(
          listClass,
          "text-[color:var(--color-text-secondary)]",
          className,
        )}
        {...props}
      />
    </TabsVariantContext.Provider>
  );
});
TabsList.displayName = TabsPrimitive.List.displayName;

const TabsTrigger = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.Trigger>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Trigger> & {
    /** Optional leading icon (icon-xs in the original). */
    icon?: React.ReactNode;
    /**
     * When provided, renders a trailing close affordance inside the trigger.
     * The handler receives the click event; it stops propagation so closing a
     * tab does not also activate it. Optional — omitting it preserves the plain
     * Radix trigger markup.
     */
    onClose?: (e: React.MouseEvent<HTMLSpanElement>) => void;
    /** Accessible label for the close affordance (default "Close tab"). */
    closeLabel?: string;
  }
>(({ className, icon, onClose, closeLabel = "Close tab", children, ...props }, ref) => {
  const variant = React.useContext(TabsVariantContext);

  // Per-variant trigger styling (tabs.js:71-90).
  const base =
    "group relative flex min-w-0 cursor-pointer items-center text-sm font-medium outline-none transition-colors focus-visible:outline-none disabled:pointer-events-none disabled:opacity-50 data-[state=active]:text-foreground";

  const variantClass =
    variant === "toolbar"
      ? "shrink-0 gap-1.5 rounded-md px-2 py-1 hover:bg-[color:var(--background)] data-[state=active]:bg-[color:var(--background)]"
      : variant === "underline"
        ? "shrink-0 gap-1.5 pb-2 hover:text-foreground"
        : // segmented
          "flex-1 justify-center gap-1.5 rounded-none px-4 py-1.5 first:rounded-l-md last:rounded-r-md hover:bg-[color:var(--foreground)]/5 data-[state=active]:bg-[color:var(--foreground)]/[0.1]";

  return (
    <TabsPrimitive.Trigger
      ref={ref}
      className={cn(base, onClose != null && "pe-1", className)}
      {...props}
    >
      {icon != null && (
        <span
          aria-hidden="true"
          className="flex shrink-0 items-center justify-center [&_svg]:size-3.5"
        >
          {icon}
        </span>
      )}
      {children}
      {onClose != null && (
        // Close affordance. A nested <button> inside the Radix trigger button is
        // invalid, so render an interactive span with role=button and stop the
        // click from bubbling to the trigger (which would activate the tab).
        <span
          role="button"
          tabIndex={-1}
          aria-label={closeLabel}
          className="ms-1 flex size-4 shrink-0 items-center justify-center rounded text-[color:var(--color-text-quaternary)] opacity-70 transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground hover:opacity-100 [&_svg]:size-3"
          onPointerDown={(e) => {
            // Prevent the trigger from receiving focus/activation on press.
            e.preventDefault();
            e.stopPropagation();
          }}
          onClick={(e) => {
            e.preventDefault();
            e.stopPropagation();
            onClose(e);
          }}
        >
          <X aria-hidden="true" />
        </span>
      )}
      {/* Underline indicator bar (tabs.js:100). */}
      {variant === "underline" && (
        <span className="absolute inset-x-0 bottom-[-1px] hidden h-px bg-[color:var(--foreground)] group-data-[state=active]:block" />
      )}
    </TabsPrimitive.Trigger>
  );
});
TabsTrigger.displayName = TabsPrimitive.Trigger.displayName;

// Optional thin vertical divider for between tabs (used in toolbar/closable tab
// strips). Additive — not part of the Radix composition, just a decorative
// separator a caller may interleave between TabsTriggers.
const TabsSeparator = React.forwardRef<
  HTMLSpanElement,
  React.HTMLAttributes<HTMLSpanElement>
>(({ className, ...props }, ref) => (
  <span
    ref={ref}
    role="separator"
    aria-orientation="vertical"
    className={cn("mx-0.5 h-4 w-px shrink-0 self-center bg-[color:var(--color-divider)]", className)}
    {...props}
  />
));
TabsSeparator.displayName = "TabsSeparator";

const TabsContent = React.forwardRef<
  React.ElementRef<typeof TabsPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof TabsPrimitive.Content>
>(({ className, ...props }, ref) => (
  <TabsPrimitive.Content
    ref={ref}
    className={cn("mt-2 focus-visible:outline-none", className)}
    {...props}
  />
));
TabsContent.displayName = TabsPrimitive.Content.displayName;

export { Tabs, TabsList, TabsTrigger, TabsContent, TabsSeparator };
