import * as React from "react";
import { Copy, Check, Pencil } from "lucide-react";
import type { Message } from "@/domain/models";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";

interface Props {
  message: Message;
  onEdit?: () => void;
  className?: string;
}

// Hover/focus toolbar shown on USER messages only, mirroring the original
// user-message-attachments.js actions row: a relative timestamp followed by
// a Copy and an Edit ghost icon button, revealed on group-hover and
// group-focus-within (keyboard accessible). The original has no Regenerate /
// Branch / Share actions and no toolbar on assistant messages.
export function MessageActions({ message, onEdit, className }: Props) {
  const [copied, setCopied] = React.useState(false);
  const copy = () => {
    const text = message.blocks
      .map((b) => (b.type === "markdown" ? b.content : ""))
      .join("\n")
      .trim();
    navigator.clipboard?.writeText(text);
    setCopied(true);
    setTimeout(() => setCopied(false), 1200);
  };

  return (
    <div
      className={cn(
        "mr-1 ms-1 flex items-center gap-2 opacity-0 transition-opacity group-focus-within:opacity-100 group-hover:opacity-100",
        className,
      )}
    >
      <span className="text-[12px] text-[color:var(--color-text-tertiary)]">
        {formatSentAt(message.createdAt)}
      </span>
      <div className="flex items-center gap-1">
        <ActionBtn
          onClick={copy}
          ariaLabel={copied ? "Copied" : "Copy message"}
          tooltip={copied ? "Copied" : "Copy"}
          tooltipDisabled={copied}
        >
          {copied ? <Check className="size-3.5" /> : <Copy className="size-3.5" />}
        </ActionBtn>
        {onEdit && (
          <ActionBtn onClick={onEdit} ariaLabel="Edit message" tooltip="Edit">
            <Pencil className="size-3.5" />
          </ActionBtn>
        )}
      </div>
    </div>
  );
}

function ActionBtn({
  children,
  onClick,
  ariaLabel,
  tooltip,
  tooltipDisabled,
}: {
  children: React.ReactNode;
  onClick: () => void;
  ariaLabel: string;
  tooltip: string;
  tooltipDisabled?: boolean;
}) {
  const button = (
    <button
      type="button"
      onClick={onClick}
      aria-label={ariaLabel}
      className="flex size-6 items-center justify-center rounded text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground"
    >
      {children}
    </button>
  );
  if (tooltipDisabled) return button;
  return (
    <Tooltip>
      <TooltipTrigger asChild>{button}</TooltipTrigger>
      <TooltipContent>{tooltip}</TooltipContent>
    </Tooltip>
  );
}

// Relative timestamp formatting roughly matching the original Te/we helper:
// time-only for today, weekday + time within the past week, otherwise
// month/day + time.
function formatSentAt(ms: number): string {
  const date = new Date(ms);
  const now = new Date();
  const time = date.toLocaleTimeString(undefined, {
    hour: "numeric",
    minute: "2-digit",
  });
  const sameDay =
    date.getFullYear() === now.getFullYear() &&
    date.getMonth() === now.getMonth() &&
    date.getDate() === now.getDate();
  if (sameDay) return time;
  const diffDays = (now.getTime() - date.getTime()) / 86_400_000;
  if (diffDays < 7) {
    const weekday = date.toLocaleDateString(undefined, { weekday: "long" });
    return `${weekday} ${time}`;
  }
  const md = date.toLocaleDateString(undefined, { month: "short", day: "numeric" });
  return `${md} ${time}`;
}
