import { FileText } from "lucide-react";
import { cn } from "@/lib/utils";

interface Props {
  /** The bare target name (no #heading / #^block suffix). */
  target: string;
  /** The full target including any #heading / #^block fragment. */
  fullTarget?: string;
  /** The display label (alias) if one was given, else the target. */
  display?: string;
  /** Optional click handler — wired by WikiMarkdown to navigate. */
  onOpen?: (target: string) => void;
  /** Optional DOM id (a `block-<id>` anchor hoisted from a `^blockid` on the
   *  embed line) so `[[Page#^id]]` can scroll to it. */
  anchorId?: string;
}

/**
 * Placeholder card for an Obsidian transclusion `![[Page]]`. Full transclusion
 * (recursive inlining of the referenced note / heading / block) is deferred;
 * for now we render a bordered "embed" callout box naming the target and noting
 * that it's an embed. When `onOpen` is supplied the whole card is clickable and
 * navigates to the referenced page.
 */
export function WikiEmbed({ target, fullTarget, display, onOpen, anchorId }: Props) {
  const label = display && display.length > 0 ? display : target;
  const clickable = typeof onOpen === "function";
  return (
    <div
      id={anchorId}
      className={cn(
        "wiki-embed my-3 rounded-md border border-dashed border-[color:var(--border)]",
        "bg-[color:var(--code-surface)] px-3 py-2.5",
        clickable && "cursor-pointer hover:bg-[color:var(--color-surface-hover)]",
      )}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onClick={clickable ? () => onOpen!(fullTarget ?? target) : undefined}
      onKeyDown={
        clickable
          ? (e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                onOpen!(fullTarget ?? target);
              }
            }
          : undefined
      }
    >
      <div className="flex items-center gap-2 text-[14px] font-medium text-[color:var(--text-link)]">
        <FileText className="size-4 shrink-0" aria-hidden />
        <span className="truncate">{label}</span>
      </div>
      <div className="mt-0.5 text-[12px] text-[color:var(--color-text-tertiary)]">
        Embedded note (transclusion preview)
      </div>
    </div>
  );
}
