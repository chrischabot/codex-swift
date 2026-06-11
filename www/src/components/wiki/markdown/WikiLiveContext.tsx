import * as React from "react";

// M27 shared context for the wiki markdown renderer. Threading host data through
// react-markdown's component overrides isn't possible via props (the override
// map is static), so transclusion + live blocks read it from context instead.

/** Loads a page's body by wikilink title, for `![[Page]]` transclusion. */
export type EmbedLoader = (
  title: string,
) => Promise<{ id: string; title: string; content: string } | null>;

export interface WikiLiveValue {
  /** Host-provided page-body loader; absent → embeds stay placeholder cards. */
  loadEmbed?: EmbedLoader;
  /** Recursion depth of the current embed (0 = top-level page). */
  embedDepth: number;
  /** Page ids already in this embed chain — blocks transclusion cycles. */
  embedChain: ReadonlySet<string>;
  /** The page being rendered, for `backlinks` / `query` live blocks. Absent in
   *  hover previews and embeds (live blocks only fire at the top reading view). */
  currentPageId?: string;
  currentPageTitle?: string;
  /** When false, ```query``` / ```backlinks``` fences render as plain code
   *  (e.g. inside an embed or hover card). */
  liveBlocks: boolean;
}

const DEFAULT: WikiLiveValue = {
  embedDepth: 0,
  embedChain: new Set<string>(),
  liveBlocks: false,
};

const WikiLiveContext = React.createContext<WikiLiveValue>(DEFAULT);

export function useWikiLive(): WikiLiveValue {
  return React.useContext(WikiLiveContext);
}

/** Max nesting of `![[embeds]]` before we stop and show a link instead. */
export const MAX_EMBED_DEPTH = 3;

export function WikiLiveProvider({
  value,
  children,
}: {
  value: WikiLiveValue;
  children: React.ReactNode;
}) {
  return <WikiLiveContext.Provider value={value}>{children}</WikiLiveContext.Provider>;
}
