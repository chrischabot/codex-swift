// Shared fenced-code masking — the single implementation of "blank out fenced
// code blocks (``` / ~~~) so markdown inside them is ignored". Previously this
// state machine was re-implemented in WikiBacklinksPanel (maskCode), in
// WikiOutlinePanel (parseHeadings + parseFootnotes), each subtly its own copy.
//
// Length-preserving: returns one output line per input line (fenced lines → "")
// so callers that depend on line indices (fragment scroll, footnote lines) keep
// working. Inline `code` spans are optionally blanked too (length-preserving),
// which the backlinks parser wants but the outline parser does not (it would
// mangle heading text).

export interface MaskFencedOptions {
  /** Also blank inline `code` spans (default true). The outline passes false so
   *  a heading like ``## API `v2` `` keeps its text for slug computation. */
  inlineCode?: boolean;
}

export function maskFencedCode(content: string, opts: MaskFencedOptions = {}): string[] {
  const inlineCode = opts.inlineCode ?? true;
  const lines = content.split(/\r?\n/);
  const out: string[] = [];
  let fence: string | null = null; // the fence char (` or ~) of the open block
  for (const line of lines) {
    const fenceMatch = line.match(/^\s{0,3}(`{3,}|~{3,})/);
    if (fenceMatch) {
      const marker = fenceMatch[1][0];
      if (fence === null) fence = marker;
      else if (marker === fence) fence = null;
      out.push("");
      continue;
    }
    if (fence !== null) {
      out.push("");
      continue;
    }
    out.push(inlineCode ? line.replace(/`[^`]*`/g, (m) => " ".repeat(m.length)) : line);
  }
  return out;
}
