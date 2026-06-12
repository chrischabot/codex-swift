// M29 hotkey dispatcher — turns a command's display accelerator hint (e.g.
// "⌘⇧F", "⌘O", "⌘/") into a structured chord and matches it against a
// KeyboardEvent. The registry already carries these hints for the palette; the
// dispatcher (useWikiCommands) parses them so the SAME string both displays and
// binds — no second source of truth. Also accepts textual forms ("Mod+Shift+F",
// "Cmd+O") for robustness.

export interface Hotkey {
  /** ⌘ / Cmd / Mod — satisfied by either Meta or Ctrl (cross-platform). */
  mod: boolean;
  shift: boolean;
  alt: boolean;
  /** Explicit Ctrl (⌃) — distinct from `mod`. Rarely used. */
  ctrl: boolean;
  /** Single normalized (lowercased) key, e.g. "f", "/", "enter". Empty = invalid. */
  key: string;
}

const TOKEN: Record<string, keyof Hotkey | undefined> = {
  "⌘": "mod",
  cmd: "mod",
  command: "mod",
  mod: "mod",
  meta: "mod",
  "⇧": "shift",
  shift: "shift",
  "⌥": "alt",
  alt: "alt",
  option: "alt",
  opt: "alt",
  "⌃": "ctrl",
  ctrl: "ctrl",
  control: "ctrl",
};

/** Parse an accelerator hint into a chord. Returns null when no key is found. */
export function parseHotkey(hint: string): Hotkey | null {
  if (!hint) return null;
  const h: Hotkey = { mod: false, shift: false, alt: false, ctrl: false, key: "" };
  // Tokens are either +-delimited words ("Cmd+Shift+F") or bare symbol runs
  // ("⌘⇧F"). Split on "+" first; then peel modifier symbols off each piece.
  const pieces = hint.includes("+") ? hint.split("+") : [hint];
  for (let piece of pieces) {
    piece = piece.trim();
    // Peel leading single-char modifier symbols (⌘⇧⌥⌃) off a glued run.
    while (piece.length > 1 && TOKEN[piece[0]]) {
      h[TOKEN[piece[0]]!] = true as never;
      piece = piece.slice(1);
    }
    const word = piece.toLowerCase();
    const mod = TOKEN[word];
    if (mod) {
      h[mod] = true as never;
    } else if (word.length > 0) {
      h.key = word; // last non-modifier token wins as the key
    }
  }
  return h.key ? h : null;
}

/** Does `e` match the parsed chord? `mod` matches Meta OR Ctrl. */
export function matchesHotkey(e: KeyboardEvent, h: Hotkey): boolean {
  const modPressed = e.metaKey || e.ctrlKey;
  if (h.mod && !modPressed) return false;
  if (!h.mod && !h.ctrl && modPressed) return false; // bare key, but mod held
  if (h.ctrl && !e.ctrlKey) return false;
  if (h.shift !== e.shiftKey) return false;
  if (h.alt !== e.altKey) return false;
  return e.key.toLowerCase() === h.key;
}

// Modifier symbols, in display order, matching the registry hint convention
// (⌘ first, e.g. "⌘⇧F"). parseHotkey is order-agnostic, but keeping the same
// order means a captured chord renders identically to a built-in.
const MOD_SYMBOLS: Array<[keyof KeyboardEvent, string]> = [
  ["metaKey", "⌘"],
  ["ctrlKey", "⌃"],
  ["altKey", "⌥"],
  ["shiftKey", "⇧"],
];

/** Pretty-printed names for non-printable keys captured during rebinding. */
const KEY_LABEL: Record<string, string> = {
  " ": "Space",
  arrowup: "↑",
  arrowdown: "↓",
  arrowleft: "←",
  arrowright: "→",
  escape: "Esc",
  enter: "↵",
  backspace: "⌫",
  delete: "⌦",
  tab: "⇥",
};

/**
 * Format a KeyboardEvent into a display accelerator hint (e.g. "⌘⇧F"), the same
 * dialect parseHotkey reads — so a captured chord round-trips through the
 * dispatcher. Returns null when the event is a bare modifier press (no real
 * key yet) so the capture UI can keep waiting.
 */
export function formatHotkey(e: KeyboardEvent): string | null {
  const key = e.key;
  if (key === "Control" || key === "Alt" || key === "Shift" || key === "Meta") return null;
  let out = "";
  for (const [prop, sym] of MOD_SYMBOLS) if (e[prop]) out += sym;
  const lower = key.toLowerCase();
  const label = KEY_LABEL[lower] ?? (key.length === 1 ? key.toUpperCase() : key);
  return out + label;
}

/** True when focus is in a text-entry surface, where bare-key chords (no mod)
 *  should NOT fire. Mod chords are allowed through. */
export function isEditableTarget(target: EventTarget | null): boolean {
  const el = target as HTMLElement | null;
  if (!el || !el.tagName) return false;
  const tag = el.tagName.toLowerCase();
  return tag === "input" || tag === "textarea" || tag === "select" || el.isContentEditable;
}
