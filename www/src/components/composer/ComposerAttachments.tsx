import { X, FileText, Image as ImageIcon, Paperclip, Loader2, AlertCircle } from "lucide-react";
import { cn } from "@/lib/utils";

export interface AttachmentDraft {
  id: string;
  name: string;
  size: number;
  kind: "file" | "image";
  /** Optional thumbnail/object URL for image attachments. */
  previewUrl?: string;
  /** Upload lifecycle — mirrors the original attachment upload flow. */
  status?: "uploading" | "ready" | "error";
}

interface Props {
  items: AttachmentDraft[];
  onRemove: (id: string) => void;
  className?: string;
}

export function ComposerAttachments({ items, onRemove, className }: Props) {
  if (items.length === 0) return null;
  return (
    <div className={cn("flex flex-wrap gap-1.5 border-b border-[color:var(--color-divider)] px-2 pb-2 pt-2", className)}>
      {items.map((a) =>
        a.kind === "image" ? (
          <ImageTile key={a.id} item={a} onRemove={onRemove} />
        ) : (
          <FileChip key={a.id} item={a} onRemove={onRemove} />
        ),
      )}
    </div>
  );
}

// Image attachments render as a 64px square thumbnail tile (size-16, rounded-lg)
// matching user-message-attachments.js, with the X overlaid in the corner.
function ImageTile({ item, onRemove }: { item: AttachmentDraft; onRemove: (id: string) => void }) {
  return (
    <div className="group relative size-16 overflow-hidden rounded-lg border border-[color:var(--border)] bg-[color:var(--color-surface-hover)]">
      {item.status === "uploading" ? (
        <div className="flex size-full items-center justify-center">
          <Loader2 className="size-4 animate-spin text-[color:var(--color-text-tertiary)]" />
        </div>
      ) : item.status === "error" ? (
        <div className="flex size-full items-center justify-center">
          <AlertCircle className="size-4 text-[color:var(--color-red-500)]" />
        </div>
      ) : item.previewUrl ? (
        <img src={item.previewUrl} alt={item.name} className="size-full rounded-md object-cover" />
      ) : (
        <div className="flex size-full items-center justify-center">
          <ImageIcon className="size-4 text-[color:var(--color-text-tertiary)]" />
        </div>
      )}
      <RemoveButton name={item.name} onClick={() => onRemove(item.id)} overlay />
    </div>
  );
}

function FileChip({ item, onRemove }: { item: AttachmentDraft; onRemove: (id: string) => void }) {
  return (
    <div className="group flex h-7 items-center gap-1.5 rounded-lg border border-[color:var(--border)] bg-background pl-2 pr-1 text-sm">
      {item.status === "uploading" ? (
        <Loader2 className="size-3.5 animate-spin text-[color:var(--color-text-tertiary)]" />
      ) : item.status === "error" ? (
        <AlertCircle className="size-3.5 text-[color:var(--color-red-500)]" />
      ) : (
        <FileText className="size-3.5 text-[color:var(--color-text-secondary)]" />
      )}
      <span className="max-w-[160px] truncate">{item.name}</span>
      {item.status === "error" ? (
        <span className="text-2xs text-[color:var(--color-red-500)]">Failed</span>
      ) : (
        <span className="text-2xs text-[color:var(--color-text-quaternary)]">{formatSize(item.size)}</span>
      )}
      <RemoveButton name={item.name} onClick={() => onRemove(item.id)} />
    </div>
  );
}

function RemoveButton({ name, onClick, overlay }: { name: string; onClick: () => void; overlay?: boolean }) {
  return (
    <button
      type="button"
      onClick={onClick}
      aria-label={`Remove attachment ${name}`}
      className={cn(
        "flex items-center justify-center rounded text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        overlay
          ? "absolute right-1 top-1 size-5 bg-background/80 opacity-0 group-hover:opacity-100"
          : "size-5",
      )}
    >
      <X className="size-2.5" />
    </button>
  );
}

export function ComposerDropOverlay({ visible }: { visible: boolean }) {
  if (!visible) return null;
  return (
    <div className="pointer-events-none absolute inset-0 z-10 flex items-center justify-center rounded-2xl border-2 border-dashed border-[color:var(--ring)] bg-[color:var(--accent)]/70 text-sm font-medium text-[color:var(--accent-foreground)]">
      <Paperclip className="mr-2 size-4" />
      Drop to attach
    </div>
  );
}

function formatSize(bytes: number) {
  if (bytes < 1024) return `${bytes} B`;
  if (bytes < 1024 * 1024) return `${(bytes / 1024).toFixed(1)} KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)} MB`;
}
