import { FileText, ImageIcon, ExternalLink, MessageSquareText, GitPullRequest } from "lucide-react";
import type { MessageAttachment } from "@/domain/models";
import { Tooltip, TooltipContent, TooltipProvider, TooltipTrigger } from "@/components/ui/tooltip";

interface Props {
  items: MessageAttachment[];
  onOpen?: (item: MessageAttachment) => void;
}

// Leading icon per attachment kind. "comment" (an inline code-review comment
// referencing a line range) and "pull-request" (a PR ref) get distinct icons
// from the file/image defaults, mirroring the original review attachment chips.
function iconFor(kind: MessageAttachment["kind"]) {
  switch (kind) {
    case "image":
      return ImageIcon;
    case "comment":
      return MessageSquareText;
    case "pull-request":
      return GitPullRequest;
    default:
      return FileText;
  }
}

// Mirrors the original user-message attachment chips (user-message-attachments.js):
// compact inline chips on a foreground/5 surface (mapped to --color-foreground/5
// here), an icon-xs leading icon that varies by attachment kind, the name with an
// optional badge, and a tooltipped open icon-button. Comment attachments also
// surface their target line range as the secondary line.
export function AttachmentList({ items, onOpen }: Props) {
  return (
    <TooltipProvider delayDuration={300}>
      <div className="my-3 flex flex-wrap gap-2">
        {items.map((it) => {
          const Icon = iconFor(it.kind);
          // For comments, the line range stands in for the badge if none was set.
          const secondary = it.kind === "comment" ? (it.lineRange ?? it.badge) : it.badge;
          return (
            <div
              key={it.id}
              className="flex items-center gap-2 rounded-2xl bg-[color:var(--color-foreground)]/5 px-3 py-1.5"
            >
              <Icon className="size-3.5 shrink-0 text-[color:var(--color-text-tertiary)]" />
              <div className="min-w-0">
                <span className="truncate text-[13px] text-[color:var(--color-text-primary)]">
                  {it.name}
                </span>
                {secondary && (
                  <span className="ml-1.5 font-mono text-[11.5px] text-[color:var(--color-text-tertiary)]">
                    {secondary}
                  </span>
                )}
              </div>
              <Tooltip>
                <TooltipTrigger asChild>
                  <button
                    type="button"
                    aria-label={openLabel(it.kind)}
                    onClick={() => onOpen?.(it)}
                    className="rounded-md p-1 text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
                  >
                    <ExternalLink className="size-3.5" />
                  </button>
                </TooltipTrigger>
                <TooltipContent>{openLabel(it.kind)}</TooltipContent>
              </Tooltip>
            </div>
          );
        })}
      </div>
    </TooltipProvider>
  );
}

function openLabel(kind: MessageAttachment["kind"]): string {
  switch (kind) {
    case "comment":
      return "Open comment";
    case "pull-request":
      return "Open pull request";
    default:
      return "Open attachment";
  }
}
