import { useNavigate, useLocation, useParams } from "react-router-dom";
import { useAppData } from "@/state/store";
import { SidebarNavItem } from "./SidebarNavItem";
import { SidebarSectionHeader } from "./SidebarSectionHeader";
import { ProjectGroup } from "./ProjectGroup";
import { ThreadRow } from "./ThreadRow";
import { SidebarFooter } from "./SidebarFooter";
import { ScrollArea } from "@/components/ui/scroll-area";
import { usePalette } from "@/components/shell/PaletteContext";
import {
  Edit3,
  Search,
  Blocks,
  Clock4,
  PanelLeft,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";

interface SidebarProps {
  onToggle: () => void;
}

export function Sidebar({ onToggle }: SidebarProps) {
  const navigate = useNavigate();
  const location = useLocation();
  const params = useParams();
  const palette = usePalette();
  const { projects, threads } = useAppData();

  // Original sidebar separates project groups into pinned vs unpinned
  // (sidebar-project-groups.js -> { pinnedGroups, unpinnedGroups }). Pinned
  // project groups render first.
  const pinnedProjects = projects.filter((p) => p.pinned);
  const unpinnedProjects = projects.filter((p) => !p.pinned);
  const orderedProjects = [...pinnedProjects, ...unpinnedProjects];

  // Projectless "Chats" list. Pinned threads surface first (per-row pinned
  // state) rather than under a separate top-level "Pinned" section, matching
  // the original recent/all-chats list (sidebar-thread-list-signals.js).
  const projectlessChats = threads
    .filter((t) => !t.projectId && t.status === "active")
    .sort((a, b) => Number(!!b.pinned) - Number(!!a.pinned));

  const isActive = (path: string) => location.pathname === path;
  const activeThreadId = params.threadId;
  const activeProjectId = params.projectId;

  return (
    <div className="flex h-full flex-col">
      {/* Top section — under traffic-lights */}
      <div className="drag-region flex h-11 shrink-0 items-center justify-end px-2">
        <div className="no-drag">
          <Tooltip>
            <TooltipTrigger asChild>
              <Button variant="ghost" size="iconSm" onClick={onToggle} aria-label="Hide sidebar" className="text-[color:var(--color-text-tertiary)]">
                <PanelLeft />
              </Button>
            </TooltipTrigger>
            <TooltipContent>Hide sidebar</TooltipContent>
          </Tooltip>
        </div>
      </div>

      <div className="px-2 pb-1">
        <SidebarNavItem
          icon={<Edit3 />}
          label="New chat"
          active={isActive("/home") || location.pathname.startsWith("/home")}
          onClick={() => navigate("/home")}
        />
        <SidebarNavItem icon={<Search />} label="Search" onClick={() => palette.setOpen(true)} trailing={<span className="text-[11px] text-[color:var(--color-text-quaternary)]">⌘K</span>} />
        <SidebarNavItem
          icon={<Blocks />}
          label="Plugins"
          active={isActive("/plugins")}
          onClick={() => navigate("/plugins")}
        />
        <SidebarNavItem
          icon={<Clock4 />}
          label="Automations"
          active={isActive("/automations")}
          onClick={() => navigate("/automations")}
        />
      </div>

      <ScrollArea className="flex-1">
        <div className="px-2 pb-3">
          <div>
            <SidebarSectionHeader label="Projects" />
            {orderedProjects.map((p) => (
              <ProjectGroup
                key={p.id}
                project={p}
                threads={threads.filter(
                  (t) => t.projectId === p.id && t.status === "active",
                )}
                activeProjectId={activeProjectId}
                activeThreadId={activeThreadId}
                onSelectProject={() => navigate(`/home/${p.id}`)}
                onSelectThread={(id) => navigate(`/thread/${id}`)}
              />
            ))}
          </div>

          <div className="mt-3">
            <SidebarSectionHeader label="Chats" />
            {projectlessChats.length === 0 ? (
              <div className="px-2 py-1 text-[12px] text-[color:var(--color-text-quaternary)]">No chats yet</div>
            ) : (
              projectlessChats.map((t) => (
                <ThreadRow
                  key={t.id}
                  thread={t}
                  active={activeThreadId === t.id}
                  onClick={() => navigate(`/thread/${t.id}`)}
                />
              ))
            )}
          </div>
        </div>
      </ScrollArea>

      <SidebarFooter />
    </div>
  );
}
