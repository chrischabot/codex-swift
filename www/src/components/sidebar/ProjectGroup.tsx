import * as React from "react";
import type { Project, Thread } from "@/domain/models";
import { ThreadRow } from "./ThreadRow";
import { ProjectContextMenu } from "./ProjectContextMenu";
import { ChevronRight, Folder } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  project: Project;
  threads: Thread[];
  activeProjectId?: string;
  activeThreadId?: string;
  onSelectProject: () => void;
  onSelectThread: (id: string) => void;
}

export function ProjectGroup({
  project,
  threads,
  activeProjectId,
  activeThreadId,
  onSelectProject,
  onSelectThread,
}: Props) {
  const [open, setOpen] = React.useState(!project.collapsed);
  const active = activeProjectId === project.id;

  return (
    <div>
      <ProjectContextMenu project={project}>
        <button
          type="button"
          onClick={onSelectProject}
          className={cn(
            "group flex h-7 w-full items-center gap-2 rounded-md px-2 text-[13px] font-medium text-foreground transition-colors",
            "hover:bg-[color:var(--color-surface-hover)]",
            active && "bg-[color:var(--color-surface-active)]",
          )}
        >
          {/* Disclosure toggle — collapses/expands without navigating. */}
          <span
            role="button"
            tabIndex={-1}
            aria-label={open ? "Collapse project" : "Expand project"}
            onClick={(e) => {
              e.stopPropagation();
              setOpen((v) => !v);
            }}
            className="flex size-4 shrink-0 items-center justify-center text-[color:var(--color-text-tertiary)]"
          >
            <ChevronRight
              className={cn("size-3.5 transition-transform", open && "rotate-90")}
            />
          </span>
          <Folder className="size-4 text-[color:var(--color-text-secondary)]" />
          <span className="flex-1 truncate text-left">{project.name}</span>
        </button>
      </ProjectContextMenu>
      {open && (
        <div className="ml-3 border-l border-[color:var(--color-divider)] pl-[3px]">
          {threads.length > 0 ? (
            threads.map((t) => (
              <ThreadRow
                key={t.id}
                thread={t}
                active={activeThreadId === t.id}
                onClick={() => onSelectThread(t.id)}
                indent
              />
            ))
          ) : (
            <div className="px-2 py-1 pl-3 text-[12px] text-[color:var(--color-text-quaternary)]">
              No chats yet
            </div>
          )}
        </div>
      )}
    </div>
  );
}
