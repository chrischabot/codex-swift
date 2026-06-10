import * as React from "react";
import type { WikiPageSummary } from "@/runtime/connector";

// Explorer sort options + their localStorage persistence.
//
// granite ref: src/ui/views/sidebar exposes a "sort order" affordance on the
// file tree (name asc/desc, modified-time asc/desc). Here the same four orders
// drive how SIBLING nodes are ordered within each folder (folders always stay
// grouped before files — only the within-group ordering changes). The choice is
// persisted per-browser so the tree reopens the way the user left it.

export type SortMode = "name-asc" | "name-desc" | "date-newest" | "date-oldest";

export const SORT_MODES: readonly SortMode[] = [
  "name-asc",
  "name-desc",
  "date-newest",
  "date-oldest",
];

export const SORT_LABELS: Record<SortMode, string> = {
  "name-asc": "Name (A → Z)",
  "name-desc": "Name (Z → A)",
  "date-newest": "Date (newest first)",
  "date-oldest": "Date (oldest first)",
};

export const DEFAULT_SORT: SortMode = "name-asc";

const STORAGE_KEY = "wiki:explorer:sort";

function isSortMode(v: unknown): v is SortMode {
  return typeof v === "string" && (SORT_MODES as readonly string[]).includes(v);
}

export function readSortMode(): SortMode {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    return isSortMode(raw) ? raw : DEFAULT_SORT;
  } catch {
    return DEFAULT_SORT;
  }
}

function writeSortMode(mode: SortMode): void {
  try {
    localStorage.setItem(STORAGE_KEY, mode);
  } catch {
    /* quota / private mode — non-fatal, choice stays in memory */
  }
}

/** Persisted sort-mode state for the explorer header menu. */
export function useSortMode(): [SortMode, (mode: SortMode) => void] {
  const [mode, setMode] = React.useState<SortMode>(() =>
    typeof window === "undefined" ? DEFAULT_SORT : readSortMode(),
  );
  const set = React.useCallback((next: SortMode) => {
    setMode(next);
    writeSortMode(next);
  }, []);
  return [mode, set];
}

/** Locale-aware case-insensitive label compare (the existing tree default). */
function byLabel(a: { label: string }, b: { label: string }): number {
  return a.label.localeCompare(b.label, undefined, { sensitivity: "base" });
}

/** Comparator for two FILE nodes' underlying pages under a given mode. Folders
 *  carry no date, so they always fall back to label order regardless of mode
 *  (handled by `compareNodes`). Pages with no `updatedAt` sort last under the
 *  date modes so undated rows don't jump to the top. */
function comparePages(a: WikiPageSummary, b: WikiPageSummary, mode: SortMode): number {
  switch (mode) {
    case "name-asc":
      return labelOf(a).localeCompare(labelOf(b), undefined, { sensitivity: "base" });
    case "name-desc":
      return labelOf(b).localeCompare(labelOf(a), undefined, { sensitivity: "base" });
    case "date-newest":
    case "date-oldest": {
      const ua = a.updatedAt;
      const ub = b.updatedAt;
      // Missing dates sort last in BOTH directions.
      if (ua == null && ub == null) {
        return labelOf(a).localeCompare(labelOf(b), undefined, { sensitivity: "base" });
      }
      if (ua == null) return 1;
      if (ub == null) return -1;
      if (ua === ub) {
        return labelOf(a).localeCompare(labelOf(b), undefined, { sensitivity: "base" });
      }
      return mode === "date-newest" ? ub - ua : ua - ub;
    }
  }
}

function labelOf(p: WikiPageSummary): string {
  return (p.title ?? "").trim() || p.id;
}

// A minimal structural view of the tree nodes the explorer renders. Kept loose
// (rather than importing the FileNode/FolderNode types, which live in the
// component file) so this module stays a pure, independently-testable unit.
export interface SortableFile {
  type: "file";
  label: string;
  page: WikiPageSummary;
}
export interface SortableFolder {
  type: "folder";
  label: string;
}
export type SortableNode = SortableFile | SortableFolder;

/** Order two sibling nodes: folders always precede files; within the same kind,
 *  files honour the active sort mode and folders stay alphabetical (they have no
 *  date of their own). */
export function compareNodes(a: SortableNode, b: SortableNode, mode: SortMode): number {
  if (a.type !== b.type) return a.type === "folder" ? -1 : 1;
  if (a.type === "folder" || b.type === "folder") return byLabel(a, b);
  return comparePages(a.page, b.page, mode);
}
