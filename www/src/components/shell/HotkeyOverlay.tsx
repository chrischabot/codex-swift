import * as React from "react";
import { Dialog, DialogContent, DialogHeader, DialogTitle } from "@/components/ui/dialog";
import { HOTKEYS, type HotkeySpec, type HotkeyGroup } from "./HotkeyManager";

let externalOpen: (v: boolean) => void = () => {};
let externalIsOpen = false;

export function openHotkeyOverlay() {
  externalOpen(!externalIsOpen);
}

// Group order + headings mirror the original command registry's
// commandMenuGroupKey taxonomy (thread / navigation / panels / configure).
const GROUP_ORDER: HotkeyGroup[] = ["thread", "navigation", "panels", "configure"];
const GROUP_LABELS: Record<HotkeyGroup, string> = {
  thread: "Chat",
  navigation: "Navigation",
  panels: "Panels",
  configure: "Configure",
};

// kbd chip mirroring webview/keyboard-shortcuts-settings.js (component `h`
// rendered with `!px-2 !py-1 !text-sm`): rounded chip, current/10 fill,
// no border, token-text-secondary.
function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center rounded-md border-0 bg-current/10 px-2 py-1 font-sans text-sm leading-none text-current shadow-none">
      {children}
    </kbd>
  );
}

export function HotkeyOverlay() {
  const [open, setOpen] = React.useState(false);
  React.useEffect(() => {
    externalOpen = setOpen;
    return () => {
      externalOpen = () => {};
    };
  }, []);
  React.useEffect(() => {
    externalIsOpen = open;
  }, [open]);

  const grouped = React.useMemo(() => {
    return GROUP_ORDER.map((group) => ({
      group,
      items: HOTKEYS.filter((h) => h.group === group),
    })).filter((g) => g.items.length > 0);
  }, []);

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent className="max-w-[480px]">
        <DialogHeader>
          <DialogTitle>Keyboard shortcuts</DialogTitle>
        </DialogHeader>
        <table className="w-full table-fixed border-collapse text-[13px]">
          <colgroup>
            <col />
            <col className="w-40" />
          </colgroup>
          <thead className="text-left text-[color:var(--color-text-tertiary)]">
            <tr className="border-b border-[color:var(--color-divider)]">
              <th className="px-1 py-2 font-medium">Command</th>
              <th className="px-1 py-2 font-medium">Keybinding</th>
            </tr>
          </thead>
          <tbody>
            {grouped.map(({ group, items }, gi) =>
              items.map((h: HotkeySpec, i) => (
                <tr
                  key={h.id}
                  className={
                    i === 0 && gi > 0
                      ? "border-t border-[color:var(--color-divider)] align-middle"
                      : "align-middle"
                  }
                >
                  <td className="px-1 py-2 text-[color:var(--color-text-primary)]">
                    {i === 0 ? (
                      <span className="mb-1 block text-[11px] uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
                        {GROUP_LABELS[group]}
                      </span>
                    ) : null}
                    {h.label}
                  </td>
                  <td className="px-1 py-2">
                    <span className="flex min-h-8 items-center gap-1 text-[color:var(--color-text-secondary)]">
                      {h.display ? <Kbd>{h.display}</Kbd> : "Unassigned"}
                    </span>
                  </td>
                </tr>
              )),
            )}
          </tbody>
        </table>
      </DialogContent>
    </Dialog>
  );
}
