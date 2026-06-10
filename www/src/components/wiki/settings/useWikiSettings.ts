import * as React from "react";
import { DEFAULT_GRAPH_SETTINGS, type GraphColorGroup, type GraphSettings } from "../graph/GraphControls";

// Wiki UI preferences, persisted to localStorage and synced across tabs +
// across hook instances in the same tab.
//
// A www-idiomatic port of granite's SettingsModal storage layer. Granite
// fans these out across a settings store + per-plugin stores backed by a vault
// file; here the wiki is a single connector-backed view, so every preference
// the modal exposes lives under one JSON blob (key "wiki:settings").
//
// The `storage` event fires ONLY in OTHER tabs, so a writing tab's other
// useWikiSettings instances (e.g. the modal + the editor reading prefs) would
// never observe the change. As with useBookmarks we dispatch CHANGE_EVENT on
// every write and all instances re-read on it.

const STORAGE_KEY = "wiki:settings";
const CHANGE_EVENT = "wiki:settings:changed";

/** The set of right-rail tabs the modal can pin as the default. Kept in sync
 *  with the TabsTrigger values in WikiPage. */
export const WIKI_RAIL_TABS = [
  "connections",
  "graph",
  "tags",
  "outline",
  "bookmarks",
  "recents",
  "properties",
] as const;
export type WikiRailTab = (typeof WIKI_RAIL_TABS)[number];

export interface WikiSettings {
  /** Render markdown inline as you type (live preview) vs. raw source. */
  readonly editorLivePreview: boolean;
  /** Vim keybindings in the CodeMirror editor. */
  readonly editorVim: boolean;
  /** Auto-close brackets/quotes as you type (CM6 closeBrackets). */
  readonly autoPairBrackets: boolean;
  /** Re-indent the current line on input (CM6 indentOnInput). */
  readonly indentOnInput: boolean;
  /** Native browser spellcheck on the editor surface. */
  readonly spellcheck: boolean;
  /** Constrain editor + reading content to a readable max line width. */
  readonly readableLineWidth: boolean;
  /** Editor font size in px. */
  readonly editorFontSize: number;
  /** Reading-view font size in px. */
  readonly readingFontSize: number;
  /** Show the line-number gutter in the editor. */
  readonly showLineNumbers: boolean;
  /** Default knobs the graph view boots with. */
  readonly graphDefaults: GraphSettings;
  /** Right-rail tab selected when a page first opens. */
  readonly defaultRailTab: WikiRailTab;
}

export const DEFAULT_WIKI_SETTINGS: WikiSettings = {
  editorLivePreview: true,
  editorVim: false,
  autoPairBrackets: true,
  indentOnInput: true,
  spellcheck: false,
  readableLineWidth: false,
  editorFontSize: 15,
  readingFontSize: 16,
  showLineNumbers: false,
  graphDefaults: DEFAULT_GRAPH_SETTINGS,
  defaultRailTab: "connections",
};

/** Bounds for the font-size sliders, shared by the modal. */
export const EDITOR_FONT_RANGE = { min: 11, max: 24, step: 1 } as const;
export const READING_FONT_RANGE = { min: 12, max: 28, step: 1 } as const;

function isRailTab(v: unknown): v is WikiRailTab {
  return typeof v === "string" && (WIKI_RAIL_TABS as readonly string[]).includes(v);
}

function num(v: unknown, fallback: number): number {
  return typeof v === "number" && Number.isFinite(v) ? v : fallback;
}

function bool(v: unknown, fallback: boolean): boolean {
  return typeof v === "boolean" ? v : fallback;
}

/** Coerce arbitrary parsed JSON into a fully-populated, type-safe settings
 *  object. Unknown / corrupt fields fall back to defaults rather than throwing,
 *  so a partial or stale blob from an older build still loads cleanly. */
function coerce(raw: unknown): WikiSettings {
  const o = (typeof raw === "object" && raw !== null ? raw : {}) as Record<string, unknown>;
  const d = DEFAULT_WIKI_SETTINGS;
  const g = (typeof o.graphDefaults === "object" && o.graphDefaults !== null
    ? o.graphDefaults
    : {}) as Record<string, unknown>;
  return {
    editorLivePreview: bool(o.editorLivePreview, d.editorLivePreview),
    editorVim: bool(o.editorVim, d.editorVim),
    autoPairBrackets: bool(o.autoPairBrackets, d.autoPairBrackets),
    indentOnInput: bool(o.indentOnInput, d.indentOnInput),
    spellcheck: bool(o.spellcheck, d.spellcheck),
    readableLineWidth: bool(o.readableLineWidth, d.readableLineWidth),
    editorFontSize: num(o.editorFontSize, d.editorFontSize),
    readingFontSize: num(o.readingFontSize, d.readingFontSize),
    showLineNumbers: bool(o.showLineNumbers, d.showLineNumbers),
    graphDefaults: {
      repulsion: num(g.repulsion, d.graphDefaults.repulsion),
      attraction: num(g.attraction, d.graphDefaults.attraction),
      linkDistance: num(g.linkDistance, d.graphDefaults.linkDistance),
      centerGravity: num(g.centerGravity, d.graphDefaults.centerGravity),
      nodeSize: num(g.nodeSize, d.graphDefaults.nodeSize),
      linkThickness: num(g.linkThickness, d.graphDefaults.linkThickness),
      labelThreshold: num(g.labelThreshold, d.graphDefaults.labelThreshold),
      textSize: num(g.textSize, d.graphDefaults.textSize),
      colorBy: g.colorBy === "none" ? "none" : "kind",
      depth: num(g.depth, d.graphDefaults.depth),
      textFilter: typeof g.textFilter === "string" ? g.textFilter : d.graphDefaults.textFilter,
      colorGroups: Array.isArray(g.colorGroups)
        ? (g.colorGroups as GraphColorGroup[]).filter(
            (x) =>
              !!x &&
              typeof (x as GraphColorGroup).id === "string" &&
              typeof (x as GraphColorGroup).query === "string" &&
              typeof (x as GraphColorGroup).color === "string",
          )
        : d.graphDefaults.colorGroups,
    },
    defaultRailTab: isRailTab(o.defaultRailTab) ? o.defaultRailTab : d.defaultRailTab,
  };
}

function read(): WikiSettings {
  try {
    const raw = localStorage.getItem(STORAGE_KEY);
    if (!raw) return DEFAULT_WIKI_SETTINGS;
    return coerce(JSON.parse(raw) as unknown);
  } catch {
    return DEFAULT_WIKI_SETTINGS;
  }
}

function write(next: WikiSettings): void {
  try {
    localStorage.setItem(STORAGE_KEY, JSON.stringify(next));
  } catch {
    /* quota / private mode — non-fatal, state stays in memory */
  }
  if (typeof window !== "undefined") window.dispatchEvent(new CustomEvent(CHANGE_EVENT));
}

/**
 * Flip `editorLivePreview` in the persisted settings and broadcast so every
 * `useWikiSettings` consumer (the editor, the modal) updates. Callable from
 * outside React — used by the command-palette "Toggle live preview" command.
 * Returns the new value.
 */
export function toggleLivePreviewSetting(): boolean {
  const cur = read();
  const next = { ...cur, editorLivePreview: !cur.editorLivePreview };
  write(next);
  return next.editorLivePreview;
}

export interface UseWikiSettings {
  /** The current, fully-populated preferences. */
  settings: WikiSettings;
  /** Patch one or more top-level fields and persist. */
  update: (patch: Partial<WikiSettings>) => void;
  /** Patch a single graph default and persist. */
  updateGraph: <K extends keyof GraphSettings>(key: K, value: GraphSettings[K]) => void;
  /** Reset everything back to {@link DEFAULT_WIKI_SETTINGS}. */
  reset: () => void;
}

/**
 * Read + persist wiki UI preferences. Safe to mount from any component: the
 * modal writes through `update`, and read-only consumers (editor, reading view,
 * graph) get live updates via the same-tab CHANGE_EVENT and the cross-tab
 * `storage` event.
 */
export function useWikiSettings(): UseWikiSettings {
  const [settings, setSettings] = React.useState<WikiSettings>(() =>
    typeof window === "undefined" ? DEFAULT_WIKI_SETTINGS : read(),
  );

  React.useEffect(() => {
    const onStorage = (e: StorageEvent) => {
      if (e.key !== null && e.key !== STORAGE_KEY) return;
      setSettings(read());
    };
    const onLocalChange = () => setSettings(read());
    window.addEventListener("storage", onStorage); // cross-tab
    window.addEventListener(CHANGE_EVENT, onLocalChange); // same-tab
    return () => {
      window.removeEventListener("storage", onStorage);
      window.removeEventListener(CHANGE_EVENT, onLocalChange);
    };
  }, []);

  const update = React.useCallback((patch: Partial<WikiSettings>) => {
    setSettings((prev) => {
      const next = { ...prev, ...patch };
      write(next);
      return next;
    });
  }, []);

  const updateGraph = React.useCallback(
    <K extends keyof GraphSettings>(key: K, value: GraphSettings[K]) => {
      setSettings((prev) => {
        const next = { ...prev, graphDefaults: { ...prev.graphDefaults, [key]: value } };
        write(next);
        return next;
      });
    },
    [],
  );

  const reset = React.useCallback(() => {
    setSettings(DEFAULT_WIKI_SETTINGS);
    write(DEFAULT_WIKI_SETTINGS);
  }, []);

  return { settings, update, updateGraph, reset };
}
