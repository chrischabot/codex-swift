// M27 (recursive transclusion). Pure helpers for `![[Page#Heading]]` /
// `![[Page#^block]]` embeds: parse the fragment off a wikilink target and slice
// the referenced heading-section or block out of a page body. Used by the smart
// WikiEmbed, which then renders the slice with WikiMarkdown (depth-guarded).

export interface ParsedFragment {
  /** Bare page title (target before any `#`). */
  title: string;
  /** Heading text to embed (the `#Heading` form), if any. */
  heading?: string;
  /** Block id to embed (the `#^block` form), if any. */
  block?: string;
}

/** Split a wikilink target into `{title, heading?, block?}`. */
export function parseFragment(fullTarget: string): ParsedFragment {
  const hash = fullTarget.indexOf("#");
  if (hash === -1) return { title: fullTarget.trim() };
  const title = fullTarget.slice(0, hash).trim();
  const frag = fullTarget.slice(hash + 1).trim();
  if (frag.startsWith("^")) return { title, block: frag.slice(1).trim() };
  return { title, heading: frag };
}

const HEADING_RE = /^(#{1,6})\s+(.*?)\s*$/;

function normHeading(s: string): string {
  // Obsidian matches headings loosely: case-insensitive, trimmed, ignoring a
  // trailing `^block` and surrounding markdown emphasis markers.
  return s.replace(/[*_`~]/g, "").trim().toLowerCase();
}

/**
 * Return the markdown of the section under `heading` — from that heading line
 * (inclusive) up to the next heading of the SAME or higher level. Null when no
 * heading matches. Case/emphasis-insensitive on the heading text.
 */
export function extractHeadingSection(content: string, heading: string): string | null {
  const want = normHeading(heading);
  const lines = content.split(/\r?\n/);
  let start = -1;
  let level = 0;
  for (let i = 0; i < lines.length; i++) {
    const m = HEADING_RE.exec(lines[i]);
    if (m && normHeading(m[2]) === want) {
      start = i;
      level = m[1].length;
      break;
    }
  }
  if (start === -1) return null;
  let end = lines.length;
  for (let i = start + 1; i < lines.length; i++) {
    const m = HEADING_RE.exec(lines[i]);
    if (m && m[1].length <= level) {
      end = i;
      break;
    }
  }
  return lines.slice(start, end).join("\n").trim();
}

/**
 * Return the block ending with `^blockId`. A block is the paragraph (run of
 * non-blank lines) the marker sits on, with the trailing `^id` stripped. Null
 * when no line carries the marker.
 */
export function extractBlock(content: string, blockId: string): string | null {
  const marker = `^${blockId}`;
  const lines = content.split(/\r?\n/);
  let hit = -1;
  for (let i = 0; i < lines.length; i++) {
    const trimmed = lines[i].trimEnd();
    if (trimmed === marker || trimmed.endsWith(` ${marker}`)) {
      hit = i;
      break;
    }
  }
  if (hit === -1) return null;
  // The marker may sit on its own line directly after the block (Obsidian
  // allows both); walk up to gather the contiguous non-blank paragraph.
  let start = hit;
  if (lines[hit].trimEnd() === marker) start = hit - 1;
  while (start > 0 && lines[start - 1].trim() !== "") start -= 1;
  const para = lines.slice(start, hit + 1).join("\n");
  // Strip the trailing block marker from the captured text.
  return para.replace(new RegExp(`\\s*\\^${blockId}\\s*$`), "").trim();
}

/**
 * Slice the embeddable portion of `content` for a parsed fragment: the heading
 * section, the block, or (no fragment) the whole body. Returns null when a
 * requested heading/block isn't found, so the caller can show a "not found"
 * affordance distinct from an empty page.
 */
export function sliceForFragment(content: string, frag: ParsedFragment): string | null {
  if (frag.heading) return extractHeadingSection(content, frag.heading);
  if (frag.block) return extractBlock(content, frag.block);
  return content;
}
