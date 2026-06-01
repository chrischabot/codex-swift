import * as React from "react";
import { cn } from "@/lib/utils";

interface Props {
  icon: React.ReactNode;
  label: string;
  active?: boolean;
  trailing?: React.ReactNode;
  onClick?: () => void;
}

export function SidebarNavItem({ icon, label, active, trailing, onClick }: Props) {
  return (
    <button
      type="button"
      onClick={onClick}
      className={cn(
        "group flex h-7 w-full items-center gap-2 rounded-md px-2 text-[13px] font-medium text-foreground transition-colors",
        "hover:bg-[color:var(--color-surface-hover)]",
        "focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--color-ring)]",
        active && "bg-[color:var(--color-surface-active)]",
      )}
    >
      <span className="flex size-4 shrink-0 items-center justify-center text-[color:var(--color-text-secondary)] [&_svg]:size-4">
        {icon}
      </span>
      <span className="flex-1 truncate text-left">{label}</span>
      {trailing && <span className="shrink-0">{trailing}</span>}
    </button>
  );
}
