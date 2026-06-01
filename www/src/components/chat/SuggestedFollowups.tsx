import { Sparkles } from "lucide-react";

interface Props {
  items: string[];
  onPick: (text: string) => void;
}

// NET-NEW (not in the original Codex web shell): suggested follow-up chips
// shown below the last assistant message. The original only has a host
// `send-follow-up-message` command (a normal compose path) and a separate
// home-screen "ambient suggestions" feature — there is no follow-up chip row
// in the transcript. This is a deliberate diminuendo-only addition; do not
// treat it as original Codex behavior.
export function SuggestedFollowups({ items, onPick }: Props) {
  if (items.length === 0) return null;
  return (
    <div className="mt-3 flex flex-wrap gap-1.5">
      {items.map((q, i) => (
        <button
          key={i}
          onClick={() => onPick(q)}
          className="flex items-center gap-1.5 rounded-full border border-[color:var(--border)] bg-background px-3 py-1 text-[12px] text-[color:var(--color-text-secondary)] hover:border-foreground/30 hover:bg-[color:var(--color-surface-hover)] hover:text-foreground"
        >
          <Sparkles className="size-3 text-[color:var(--color-text-tertiary)]" />
          {q}
        </button>
      ))}
    </div>
  );
}
