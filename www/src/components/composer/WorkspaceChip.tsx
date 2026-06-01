import * as React from "react";
import {
  Folder,
  ChevronDown,
  FolderOpen,
  Settings,
  Search,
  FolderPlus,
  Cloud,
  CloudOff,
  Plus,
} from "lucide-react";
import { Popover, PopoverContent, PopoverTrigger } from "@/components/ui/popover";
import { useAppData } from "@/state/store";
import { useNavigate } from "react-router-dom";
import { toast } from "@/components/ui/sonner";
import { cn } from "@/lib/utils";
import type { Project } from "@/domain/models";

interface Props {
  activeProjectId?: string;
  onPick?: (projectId: string) => void;
}

// Heuristic for the mock: projects whose working directory isn't a local path
// (~ or /) are treated as remote, matching the original's local-vs-remote icon
// differentiation (workspace-root-icon.js).
function isRemote(p: Project) {
  return !/^[~/]/.test(p.workingDirectory);
}

function rowClass(active: boolean) {
  return cn(
    "flex w-full items-center gap-2 rounded-lg px-2 py-1.5 text-left text-md opacity-75 hover:opacity-100",
    "hover:bg-[color:var(--color-surface-hover)]",
    active && "bg-[color:var(--color-surface-active)] font-medium opacity-100",
  );
}

// Workspace chip below the composer. Mirrors local-active-workspace-root-dropdown.js:
// a "Search projects" field, the project list (with local/remote icons and a
// "No folders found" empty state), the add-project entry points, and the
// "Don't work in a project" / "Start from scratch" / "Use an existing folder"
// projectless options.
export function WorkspaceChip({ activeProjectId, onPick }: Props) {
  const { projects } = useAppData();
  const navigate = useNavigate();
  const [query, setQuery] = React.useState("");
  const active = projects.find((p) => p.id === activeProjectId) ?? projects[0];

  const filtered = React.useMemo(() => {
    const q = query.trim().toLowerCase();
    return q ? projects.filter((p) => p.name.toLowerCase().includes(q)) : projects;
  }, [projects, query]);

  return (
    <Popover>
      <PopoverTrigger asChild>
        <button
          type="button"
          className="flex items-center gap-1.5 rounded px-1 py-0.5 text-sm text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground"
        >
          {active && isRemote(active) ? <Cloud className="size-3.5" /> : <Folder className="size-3.5" />}
          {active?.name ?? "Workspace"}
          <ChevronDown className="size-3 opacity-60" />
        </button>
      </PopoverTrigger>
      <PopoverContent align="start" side="top" sideOffset={6} className="w-[260px] p-1.5">
        {/* Search projects */}
        <div className="mb-1 flex items-center gap-1.5 rounded-lg border border-[color:var(--border)] px-2">
          <Search className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" />
          <input
            value={query}
            onChange={(e) => setQuery(e.target.value)}
            placeholder="Search projects"
            className="h-7 w-full border-0 bg-transparent text-sm text-foreground outline-none placeholder:text-[color:var(--color-text-quaternary)]"
          />
        </div>

        <div className="space-y-px">
          {filtered.length === 0 ? (
            <div className="px-2 py-3 text-center text-sm text-[color:var(--color-text-tertiary)]">
              No folders found
            </div>
          ) : (
            filtered.map((p) => (
              <button
                key={p.id}
                onClick={() => {
                  // NET-NEW (mock only): the original sets the active workspace root
                  // via the controller; here we route to the project home.
                  onPick?.(p.id);
                  navigate(`/home/${p.id}`);
                }}
                className={rowClass(p.id === activeProjectId)}
              >
                {isRemote(p) ? (
                  <Cloud className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />
                ) : (
                  <Folder className="size-3.5 shrink-0 text-[color:var(--color-text-secondary)]" />
                )}
                <div className="min-w-0 flex-1">
                  <div className="truncate">{p.name}</div>
                  <div className="truncate font-mono text-2xs text-[color:var(--color-text-tertiary)]">{p.workingDirectory}</div>
                </div>
              </button>
            ))
          )}
        </div>

        {/* Add project entry points */}
        <div className="mt-1 border-t border-[color:var(--color-divider)] pt-1">
          <button
            onClick={() => toast("Add local project — coming soon")}
            className={rowClass(false)}
          >
            <FolderPlus className="size-3.5 shrink-0" /> Add local project
          </button>
          <button
            onClick={() => toast("Add remote project — coming soon")}
            className={rowClass(false)}
          >
            <Cloud className="size-3.5 shrink-0" /> Add remote project
          </button>
        </div>

        {/* Projectless options */}
        <div className="mt-1 border-t border-[color:var(--color-divider)] pt-1">
          <button
            onClick={() => {
              onPick?.("");
              navigate("/home");
            }}
            className={rowClass(false)}
          >
            <CloudOff className="size-3.5 shrink-0" /> Don't work in a project
          </button>
          <button
            onClick={() => toast("Start from scratch — coming soon")}
            className={rowClass(false)}
          >
            <Plus className="size-3.5 shrink-0" /> Start from scratch
          </button>
          <button
            onClick={() => toast("Folder picker — coming soon")}
            className={rowClass(false)}
          >
            <FolderOpen className="size-3.5 shrink-0" /> Use an existing folder
          </button>
        </div>

        <div className="mt-1 border-t border-[color:var(--color-divider)] pt-1">
          <button
            onClick={() => navigate("/settings")}
            className={rowClass(false)}
          >
            <Settings className="size-3.5 shrink-0" /> Workspace settings
          </button>
        </div>
      </PopoverContent>
    </Popover>
  );
}
