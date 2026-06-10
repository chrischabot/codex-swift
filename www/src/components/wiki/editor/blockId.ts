// Block-ID insert command for the wiki editor.
//
// Obsidian parity: a `^id` suffix at the end of a block lets other notes link
// to that exact block via `[[Page#^id]]`. This command generates a short random
// id, appends `^id` to the end of the line holding the (main) cursor, and copies
// the ready-to-paste `[[<pageTitle>#^id]]` reference to the clipboard so the user
// can immediately link to it elsewhere.
//
// The pure pieces (`generateBlockId`, `planBlockIdInsert`) are unit-testable
// without a CodeMirror view; the Command + factory at the bottom adapt them to
// the live editor and the clipboard.

import { EditorView } from "@codemirror/view";
import type { Command } from "@codemirror/view";

// Obsidian block ids are `[A-Za-z0-9-]`; we use lowercase alphanumerics for a
// short, paste-safe, collision-unlikely token.
const ID_ALPHABET = "abcdefghijklmnopqrstuvwxyz0123456789";
const ID_LENGTH = 6;

/** Generate a short random block id (6 chars, lowercased alphanumeric). The
 *  optional `rng` seam keeps it deterministic in tests. */
export function generateBlockId(rng: () => number = Math.random): string {
  let out = "";
  for (let i = 0; i < ID_LENGTH; i++) {
    out += ID_ALPHABET[Math.floor(rng() * ID_ALPHABET.length)];
  }
  return out;
}

export interface BlockIdInsertPlan {
  /** Document offset to insert the suffix at (end of the cursor's line). */
  readonly at: number;
  /** The text to insert (` ^id`, with a leading space unless the line is empty). */
  readonly insert: string;
  /** Caret offset after the insert lands. */
  readonly caret: number;
}

/**
 * Compute where/what to insert for a block id, given the full text and the main
 * cursor offset. The suffix goes at the END of the cursor's line; a leading
 * space separates it from existing content (Obsidian requires the gap), and is
 * omitted when the line is blank. If the line already ends with a `^id` block id
 * we return null (don't stack a second one). Pure + exported for tests.
 */
export function planBlockIdInsert(text: string, cursor: number, id: string): BlockIdInsertPlan | null {
  const lineStart = text.lastIndexOf("\n", cursor - 1) + 1;
  let lineEnd = text.indexOf("\n", cursor);
  if (lineEnd === -1) lineEnd = text.length;
  const line = text.slice(lineStart, lineEnd);
  // Already block-id'd → bail rather than appending a duplicate.
  if (/[ \t]\^[A-Za-z0-9_-]+[ \t]*$/.test(line)) return null;
  const trimmedEnd = line.replace(/[ \t]+$/, "");
  // Re-derive lineEnd against the trimmed tail so we drop trailing spaces.
  const insertAt = lineStart + trimmedEnd.length;
  const insert = trimmedEnd.length === 0 ? `^${id}` : ` ^${id}`;
  return { at: insertAt, insert, caret: insertAt + insert.length };
}

/** Best-effort clipboard write — silently no-ops where the API is unavailable
 *  (insecure context, denied permission); the id is still inserted. */
function copyToClipboard(value: string): void {
  try {
    void globalThis.navigator?.clipboard?.writeText?.(value);
  } catch {
    /* clipboard blocked — non-fatal, the ^id is still in the doc */
  }
}

/**
 * Build the block-id Command. Inserts ` ^id` at the cursor's line end and copies
 * `[[<pageTitle>#^id]]` to the clipboard. `getPageTitle` returns the current
 * editor page title at call time (it changes as the user types the title), so a
 * thunk rather than a captured string.
 */
export function insertBlockIdCommand(getPageTitle: () => string): Command {
  return (view: EditorView): boolean => {
    const id = generateBlockId();
    const cursor = view.state.selection.main.head;
    const plan = planBlockIdInsert(view.state.doc.toString(), cursor, id);
    if (!plan) return false;
    view.dispatch({
      changes: { from: plan.at, insert: plan.insert },
      selection: { anchor: plan.caret },
      scrollIntoView: true,
    });
    const title = getPageTitle().trim();
    copyToClipboard(`[[${title}#^${id}]]`);
    view.focus();
    return true;
  };
}
