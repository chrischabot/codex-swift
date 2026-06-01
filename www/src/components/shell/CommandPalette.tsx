import * as React from "react";
import { Command } from "cmdk";
import { useNavigate, useParams } from "react-router-dom";
import { useAppData, dispatch } from "@/state/store";
import { Dialog, DialogContent, DialogTitle, DialogDescription } from "@/components/ui/dialog";
import { Search } from "lucide-react";
import { toast } from "@/components/ui/sonner";
import { usePalette } from "./PaletteContext";

// kbd chip mirroring the original webview/tooltip.js `g` component:
//   inline-flex !rounded-md !border-0 !bg-current/10 !font-sans !text-xs
//   !text-current !shadow-none  (with !px-1.5 !py-0.5 !leading-none)
function Kbd({ children }: { children: React.ReactNode }) {
  return (
    <kbd className="inline-flex items-center rounded-md border-0 bg-current/10 px-1.5 py-0.5 font-sans text-xs leading-none text-current shadow-none">
      {children}
    </kbd>
  );
}

const itemClass =
  "flex h-8 items-center gap-2 rounded-md px-2 text-[13px] aria-selected:bg-[color:var(--color-surface-hover)]";

export function CommandPalette() {
  const { open, setOpen } = usePalette();
  const navigate = useNavigate();
  const params = useParams();
  const { projects, threads } = useAppData();
  const [q, setQ] = React.useState("");

  const currentThreadId = params.threadId as string | undefined;
  const currentThread = currentThreadId
    ? threads.find((t) => t.id === currentThreadId)
    : undefined;

  const close = () => setOpen(false);
  const go = (path: string) => {
    close();
    navigate(path);
  };
  const run = (fn: () => void) => {
    close();
    fn();
  };

  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogContent className="max-w-[560px] p-0" showClose={false}>
        <DialogTitle className="sr-only">Command menu</DialogTitle>
        <DialogDescription className="sr-only">Search chats, navigate, and run commands</DialogDescription>
        <Command label="Command menu">
          <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] px-3">
            <Search className="size-4 text-[color:var(--color-text-tertiary)]" />
            <Command.Input
              value={q}
              onValueChange={setQ}
              placeholder="Search commands…"
              className="h-11 flex-1 bg-transparent outline-none"
            />
          </div>
          <Command.List className="max-h-[400px] overflow-y-auto p-2">
            <Command.Empty className="px-3 py-6 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
              No matching commands
            </Command.Empty>

            {/* Action commands grouped to mirror the original command menu's
                commandMenuGroupKey taxonomy: thread / panels / configure. */}
            <Command.Group heading="Chat">
              <Command.Item
                onSelect={() => go(`/home/${projects[0]?.id ?? "p-diminuendo"}`)}
                className={itemClass}
              >
                <span className="flex-1 truncate">New chat</span>
                <Kbd>⌘N</Kbd>
              </Command.Item>
              {currentThread ? (
                <>
                  <Command.Item
                    onSelect={() =>
                      run(() => {
                        dispatch.setThreadPinned(currentThread.id, !currentThread.pinned);
                        toast(currentThread.pinned ? "Unpinned chat" : "Pinned chat");
                      })
                    }
                    className={itemClass}
                  >
                    <span className="flex-1 truncate">
                      {currentThread.pinned ? "Unpin chat" : "Pin chat"}
                    </span>
                    <Kbd>⌥⌘P</Kbd>
                  </Command.Item>
                  <Command.Item
                    onSelect={() =>
                      run(() => {
                        dispatch.setThreadArchived(currentThread.id, true);
                        toast("Archived chat", {
                          action: {
                            label: "Undo",
                            onClick: () => dispatch.setThreadArchived(currentThread.id, false),
                          },
                        });
                      })
                    }
                    className={itemClass}
                  >
                    <span className="flex-1 truncate">Archive chat</span>
                    <Kbd>⌘⇧A</Kbd>
                  </Command.Item>
                </>
              ) : null}
            </Command.Group>

            <Command.Group heading="View">
              <Command.Item onSelect={() => go("/settings")} className={itemClass}>
                <span className="flex-1 truncate">Settings</span>
                <Kbd>⌘,</Kbd>
              </Command.Item>
              <Command.Item onSelect={() => go("/plugins")} className={itemClass}>
                <span className="flex-1 truncate">Plugins</span>
              </Command.Item>
              <Command.Item onSelect={() => go("/automations")} className={itemClass}>
                <span className="flex-1 truncate">Automations</span>
              </Command.Item>
              <Command.Item onSelect={() => go("/archive")} className={itemClass}>
                <span className="flex-1 truncate">Archived chats</span>
              </Command.Item>
            </Command.Group>

            {/* Navigation targets (net-new search affordance kept from the
                reimplementation). */}
            <Command.Group heading="Projects">
              {projects.map((p) => (
                <Command.Item
                  key={p.id}
                  onSelect={() => go(`/home/${p.id}`)}
                  className={itemClass}
                >
                  {p.name}
                </Command.Item>
              ))}
            </Command.Group>
            <Command.Group heading="Chats">
              {threads.map((t) => (
                <Command.Item
                  key={t.id}
                  onSelect={() => go(`/thread/${t.id}`)}
                  className={itemClass}
                >
                  {t.title}
                </Command.Item>
              ))}
            </Command.Group>
          </Command.List>
        </Command>
      </DialogContent>
    </Dialog>
  );
}
