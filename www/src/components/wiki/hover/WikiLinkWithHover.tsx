import * as React from "react";
import { HoverCard, HoverCardContent, HoverCardTrigger } from "@/components/ui/hover-card";
import { WikiHoverCard } from "./WikiHoverCard";

interface Props {
  /** Full wikilink target — page title possibly with a `#heading` / `#^block`
   *  suffix. The suffix is stripped before resolving to a page id. */
  target: string;
  /** Maps a (suffix-stripped) title to a page id. Typically built from
   *  listWikiPages; returns undefined for unresolved/dangling links. */
  resolveId?: (title: string) => string | undefined;
  /** Open the link's target (click) — forwarded to WikiMarkdown's onWikiLink.
   *  Optional: when absent the anchor falls back to navigating its href (so
   *  surfaces that render WikiMarkdown without a handler keep working links). */
  onOpen?: (target: string) => void;
  /** The rendered anchor/label (the wikilink text or alias). */
  children: React.ReactNode;
}

const OPEN_DELAY_MS = 300;
const CLOSE_DELAY_MS = 200;

/**
 * Wraps a wikilink anchor in a radix HoverCard that previews the resolved page.
 * Radix's openDelay (~300ms) gives the hover-intent debounce — WikiHoverCard
 * only mounts (and thus only fetches) once the card actually opens. The anchor
 * itself stays clickable and routes through `onOpen`.
 *
 * When the target can't be resolved to a page id, the anchor renders plain
 * (no hover card) so dangling links don't pop an empty "not found" card.
 */
export function WikiLinkWithHover({ target, resolveId, onOpen, children }: Props) {
  // Strip a trailing #heading / #^block fragment for resolution + preview.
  const baseTitle = React.useMemo(() => target.split("#", 1)[0]!.trim(), [target]);
  const pageId = resolveId?.(baseTitle);

  const anchor = (
    <a
      href={`/wiki?q=${encodeURIComponent(target)}`}
      className="wiki-link cursor-pointer rounded-sm text-[color:var(--text-link)] underline decoration-dotted underline-offset-2 hover:decoration-solid"
      onClick={(e) => {
        // Only intercept when a handler is wired; otherwise let the href
        // navigate (the original WikiMarkdown behaviour for handler-less hosts).
        if (onOpen) {
          e.preventDefault();
          onOpen(target);
        }
      }}
    >
      {children}
    </a>
  );

  // No resolvable target → plain anchor, no preview card.
  if (!pageId) return anchor;

  return (
    <HoverCard openDelay={OPEN_DELAY_MS} closeDelay={CLOSE_DELAY_MS}>
      <HoverCardTrigger asChild>{anchor}</HoverCardTrigger>
      <HoverCardContent align="start" className="w-80">
        <WikiHoverCard pageId={pageId} title={baseTitle} onOpen={() => onOpen?.(target)} />
      </HoverCardContent>
    </HoverCard>
  );
}
