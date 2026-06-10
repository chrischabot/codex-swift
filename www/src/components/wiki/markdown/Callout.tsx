import {
  AlertTriangle,
  Bug,
  Check,
  ChevronRight,
  CircleAlert,
  CircleHelp,
  Flame,
  Info,
  ListTodo,
  type LucideIcon,
  Pencil,
  Quote,
  ScrollText,
  Star,
  X,
} from "lucide-react";
import { type ReactNode, useState } from "react";
import { cn } from "@/lib/utils";
import type { CalloutType } from "./wikiRemarkPlugins";

interface Props {
  /** Canonical callout type (already alias-resolved by parseCallout). */
  type: CalloutType;
  /** Header title; when null the capitalized type name is shown. */
  title?: string | null;
  /** Foldable marker captured by remarkCallouts: `+` (foldable, open) /
   *  `-` (foldable, collapsed) / null (not foldable — no toggle). */
  fold?: "+" | "-" | null;
  children?: ReactNode;
}

interface CalloutStyle {
  icon: LucideIcon;
  /** Accent color CSS value (used for the left border + icon + title). */
  accent: string;
  /** Faint tinted background CSS value for the callout body. */
  tint: string;
}

// type → icon + www-token colors. We use the www palette tokens (see
// /tmp/wiki_bp_token-map.md) rather than granite's Obsidian RGB callout vars.
// The tint is a low-alpha wash of the same hue via color-mix so it works in
// both light and dark themes off a single token.
function styleFor(type: CalloutType): CalloutStyle {
  const make = (icon: LucideIcon, token: string): CalloutStyle => ({
    icon,
    accent: `var(${token})`,
    tint: `color-mix(in srgb, var(${token}) 8%, transparent)`,
  });
  switch (type) {
    case "note":
      return make(Pencil, "--text-link");
    case "abstract":
      return make(ScrollText, "--color-green-500");
    case "info":
      return make(Info, "--text-link");
    case "todo":
      return make(ListTodo, "--text-link");
    case "tip":
      return make(Flame, "--color-green-500");
    case "important":
      return make(Star, "--color-purple-400");
    case "success":
      return make(Check, "--color-green-500");
    case "question":
      return make(CircleHelp, "--color-yellow-400");
    case "warning":
      return make(AlertTriangle, "--color-orange-500");
    case "failure":
      return make(X, "--color-red-500");
    case "danger":
      return make(CircleAlert, "--color-red-500");
    case "bug":
      return make(Bug, "--color-red-500");
    case "example":
      return make(ScrollText, "--color-purple-400");
    case "quote":
      return make(Quote, "--color-text-tertiary");
    default:
      return make(Pencil, "--text-link");
  }
}

function capitalize(s: string): string {
  return s.length > 0 ? s[0]!.toUpperCase() + s.slice(1) : s;
}

/**
 * Obsidian-style callout box: colored left border + tinted background, a header
 * row with a lucide icon and title, and the markdown body underneath.
 * Mirrors granite's reading-mode `.callout` block (renderer.ts:447-498).
 */
export function Callout({ type, title, fold = null, children }: Props) {
  const style = styleFor(type);
  const Icon = style.icon;
  const foldable = fold === "+" || fold === "-";
  // Initial collapsed state follows the marker (`-` = start collapsed).
  const [collapsed, setCollapsed] = useState(fold === "-");
  const headerLabel = title ?? capitalize(type);

  return (
    <div
      className={cn(
        "wiki-callout my-4 overflow-hidden rounded-md border border-l-[3px]",
        "border-[color:var(--border)]",
        `wiki-callout-${type}`,
        foldable && collapsed && "is-collapsed",
      )}
      data-callout={type}
      style={{ borderLeftColor: style.accent, backgroundColor: style.tint }}
    >
      {foldable ? (
        <button
          type="button"
          aria-expanded={!collapsed}
          onClick={() => setCollapsed((v) => !v)}
          className="flex w-full items-center gap-2 px-3 pt-2.5 pb-1 text-left font-semibold"
        >
          <ChevronRight
            className={cn(
              "size-3.5 shrink-0 transition-transform",
              !collapsed && "rotate-90",
            )}
            style={{ color: style.accent }}
            aria-hidden
          />
          <Icon className="size-4 shrink-0" style={{ color: style.accent }} aria-hidden />
          <span className="text-[14px]" style={{ color: style.accent }}>
            {headerLabel}
          </span>
        </button>
      ) : (
        <div className="flex items-center gap-2 px-3 pt-2.5 pb-1 font-semibold">
          <Icon className="size-4 shrink-0" style={{ color: style.accent }} aria-hidden />
          <span className="text-[14px]" style={{ color: style.accent }}>
            {headerLabel}
          </span>
        </div>
      )}
      {!(foldable && collapsed) && (
        <div className="px-3 pb-2.5 text-[14px] leading-[1.65] text-foreground [&>:last-child]:mb-0">
          {children}
        </div>
      )}
    </div>
  );
}
