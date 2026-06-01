import * as React from "react";

export type ThemeMode = "light" | "dark" | "system";

const STORAGE_KEY = "dim-shadcn:theme";

function apply(mode: ThemeMode) {
  const root = document.documentElement;
  const resolved =
    mode === "system"
      ? window.matchMedia("(prefers-color-scheme: dark)").matches
        ? "dark"
        : "light"
      : mode;
  root.classList.toggle("dark", resolved === "dark");
  root.dataset.theme = resolved;
}

export function readStoredTheme(): ThemeMode {
  // Default to following the OS, matching the original Codex desktop default.
  return (localStorage.getItem(STORAGE_KEY) as ThemeMode | null) ?? "system";
}

export function initTheme() {
  apply(readStoredTheme());
}

export function useTheme(): [ThemeMode, (m: ThemeMode) => void] {
  const [mode, setMode] = React.useState<ThemeMode>(() => readStoredTheme());
  React.useEffect(() => {
    apply(mode);
    localStorage.setItem(STORAGE_KEY, mode);
  }, [mode]);
  React.useEffect(() => {
    if (mode !== "system") return;
    const mq = window.matchMedia("(prefers-color-scheme: dark)");
    const handler = () => apply("system");
    mq.addEventListener("change", handler);
    return () => mq.removeEventListener("change", handler);
  }, [mode]);
  return [mode, setMode];
}
