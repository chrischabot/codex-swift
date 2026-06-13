// Canonical wikilink parsing — the single source of truth for splitting the
// inside of a `[[…]]` into its parts, and for FINDING wikilinks in a body. This
// replaces three independent implementations (transclude.parseFragment,
// wikiRemarkPlugins.parseWikilink, and WikiBacklinksPanel's WIKILINK_RE) that
// had drifted in their handling of alias/heading/block.
//
// A wikilink inner is `target(#heading|#^block)?(|alias)?` — order-independent
// enough that we split the alias on `|` first, then a `#` fragment off the
// target. Everything is trimmed.

import { maskFencedCode } from "./codeFences";

export interface WikilinkParts {
  /** The bare target (page title), trimmed. */
  target: string;
  /** Alias after `|`, if any. */
  alias?: string;
  /** `#heading` fragment, if any. */
  heading?: string;
  /** `#^block` fragment, if any. */
  block?: string;
}

/** Parse the inside of a `[[…]]` (no brackets, no leading `!`) into its parts. */
export function parseWikilinkInner(inner: string): WikilinkParts {
  let rest = inner;
  let alias: string | undefined;
  const pipe = rest.indexOf("|");
  if (pipe !== -1) {
    alias = rest.slice(pipe + 1).trim();
    rest = rest.slice(0, pipe);
  }
  let heading: string | undefined;
  let block: string | undefined;
  const hash = rest.indexOf("#");
  if (hash !== -1) {
    const after = rest.slice(hash + 1).trim();
    rest = rest.slice(0, hash);
    if (after.startsWith("^")) block = after.slice(1).trim();
    else heading = after;
  }
  return { target: rest.trim(), alias: alias || undefined, heading: heading || undefined, block: block || undefined };
}

// Matches [[Target]], [[Target|Display]], [[Target#Heading|Display]], ![[Embed]].
// Group 1: optional `!` embed marker. Group 2: the inner content.
export const WIKILINK_RE = /(!?)\[\[([^\]\n]+?)\]\]/g;

export interface FoundWikilink extends WikilinkParts {
  /** Display text: the alias if present, else the target. */
  display: string;
  /** True for transclusions `![[…]]`. */
  embed: boolean;
  /** Zero-based source line. */
  line: number;
}

/**
 * Find every wikilink in `content`, skipping fenced/inline code (shared masker,
 * length-preserving so `line` indices match the source). Each result carries the
 * parsed parts + display + embed flag + line.
 */
export function findWikilinks(content: string): FoundWikilink[] {
  const lines = maskFencedCode(content);
  const out: FoundWikilink[] = [];
  for (let i = 0; i < lines.length; i++) {
    const line = lines[i];
    // Cheap prefilter + length cap so a pathological long line can't drive the
    // regex into pathological backtracking.
    if (!line.includes("[[") || line.length > 20000) continue;
    WIKILINK_RE.lastIndex = 0;
    let m: RegExpExecArray | null;
    while ((m = WIKILINK_RE.exec(line)) !== null) {
      const parts = parseWikilinkInner(m[2] ?? "");
      if (!parts.target) continue;
      out.push({ ...parts, display: parts.alias ?? parts.target, embed: m[1] === "!", line: i });
    }
  }
  return out;
}
