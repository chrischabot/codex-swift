import { Toaster as SonnerToaster, toast } from "sonner";

// The original Codex ships a custom toast-signal system (toast-signal.js) with
// info / success / warning / danger levels rather than the `sonner` library.
// Sonner is an intentional replacement here; the per-level `classNames` below
// mirror the original severity treatments (green / amber / red) so success /
// warning / error toasts read the same. Placement could not be confirmed from
// the extracted CSS, so bottom-right is kept as the default anchor.
export function Toaster() {
  return (
    <SonnerToaster
      position="bottom-right"
      toastOptions={{
        classNames: {
          toast:
            "rounded-xl bg-[var(--popover)]/90 text-popover-foreground shadow-[var(--shadow-popover)] ring-[0.5px] ring-[color:var(--border)] backdrop-blur-sm",
          description: "text-[color:var(--color-text-secondary)]",
          actionButton: "bg-foreground text-background",
          cancelButton: "bg-[color:var(--color-surface-hover)]",
          success: "[&_[data-icon]]:text-[color:var(--color-green-500)]",
          warning: "[&_[data-icon]]:text-[color:var(--color-orange-500)]",
          error: "[&_[data-icon]]:text-[color:var(--color-red-500)]",
          info: "[&_[data-icon]]:text-[color:var(--color-text-secondary)]",
        },
      }}
    />
  );
}

export { toast };
