import * as React from "react";
import {
  ContextMenu,
  ContextMenuContent,
  ContextMenuItem,
  ContextMenuTrigger,
} from "@/components/ui/context-menu";
import type { Project } from "@/domain/models";
import { toast } from "@/components/ui/sonner";

interface Props {
  project: Project;
  children: React.ReactNode;
}

// NOTE: The original Codex desktop has no dedicated project right-click context
// menu — the only project-related menu in the source (project-dropdown-options.js)
// is a workspace-root selector. The previous implementation invented
// thread-level actions ("Pin chat", "Rename chat", "Open side chat", "Fork")
// which do not exist for projects. This is pared back to the project actions
// that are actually grounded in the source: copying the working directory
// (thread-actions.js:244 "Copy working directory") and opening a new window
// (thread-actions.js:284 "Open in new window").
export function ProjectContextMenu({ project, children }: Props) {
  return (
    <ContextMenu>
      <ContextMenuTrigger asChild>{children}</ContextMenuTrigger>
      <ContextMenuContent>
        <ContextMenuItem
          onSelect={() => {
            navigator.clipboard
              ?.writeText(project.workingDirectory)
              .then(
                () => toast("Copied working directory"),
                () => toast("Failed to copy working directory"),
              );
          }}
        >
          Copy working directory
        </ContextMenuItem>
      </ContextMenuContent>
    </ContextMenu>
  );
}
