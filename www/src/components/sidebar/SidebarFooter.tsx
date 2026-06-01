import { Settings as SettingsIcon, Smartphone } from "lucide-react";
import { useNavigate, useLocation } from "react-router-dom";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { ConnectionStatus } from "@/components/shell/ConnectionStatus";
import { SidebarNavItem } from "./SidebarNavItem";
import { toast } from "@/components/ui/sonner";

export function SidebarFooter() {
  const navigate = useNavigate();
  const location = useLocation();
  const active = location.pathname === "/settings";
  return (
    <div className="flex flex-col">
      <div className="px-2 pb-1 pt-2">
        <ConnectionStatus />
      </div>
      <div className="flex h-11 shrink-0 items-center justify-between border-t border-[color:var(--sidebar-border)] px-2">
        <div className="flex-1">
          <SidebarNavItem
            icon={<SettingsIcon />}
            label="Settings"
            active={active}
            onClick={() => navigate("/settings")}
          />
        </div>
        <Tooltip>
          <TooltipTrigger asChild>
            <button
              type="button"
              aria-label="Connect a device"
              onClick={() => toast("Connect a device to this Mac")}
              className="flex h-7 w-7 items-center justify-center rounded-md text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--color-ring)]"
            >
              <Smartphone className="size-4" />
            </button>
          </TooltipTrigger>
          <TooltipContent>Connect a device</TooltipContent>
        </Tooltip>
      </div>
    </div>
  );
}
