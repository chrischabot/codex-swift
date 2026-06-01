import * as React from "react";

// Minimal ANSI SGR (Select Graphic Rendition) parser. Terminal output captured
// from exec tool calls frequently carries CSI color escapes (e.g. `\x1b[31m`),
// which would otherwise show as garbage. We translate the SGR subset Codex
// actually emits — the 8 standard + 8 bright foreground colors, bold/dim,
// underline, and the reset/default codes — into styled <span>s. Colors map onto
// the shared chart palette tokens (--color-charts-*) so they track the theme.
// Unknown / cursor-movement escapes are dropped rather than rendered raw.

interface SgrStyle {
  color?: string;
  bold?: boolean;
  dim?: boolean;
  underline?: boolean;
}

// Foreground SGR code → CSS var. Bright variants (90-97) collapse onto the same
// palette since the token set has a single shade per hue.
const FG: Record<number, string> = {
  30: "var(--color-text-primary)", // black → primary text (visible on dark+light)
  31: "var(--color-charts-red)",
  32: "var(--color-charts-green)",
  33: "var(--color-charts-orange)", // yellow
  34: "var(--color-charts-blue)",
  35: "var(--color-charts-purple)", // magenta
  36: "var(--color-charts-blue)", // cyan → blue (no cyan token)
  37: "var(--color-text-secondary)", // white/grey
  90: "var(--color-text-tertiary)", // bright black / grey
  91: "var(--color-charts-red)",
  92: "var(--color-charts-green)",
  93: "var(--color-charts-orange)",
  94: "var(--color-charts-blue)",
  95: "var(--color-charts-purple)",
  96: "var(--color-charts-blue)",
  97: "var(--color-text-primary)",
};

// Matches a CSI sequence: ESC [ <params> <final-byte>. We only act on the SGR
// final byte `m`; other finals (cursor moves, erase, etc.) are matched so they
// can be stripped.
const CSI = new RegExp("\\u001b\\[([0-9;?]*)([A-Za-z])", "g");

function applyCodes(style: SgrStyle, params: string): SgrStyle {
  // Empty params == "0" (reset).
  const codes = params.length === 0 ? [0] : params.split(";").map((p) => Number(p) || 0);
  let next: SgrStyle = { ...style };
  for (let i = 0; i < codes.length; i++) {
    const c = codes[i];
    if (c === 0) {
      next = {};
    } else if (c === 1) {
      next.bold = true;
    } else if (c === 2) {
      next.dim = true;
    } else if (c === 4) {
      next.underline = true;
    } else if (c === 22) {
      next.bold = false;
      next.dim = false;
    } else if (c === 24) {
      next.underline = false;
    } else if (c === 39) {
      delete next.color;
    } else if (FG[c]) {
      next.color = FG[c];
    } else if (c === 38) {
      // 256-color / truecolor extended foreground: 38;5;N or 38;2;R;G;B.
      if (codes[i + 1] === 5) {
        i += 2; // consume mode + index (best-effort: leave default color)
      } else if (codes[i + 1] === 2) {
        const [, , r, g, b] = codes.slice(i);
        if (r != null && g != null && b != null) next.color = `rgb(${r}, ${g}, ${b})`;
        i += 4;
      }
    }
    // Background codes (40-49, 48) and others are ignored.
  }
  return next;
}

function styleToCss(s: SgrStyle): React.CSSProperties | undefined {
  const css: React.CSSProperties = {};
  if (s.color) css.color = s.color;
  if (s.bold) css.fontWeight = 600;
  if (s.dim) css.opacity = 0.7;
  if (s.underline) css.textDecoration = "underline";
  return Object.keys(css).length > 0 ? css : undefined;
}

// Parse ANSI text into an array of React nodes (styled <span>s + plain strings).
export function ansiToSpans(input: string): React.ReactNode[] {
  const nodes: React.ReactNode[] = [];
  let style: SgrStyle = {};
  let lastIndex = 0;
  let key = 0;

  const push = (text: string) => {
    if (text.length === 0) return;
    const css = styleToCss(style);
    if (css) {
      nodes.push(
        <span key={key++} style={css}>
          {text}
        </span>,
      );
    } else {
      nodes.push(text);
    }
  };

  CSI.lastIndex = 0;
  let match: RegExpExecArray | null;
  while ((match = CSI.exec(input)) !== null) {
    // Emit text preceding this escape with the current style.
    push(input.slice(lastIndex, match.index));
    lastIndex = CSI.lastIndex;
    // Only SGR (`m`) changes style; other CSI sequences are stripped.
    if (match[2] === "m") {
      style = applyCodes(style, match[1]);
    }
  }
  push(input.slice(lastIndex));
  return nodes;
}
