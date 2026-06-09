import * as React from "react";
import { Trash2 } from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Button } from "@/components/ui/button";
import { toast } from "@/components/ui/sonner";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogFooter,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";

interface Props {
  pageId: string;
  /** Page title, shown in the confirm dialog. */
  title?: string;
  /** Called after a successful delete (host typically navigates away). */
  onDeleted?: () => void;
  className?: string;
}

/**
 * Destructive "delete this page" control. Deleting a wiki page routes through
 * `wiki/page/delete`, which purges the document plus its derived chunks and the
 * FTS/vec index rows (a raw delete would orphan them). Gated like the rest of
 * the edit surface — hidden unless the connector exposes deleteWikiPage. A
 * confirm dialog guards the irreversible action (there is no trash/undo).
 */
export function DeletePageButton({ pageId, title, onDeleted, className }: Props) {
  const { connector, status } = useRuntime();
  const canDelete = status.kind === "connected" && typeof connector.deleteWikiPage === "function";
  const [open, setOpen] = React.useState(false);
  const [busy, setBusy] = React.useState(false);

  if (!canDelete) return null;

  const doDelete = async () => {
    if (!connector.deleteWikiPage || busy) return;
    setBusy(true);
    try {
      const res = await connector.deleteWikiPage(pageId);
      if (res === null) {
        toast.error("Delete failed");
        return;
      }
      toast.success(res.deleted ? "Page deleted" : "Page was already gone");
      setOpen(false);
      onDeleted?.();
    } catch (err) {
      toast.error(err instanceof Error ? err.message : "Delete failed");
    } finally {
      setBusy(false);
    }
  };

  return (
    <>
      <Button
        variant="outline"
        size="xs"
        onClick={() => setOpen(true)}
        aria-label="Delete page"
        title="Delete page"
        className={className}
      >
        <Trash2 className="size-3" />
      </Button>
      <Dialog open={open} onOpenChange={(o) => !busy && setOpen(o)}>
        <DialogContent className="sm:max-w-[420px]">
          <DialogHeader>
            <DialogTitle>Delete page?</DialogTitle>
            <DialogDescription>
              {title ? `“${title}” ` : "This page "}
              and its search-index entries will be permanently removed. This can’t be undone.
            </DialogDescription>
          </DialogHeader>
          <DialogFooter>
            <Button variant="ghost" size="sm" disabled={busy} onClick={() => setOpen(false)}>
              Cancel
            </Button>
            <Button variant="destructive" size="sm" loading={busy} onClick={() => void doDelete()}>
              {!busy && <Trash2 className="mr-1 size-3.5" />}
              Delete
            </Button>
          </DialogFooter>
        </DialogContent>
      </Dialog>
    </>
  );
}
