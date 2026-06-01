import * as React from "react";
import { cn } from "@/lib/utils";
import spritesheet from "@/assets/codex-spritesheet-v4.webp";

// Animation states, mirroring the original `j` state map in codex-avatar.js.
export type CodexAvatarState =
  | "idle"
  | "running"
  | "running-left"
  | "running-right"
  | "review"
  | "waving"
  | "waiting"
  | "jumping"
  | "failed";

// Mascot skins, mirroring the original `L` skin map. Only the "codex" skin ships
// a bundled spritesheet here; the other ids are accepted (additive API) and
// fall back to the codex sheet so callers don't have to gate on availability.
export type CodexAvatarSkin =
  | "codex"
  | "bsod"
  | "dewey"
  | "fireball"
  | "null-signal"
  | "rocky"
  | "seedy"
  | "stacky";

interface Props {
  /** Rendered width in px (height follows the 192/208 aspect ratio). */
  size?: number;
  className?: string;
  /** Mascot skin. Defaults to "codex". Unknown skins fall back to the codex sheet. */
  skin?: CodexAvatarSkin;
  /** Animation state. Defaults to "idle" (unchanged from the prior behavior). */
  state?: CodexAvatarState;
}

// Animated Codex mascot, mirroring output/webview/codex-avatar.js +
// codex-avatar-Bf_p5kK8.css. The asset is an 8-column x 9-row sprite sheet
// (background-size 800% 900%, image-rendering: pixelated, aspect-ratio
// 192/208). We step the background-position through the selected state's frame
// timing array. Respects prefers-reduced-motion (holds frame 0).
//
// COLS/ROWS come from the original E=8 (columns), D=9 (rows). The idle loop is
// the `k` timing array (row 0, columns 0..5 with per-frame durations); all other
// states are built with the same `P(row, count, baseDur, lastDur)` shape the
// original used (`j` map).
const COLS = 8;
const ROWS = 9;

interface Frame {
  row: number;
  col: number;
  durationMs: number;
}

// The hand-tuned idle loop (original `k`).
const IDLE_FRAMES: Frame[] = [
  { row: 0, col: 0, durationMs: 280 },
  { row: 0, col: 1, durationMs: 110 },
  { row: 0, col: 2, durationMs: 110 },
  { row: 0, col: 3, durationMs: 140 },
  { row: 0, col: 4, durationMs: 140 },
  { row: 0, col: 5, durationMs: 320 },
];

// P(row, count, baseDur, lastDur): a row of `count` frames, every frame `baseDur`
// except the final one `lastDur`. Mirrors the original P() builder.
function row(rowIndex: number, count: number, baseDur: number, lastDur: number): Frame[] {
  return Array.from({ length: count }, (_, i) => ({
    row: rowIndex,
    col: i,
    durationMs: i === count - 1 ? lastDur : baseDur,
  }));
}

// State → frame sequence, mirroring the original `j` map.
const STATES: Record<CodexAvatarState, Frame[]> = {
  idle: IDLE_FRAMES,
  failed: row(5, 8, 140, 240),
  jumping: row(4, 5, 140, 280),
  review: row(8, 6, 150, 280),
  running: row(7, 6, 120, 220),
  "running-left": row(2, 8, 120, 220),
  "running-right": row(1, 8, 120, 220),
  waving: row(3, 4, 140, 280),
  waiting: row(6, 6, 150, 260),
};

function framePosition(col: number, rowIndex: number): string {
  // background-size 800% 900%: each frame is 1/(COLS-1) / 1/(ROWS-1) of the
  // positioning range.
  const x = (col / (COLS - 1)) * 100;
  const y = (rowIndex / (ROWS - 1)) * 100;
  return `${x}% ${y}%`;
}

export function CodexAvatar({ size = 22, className, skin = "codex", state = "idle" }: Props) {
  const frames = STATES[state] ?? IDLE_FRAMES;
  const [frame, setFrame] = React.useState(0);

  // Reset to frame 0 whenever the state (and therefore the frame array) changes.
  React.useEffect(() => {
    setFrame(0);
  }, [state]);

  React.useEffect(() => {
    if (
      typeof window === "undefined" ||
      window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ) {
      return;
    }
    let timeout: number | undefined;
    let current = 0;
    const tick = () => {
      const next = (current + 1) % frames.length;
      current = next;
      setFrame(next);
      timeout = window.setTimeout(tick, frames[next].durationMs);
    };
    timeout = window.setTimeout(tick, frames[0].durationMs);
    return () => {
      if (timeout != null) window.clearTimeout(timeout);
    };
  }, [frames]);

  const f = frames[frame] ?? frames[0];
  const height = Math.round((size * 208) / 192);

  // Only the codex skin has a bundled sheet; other skins fall back to it.
  const sheet = spritesheet;

  return (
    <span
      className={cn("inline-block shrink-0 align-middle", className)}
      style={{
        width: size,
        height,
        // Lock the cell aspect ratio so the pixel grid stays square regardless
        // of size rounding.
        aspectRatio: "192 / 208",
        backgroundImage: `url(${sheet})`,
        backgroundRepeat: "no-repeat",
        backgroundSize: "800% 900%",
        backgroundPosition: framePosition(f.col, f.row),
        imageRendering: "pixelated",
      }}
      role="img"
      aria-label={skin === "codex" ? "Codex" : `Codex (${skin})`}
      data-skin={skin}
      data-state={state}
    />
  );
}
