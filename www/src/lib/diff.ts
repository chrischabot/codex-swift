import type { DiffFile, DiffLine } from "@/domain/models";

// Shared unified-diff parsing. ONE implementation feeds both the inline chat
// DiffBlock and the side-panel Review tab, so the two surfaces can never
// disagree on line numbers / classification / counts (they used to maintain
// divergent parsers — renames, binary, and "\ No newline" were handled
// differently in each).

// Count +/- lines in a single-file unified diff body (ignoring the ---/+++
// header rows). Used to give diff blocks accurate add/remove totals.
export function countDiff(diff?: string): { added: number; removed: number } {
  let added = 0, removed = 0;
  for (const l of (diff ?? "").split("\n")) {
    if (l.startsWith("+") && !l.startsWith("+++")) added++;
    else if (l.startsWith("-") && !l.startsWith("---")) removed++;
  }
  return { added, removed };
}

// Parse a git unified diff into the UI's DiffFile[] (path + per-line model).
// Handles multi-file diffs, hunk headers, renames, binary files, and
// new/deleted-file detection (so callers can badge each file).
export function parseUnifiedDiff(raw: string): DiffFile[] {
  const files: DiffFile[] = [];
  let cur: DiffFile | null = null;
  let oldLn = 0, newLn = 0;
  const flush = () => { if (cur && cur.path) { cur.delta = `+${cur.added} −${cur.removed}`; files.push(cur); } };
  const newFile = (path = ""): DiffFile => ({ path, delta: "", added: 0, removed: 0, lines: [], kind: "modified" });
  for (const line of raw.split("\n")) {
    if (line.startsWith("diff --git")) {
      flush();
      // `diff --git a/x b/x` — prefer the b/ path (the post-image).
      const m = line.match(/ a\/(.+) b\/(.+)$/);
      cur = newFile(m?.[2] ?? line.match(/ b\/(.+)$/)?.[1] ?? "");
      oldLn = 0; newLn = 0;
      continue;
    }
    if (!cur) {
      if (line.startsWith("--- ") || line.startsWith("+++ ")) cur = newFile();
      else continue;
    }
    if (line.startsWith("new file mode")) { cur.kind = "added"; continue; }
    if (line.startsWith("deleted file mode")) { cur.kind = "deleted"; continue; }
    if (line.startsWith("rename from ")) { cur.kind = "renamed"; cur.lines.push({ kind: "header", text: line } as DiffLine); continue; }
    if (line.startsWith("rename to ")) { cur.kind = "renamed"; const p = line.slice("rename to ".length).trim(); if (p) cur.path = p; continue; }
    if (line.startsWith("copy from ") || line.startsWith("copy to ") || line.startsWith("similarity index")
        || line.startsWith("index ") || line.startsWith("old mode") || line.startsWith("new mode")) continue;
    if (line.startsWith("Binary files") || line.startsWith("GIT binary patch")) {
      cur.kind = "binary";
      cur.lines.push({ kind: "header", text: "Binary file — not shown" } as DiffLine);
      continue;
    }
    if (line.startsWith("+++ ")) {
      const p = line.slice(4).replace(/^b\//, "").trim();
      if (p && p !== "/dev/null") cur.path = p;
      else if (p === "/dev/null") cur.kind = "deleted";
      continue;
    }
    if (line.startsWith("--- ")) {
      const p = line.slice(4).replace(/^a\//, "").trim();
      if (p === "/dev/null") cur.kind = "added";
      else if (!cur.path && p) cur.path = p;
      continue;
    }
    if (line.startsWith("@@")) {
      const m = line.match(/@@ -(\d+)(?:,\d+)? \+(\d+)(?:,\d+)? @@/);
      oldLn = m ? parseInt(m[1], 10) : 0;
      newLn = m ? parseInt(m[2], 10) : 0;
      cur.lines.push({ kind: "header", text: line } as DiffLine);
      continue;
    }
    if (line.startsWith("+") && !line.startsWith("+++")) { cur.lines.push({ kind: "added", newLine: newLn++, text: line.slice(1) }); cur.added++; continue; }
    if (line.startsWith("-") && !line.startsWith("---")) { cur.lines.push({ kind: "removed", oldLine: oldLn++, text: line.slice(1) }); cur.removed++; continue; }
    if (line.startsWith(" ")) { cur.lines.push({ kind: "context", oldLine: oldLn++, newLine: newLn++, text: line.slice(1) }); continue; }
    // "\ No newline at end of file" and blank trailing lines → ignore.
  }
  flush();
  return files;
}
