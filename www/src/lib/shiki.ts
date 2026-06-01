// Lazy-initialised shiki highlighter. We create it once and reuse across all
// code blocks. Bundled langs cover the common cases used in chat output.
import type { Highlighter } from "shiki";

let promise: Promise<Highlighter> | null = null;

// Match Codex's default code theme (parsePatchFiles.js:151-152 registers
// github-dark-default / github-light-default as the GitHub default pair).
const LIGHT_THEME = "github-light-default";
const DARK_THEME = "github-dark-default";

const LANGS = [
  "bash",
  "shell",
  "json",
  "yaml",
  "toml",
  "tsx",
  "typescript",
  "javascript",
  "jsx",
  "python",
  "go",
  "rust",
  "swift",
  "java",
  "html",
  "css",
  "sql",
  "md",
  "diff",
] as const;

async function getHighlighter(): Promise<Highlighter> {
  if (!promise) {
    promise = (async () => {
      const { createHighlighter } = await import("shiki");
      return createHighlighter({ themes: [LIGHT_THEME, DARK_THEME], langs: LANGS as unknown as string[] });
    })();
  }
  return promise;
}

// Plain-text languages render with no grammar (matches the original, which
// treats plaintext as no-highlight rather than colouring it as a shell).
const PLAIN_LANGS = new Set(["text", "plaintext", "txt", ""]);

const normaliseLang = (lang: string): string => {
  const l = lang.toLowerCase();
  if (l === "sh" || l === "zsh") return "bash";
  if (l === "ts") return "typescript";
  if (l === "js") return "javascript";
  if (l === "py") return "python";
  if (l === "yml") return "yaml";
  return (LANGS as readonly string[]).includes(l) ? l : "bash";
};

export async function highlightToHtml(code: string, lang: string): Promise<string> {
  // Plain text gets no syntax colouring, just an escaped pre/code block.
  if (PLAIN_LANGS.has(lang.toLowerCase())) {
    return `<pre class="shiki"><code>${escapeHtml(code)}</code></pre>`;
  }
  const hl = await getHighlighter();
  const theme = document.documentElement.classList.contains("dark") ? DARK_THEME : LIGHT_THEME;
  try {
    return hl.codeToHtml(code, { lang: normaliseLang(lang), theme });
  } catch {
    return `<pre><code>${escapeHtml(code)}</code></pre>`;
  }
}

function escapeHtml(s: string): string {
  return s
    .replace(/&/g, "&amp;")
    .replace(/</g, "&lt;")
    .replace(/>/g, "&gt;");
}
