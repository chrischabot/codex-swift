import { useNavigate } from "react-router-dom";
import { useAppData, dispatch } from "@/state/store";
import { Button } from "@/components/ui/button";
import { Archive, MessageSquare } from "lucide-react";
import { formatRelative } from "@/lib/utils";
import { toast } from "@/components/ui/sonner";

export function ArchivePage() {
  const { threads } = useAppData();
  const navigate = useNavigate();
  const archived = threads.filter((t) => t.status === "archived");

  const unarchive = (id: string) => {
    dispatch.setThreadArchived(id, false);
    toast("Unarchived chat", {
      action: { label: "View now", onClick: () => navigate(`/thread/${id}`) },
    });
  };

  const remove = (id: string) => {
    if (!confirm("Permanently delete this archived chat? This cannot be undone.")) return;
    dispatch.deleteThread(id);
    toast("Deleted archived chat");
  };

  const removeAll = () => {
    if (archived.length === 0) return;
    if (!confirm("Permanently delete all archived chats? This cannot be undone.")) return;
    archived.forEach((t) => dispatch.deleteThread(t.id));
    toast("Deleting archived chats…");
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div className="text-[14px] font-medium">Archived chats</div>
        {archived.length > 0 && (
          <Button variant="ghost" size="xs" onClick={removeAll}>
            Delete all
          </Button>
        )}
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto px-4">
        <div className="mx-auto max-w-[720px] py-6">
          {archived.length === 0 ? (
            <div className="flex flex-col items-center justify-center pt-20 text-center text-[color:var(--color-text-tertiary)]">
              <Archive className="mb-3 size-8 text-[color:var(--color-text-quaternary)]" />
              <div className="text-[14px] font-medium text-foreground">Nothing archived</div>
              <div className="mt-1 text-[12.5px]">Right-click a chat in the sidebar and pick Archive to send it here.</div>
            </div>
          ) : (
            <ul className="rounded-lg border border-[color:var(--border)]">
              {archived.map((t) => (
                <li
                  key={t.id}
                  className="flex w-full items-center justify-between gap-3 px-4 py-3 hover:bg-[color:var(--color-surface-hover)]"
                >
                  <button
                    onClick={() => navigate(`/thread/${t.id}`)}
                    className="min-w-0 flex-1 text-left text-[color:var(--color-text-primary)]"
                  >
                    <div className="flex min-w-0 items-center gap-2 text-base font-medium">
                      <MessageSquare className="size-4 shrink-0 text-[color:var(--color-text-tertiary)]" />
                      <span className="truncate">{t.title.trim() || "Untitled chat"}</span>
                    </div>
                    <div className="mt-1 flex min-w-0 flex-col gap-0.5 text-sm">
                      <div className="truncate text-[color:var(--color-text-secondary)]">
                        {formatRelative(t.updatedAt)}
                      </div>
                    </div>
                  </button>
                  <div className="flex shrink-0 items-center gap-1.5">
                    <Button variant="secondary" size="xs" onClick={() => unarchive(t.id)}>
                      Unarchive
                    </Button>
                    <Button variant="ghost" size="xs" onClick={() => remove(t.id)}>
                      Delete
                    </Button>
                  </div>
                </li>
              ))}
            </ul>
          )}
        </div>
      </div>
    </div>
  );
}
