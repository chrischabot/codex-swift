import * as React from "react";
import * as DropdownMenuPrimitive from "@radix-ui/react-dropdown-menu";
import { Check, ChevronRight, Circle, Search } from "lucide-react";
import { cn } from "@/lib/utils";

const DropdownMenu = DropdownMenuPrimitive.Root;
const DropdownMenuTrigger = DropdownMenuPrimitive.Trigger;
const DropdownMenuGroup = DropdownMenuPrimitive.Group;
const DropdownMenuPortal = DropdownMenuPrimitive.Portal;
const DropdownMenuSub = DropdownMenuPrimitive.Sub;
const DropdownMenuRadioGroup = DropdownMenuPrimitive.RadioGroup;

const DropdownMenuSubTrigger = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.SubTrigger>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.SubTrigger> & {
    inset?: boolean;
  }
>(({ className, inset, children, ...props }, ref) => (
  <DropdownMenuPrimitive.SubTrigger
    ref={ref}
    className={cn(
      "group flex cursor-pointer select-none items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-[color:var(--foreground)] outline-none hover:bg-[color:var(--color-surface-hover)] focus:bg-[color:var(--color-surface-hover)] data-[state=open]:bg-[color:var(--color-surface-hover)] [&_svg]:opacity-75 group-hover:[&_svg]:opacity-100 group-focus:[&_svg]:opacity-100",
      inset && "pl-8",
      className,
    )}
    {...props}
  >
    {children}
    <ChevronRight className="ml-auto size-4" />
  </DropdownMenuPrimitive.SubTrigger>
));
DropdownMenuSubTrigger.displayName = DropdownMenuPrimitive.SubTrigger.displayName;

const DropdownMenuSubContent = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.SubContent>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.SubContent>
>(({ className, ...props }, ref) => (
  <DropdownMenuPrimitive.SubContent
    ref={ref}
    className={cn(
      "no-drag z-50 m-px flex min-w-[10rem] select-none flex-col overflow-y-auto rounded-xl bg-[var(--popover)]/90 px-1 py-1 text-popover-foreground shadow-[var(--shadow-popover)] ring-[0.5px] ring-[color:var(--border)] backdrop-blur-sm",
      className,
    )}
    {...props}
  />
));
DropdownMenuSubContent.displayName = DropdownMenuPrimitive.SubContent.displayName;

const DropdownMenuContent = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.Content>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.Content>
>(({ className, sideOffset = 6, ...props }, ref) => (
  <DropdownMenuPrimitive.Portal>
    <DropdownMenuPrimitive.Content
      ref={ref}
      sideOffset={sideOffset}
      className={cn(
        "no-drag z-50 m-px flex min-w-[12rem] origin-[var(--radix-dropdown-menu-content-transform-origin)] select-none flex-col overflow-y-auto rounded-xl bg-[var(--popover)]/90 px-1 py-1 text-popover-foreground shadow-[var(--shadow-popover)] ring-[0.5px] ring-[color:var(--border)] backdrop-blur-sm",
        "data-[state=open]:animate-in data-[state=closed]:animate-out data-[state=closed]:fade-out-0 data-[state=open]:fade-in-0 data-[state=closed]:zoom-out-95 data-[state=open]:zoom-in-95",
        className,
      )}
      {...props}
    />
  </DropdownMenuPrimitive.Portal>
));
DropdownMenuContent.displayName = DropdownMenuPrimitive.Content.displayName;

const DropdownMenuItem = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.Item>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.Item> & {
    inset?: boolean;
  }
>(({ className, inset, ...props }, ref) => (
  <DropdownMenuPrimitive.Item
    ref={ref}
    className={cn(
      "group relative flex w-full cursor-pointer select-none items-center gap-1.5 rounded-lg px-2 py-1 text-sm text-[color:var(--foreground)] outline-none transition-colors hover:bg-[color:var(--color-surface-hover)] focus:bg-[color:var(--color-surface-hover)] data-[disabled]:pointer-events-none data-[disabled]:cursor-default data-[disabled]:opacity-50 [&_svg]:size-4 [&_svg]:shrink-0 [&_svg]:opacity-75 group-hover:[&_svg]:opacity-100 group-focus:[&_svg]:opacity-100",
      inset && "pl-8",
      className,
    )}
    {...props}
  />
));
DropdownMenuItem.displayName = DropdownMenuPrimitive.Item.displayName;

const DropdownMenuCheckboxItem = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.CheckboxItem>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.CheckboxItem>
>(({ className, children, checked, ...props }, ref) => (
  <DropdownMenuPrimitive.CheckboxItem
    ref={ref}
    className={cn(
      "relative flex cursor-default select-none items-center rounded-sm py-1.5 pl-8 pr-2 text-sm outline-none focus:bg-[color:var(--color-surface-hover)]",
      className,
    )}
    checked={checked}
    {...props}
  >
    <span className="absolute left-2 flex h-3.5 w-3.5 items-center justify-center">
      <DropdownMenuPrimitive.ItemIndicator>
        <Check className="h-4 w-4" />
      </DropdownMenuPrimitive.ItemIndicator>
    </span>
    {children}
  </DropdownMenuPrimitive.CheckboxItem>
));
DropdownMenuCheckboxItem.displayName = DropdownMenuPrimitive.CheckboxItem.displayName;

const DropdownMenuRadioItem = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.RadioItem>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.RadioItem>
>(({ className, children, ...props }, ref) => (
  <DropdownMenuPrimitive.RadioItem
    ref={ref}
    className={cn(
      "relative flex cursor-default select-none items-center rounded-sm py-1.5 pl-8 pr-2 text-sm outline-none focus:bg-[color:var(--color-surface-hover)]",
      className,
    )}
    {...props}
  >
    <span className="absolute left-2 flex h-3.5 w-3.5 items-center justify-center">
      <DropdownMenuPrimitive.ItemIndicator>
        <Circle className="h-2 w-2 fill-current" />
      </DropdownMenuPrimitive.ItemIndicator>
    </span>
    {children}
  </DropdownMenuPrimitive.RadioItem>
));
DropdownMenuRadioItem.displayName = DropdownMenuPrimitive.RadioItem.displayName;

const DropdownMenuLabel = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.Label>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.Label> & {
    inset?: boolean;
  }
>(({ className, inset, ...props }, ref) => (
  <DropdownMenuPrimitive.Label
    ref={ref}
    className={cn(
      "px-2 py-1 text-sm text-[color:var(--color-text-secondary)]",
      inset && "pl-8",
      className,
    )}
    {...props}
  />
));
DropdownMenuLabel.displayName = DropdownMenuPrimitive.Label.displayName;

const DropdownMenuSeparator = React.forwardRef<
  React.ElementRef<typeof DropdownMenuPrimitive.Separator>,
  React.ComponentPropsWithoutRef<typeof DropdownMenuPrimitive.Separator>
>(({ className, ...props }, ref) => (
  <DropdownMenuPrimitive.Separator
    ref={ref}
    className={cn("w-full px-2 py-1", className)}
    {...props}
  >
    <div className="h-px w-full bg-[color:var(--color-divider)]" />
  </DropdownMenuPrimitive.Separator>
));
DropdownMenuSeparator.displayName = DropdownMenuPrimitive.Separator.displayName;

const DropdownMenuShortcut = ({
  className,
  ...props
}: React.HTMLAttributes<HTMLSpanElement>) => {
  return (
    <span
      className={cn(
        "ml-auto text-[11px] tracking-widest text-[color:var(--color-text-quaternary)]",
        className,
      )}
      {...props}
    />
  );
};
DropdownMenuShortcut.displayName = "DropdownMenuShortcut";

// ----------------------------------------------------------------------------
// Additive (non-Radix) building blocks used by filterable menus (connections,
// model picker, etc.). They are plain DOM rows that live inside a
// DropdownMenuContent alongside the Radix items.
// ----------------------------------------------------------------------------

// A sticky search-input row for filtering a long menu. Rendered as a non-item
// row so typing into it does not steal Radix's roving focus / typeahead.
// onKeyDown is left to the caller so it can implement arrow-to-list behavior;
// we stop pointer/keydown propagation only for the wrapper so the menu does not
// close or re-focus while interacting with the field.
const DropdownMenuSearch = React.forwardRef<
  HTMLInputElement,
  Omit<React.InputHTMLAttributes<HTMLInputElement>, "className"> & {
    className?: string;
    /** Wrapper className (the row); `inputClassName` styles the field. */
    inputClassName?: string;
    /** Optional leading icon; defaults to a magnifier (lucide Search). */
    icon?: React.ReactNode;
  }
>(({ className, inputClassName, icon, placeholder = "Search…", ...props }, ref) => (
  <div
    className={cn(
      "sticky top-0 z-10 -mx-1 -mt-1 mb-1 flex items-center gap-1.5 border-b border-[color:var(--color-divider)] bg-[var(--popover)]/90 px-2.5 py-1.5 backdrop-blur-sm",
      className,
    )}
    // Keep keystrokes inside the input (don't trigger Radix typeahead) but let
    // Escape / arrow keys bubble for the caller to handle.
    onKeyDown={(e) => {
      if (e.key !== "Escape" && e.key !== "ArrowDown" && e.key !== "ArrowUp") {
        e.stopPropagation();
      }
    }}
  >
    <span aria-hidden className="flex shrink-0 items-center text-[color:var(--color-text-quaternary)] [&_svg]:size-3.5">
      {icon ?? <Search />}
    </span>
    <input
      ref={ref}
      type="text"
      placeholder={placeholder}
      className={cn(
        "min-w-0 flex-1 bg-transparent text-sm text-[color:var(--foreground)] outline-none placeholder:text-[color:var(--color-text-quaternary)]",
        inputClassName,
      )}
      {...props}
    />
  </div>
));
DropdownMenuSearch.displayName = "DropdownMenuSearch";

// A small uppercase section label (distinct from DropdownMenuLabel, which is a
// Radix.Label and renders normal-case secondary text). Used to head grouped
// sections inside a menu.
const DropdownMenuSectionLabel = React.forwardRef<
  HTMLDivElement,
  React.HTMLAttributes<HTMLDivElement>
>(({ className, ...props }, ref) => (
  <div
    ref={ref}
    className={cn(
      "px-2 pb-1 pt-2 text-[10px] font-medium uppercase tracking-wider text-[color:var(--color-text-quaternary)] first:pt-1",
      className,
    )}
    {...props}
  />
));
DropdownMenuSectionLabel.displayName = "DropdownMenuSectionLabel";

export {
  DropdownMenu,
  DropdownMenuTrigger,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuCheckboxItem,
  DropdownMenuRadioItem,
  DropdownMenuLabel,
  DropdownMenuSeparator,
  DropdownMenuShortcut,
  DropdownMenuGroup,
  DropdownMenuPortal,
  DropdownMenuSub,
  DropdownMenuSubContent,
  DropdownMenuSubTrigger,
  DropdownMenuRadioGroup,
  DropdownMenuSearch,
  DropdownMenuSectionLabel,
};
