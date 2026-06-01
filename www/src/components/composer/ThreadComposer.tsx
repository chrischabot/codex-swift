import * as React from "react";
import { Plus, ArrowUp, ChevronDown, Image as ImageIcon, FileText, Link as LinkIcon, Square } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import {
  ComposerAttachments,
  ComposerDropOverlay,
  type AttachmentDraft,
} from "./ComposerAttachments";
import { MentionsPopover } from "./MentionsPopover";
import { SlashCommandsPopover } from "./SlashCommandsPopover";
import {
  RichTextEditor,
  type RichTextEditorHandle,
  type CaretToken,
} from "./RichTextEditor";
import {
  ThreadGoalPanel,
  BackgroundSubagentsRow,
  type ThreadGoalPanelProps,
  type BackgroundSubagentsRowProps,
} from "./AboveComposerSurfaces";
import { toast } from "@/components/ui/sonner";
import { dispatch } from "@/state/store";
import type { SendOptions } from "@/runtime/connector";
import { useModels } from "@/hooks/useModels";

// Reasoning-effort tiers mirror the original composer model picker:
// Low / Medium / High / Extra High.
type ModelTier = "Low" | "Medium" | "High" | "Extra High";

interface Props {
  placeholder?: string;
  approval?: "Full access" | "Approval required" | "Read only";
  modelLabel?: string;
  modelTier?: ModelTier;
  streaming?: boolean;        // when true, the send button becomes Stop
  /** Owning thread; uploads are staged + attached to its next turn. */
  threadId?: string;
  onSubmit?: (text: string, opts?: SendOptions) => void;
  onStop?: () => void;
  /** Prop-gated above-composer thread-goal row (default off). */
  goal?: ThreadGoalPanelProps;
  /** Prop-gated above-composer background-subagents summary row (default off). */
  subagents?: BackgroundSubagentsRowProps;
}

export function ThreadComposer({
  placeholder = "Ask for follow-up changes",
  approval = "Full access",
  modelLabel = "5.5",
  modelTier = "High",
  streaming = false,
  threadId,
  onSubmit,
  onStop,
  goal,
  subagents,
}: Props) {
  const [selectedApproval, setSelectedApproval] = React.useState(approval);
  const [selectedModel, setSelectedModel] = React.useState(
    `${modelLabel} ${modelTier}`,
  );
  const [text, setText] = React.useState("");
  const editorRef = React.useRef<RichTextEditorHandle | null>(null);
  const [attachments, setAttachments] = React.useState<AttachmentDraft[]>([]);
  const [dragOver, setDragOver] = React.useState(false);
  const [token, setToken] = React.useState<CaretToken | null>(null);

  const mentionsOpen = token?.trigger === "@";
  const slashOpen = token?.trigger === "/";
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);
  const models = useModels();

  const composerOpts = (): SendOptions => ({
    approval: selectedApproval === "Full access" ? "full-access"
      : selectedApproval === "Approval required" ? "approval-required" : "read-only",
    modelLabel: selectedModel.split(" ")[0],
    modelTier: selectedModel.split(" ").slice(1).join(" ") as SendOptions["modelTier"],
  });

  const submit = () => {
    if (!text.trim() && attachments.length === 0) return;
    // Attachments were uploaded on selection and are tracked by the connector
    // (per-thread pending), so they ride the next turn automatically.
    onSubmit?.(text, composerOpts());
    editorRef.current?.clear();
    setText("");
    setAttachments([]);
    setToken(null);
    requestAnimationFrame(() => editorRef.current?.focus());
  };

  // Upload each picked/dropped file to the gateway, tracking lifecycle on the
  // chip. The connector stages it and attaches it to the next turn.
  const uploadFiles = (files: File[]) => {
    for (const file of files) {
      const id = `${Date.now()}-${file.name}`;
      const kind = file.type.startsWith("image/") ? ("image" as const) : ("file" as const);
      setAttachments((p) => [...p, { id, name: file.name, size: file.size, kind, status: "uploading" }]);
      dispatch
        .uploadFile(threadId ?? null, file)
        .then((r) => setAttachments((p) => p.map((a) => (a.id === id ? { ...a, status: "ready", previewUrl: r.url } : a))))
        .catch(() => {
          setAttachments((p) => p.map((a) => (a.id === id ? { ...a, status: "error" } : a)));
          toast(`Upload failed: ${file.name}`);
        });
    }
  };

  const openPicker = (kind: "image" | "file") => {
    if (!fileInputRef.current) return;
    fileInputRef.current.accept = kind === "image" ? "image/*" : "";
    fileInputRef.current.click();
  };

  const onDrop = (ev: React.DragEvent) => {
    ev.preventDefault();
    setDragOver(false);
    uploadFiles(Array.from(ev.dataTransfer.files));
  };

  return (
    <>
    {/* Prop-gated above-composer surfaces (default off). */}
    {goal && <ThreadGoalPanel {...goal} first={!subagents} />}
    {subagents && <BackgroundSubagentsRow {...subagents} first />}
    <div
      className={cn(
        "relative border border-[color:var(--border)] bg-background shadow-[var(--shadow-card)] focus-within:shadow-[var(--shadow-card-hover)]",
        goal || subagents ? "rounded-b-2xl" : "rounded-2xl",
      )}
      onDragOver={(e) => {
        if (e.dataTransfer.types.includes("Files")) {
          e.preventDefault();
          setDragOver(true);
        }
      }}
      onDragLeave={() => setDragOver(false)}
      onDrop={onDrop}
    >
      <ComposerDropOverlay visible={dragOver} />
      <input
        ref={fileInputRef}
        type="file"
        multiple
        className="hidden"
        onChange={(e) => {
          uploadFiles(Array.from(e.target.files ?? []));
          e.target.value = "";
        }}
      />
      <ComposerAttachments items={attachments} onRemove={(id) => setAttachments((p) => p.filter((a) => a.id !== id))} />
      <RichTextEditor
        ref={editorRef}
        value={text}
        onChange={setText}
        onSubmit={submit}
        onToken={setToken}
        popoverOpen={mentionsOpen || slashOpen}
        placeholder={placeholder}
        aria-label="Follow-up composer"
      />
      <div className="flex items-center gap-2 px-2 pb-2">
        {/* NET-NEW (mock only): plus-menu attachment entry points. The original
            sources attachments from the workspace file picker / paste/drop. */}
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <Button variant="ghost" size="iconSm" aria-label="Add attachment" className="text-[color:var(--color-text-secondary)]">
              <Plus />
            </Button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start">
            <DropdownMenuItem onSelect={() => openPicker("file")}>
              <FileText /> Add file
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => openPicker("image")}>
              <ImageIcon /> Add image
            </DropdownMenuItem>
            <DropdownMenuSeparator />
            <DropdownMenuItem><LinkIcon /> From URL</DropdownMenuItem>
            <DropdownMenuItem>Open browser</DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button
              type="button"
              className={cn(
                "flex h-7 items-center gap-1.5 rounded-md px-2 text-base font-medium",
                selectedApproval === "Full access"
                  ? "text-[color:var(--color-red-500)] hover:bg-[color:var(--color-red-500)]/8"
                  : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]",
              )}
            >
              <span
                className={cn(
                  "size-1.5 rounded-full",
                  selectedApproval === "Full access"
                    ? "bg-[color:var(--color-red-500)]"
                    : selectedApproval === "Approval required"
                      ? "bg-[color:var(--color-orange-500)]"
                      : "bg-[color:var(--color-text-quaternary)]",
                )}
              />
              {selectedApproval}
              <ChevronDown className="size-3 opacity-60" />
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="start" className="w-[220px]">
            <DropdownMenuItem onSelect={() => setSelectedApproval("Full access")}>
              <span className="size-1.5 rounded-full bg-[color:var(--color-red-500)]" /> Full access
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setSelectedApproval("Approval required")}>
              <span className="size-1.5 rounded-full bg-[color:var(--color-orange-500)]" /> Approval required
            </DropdownMenuItem>
            <DropdownMenuItem onSelect={() => setSelectedApproval("Read only")}>
              <span className="size-1.5 rounded-full bg-[color:var(--color-text-quaternary)]" /> Read only
            </DropdownMenuItem>
          </DropdownMenuContent>
        </DropdownMenu>
        <div className="flex-1" />
        <DropdownMenu>
          <DropdownMenuTrigger asChild>
            <button
              type="button"
              className="flex h-7 items-center gap-1 rounded-md px-2 text-base font-medium text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
            >
              {selectedModel}
              <ChevronDown className="size-3 opacity-60" />
            </button>
          </DropdownMenuTrigger>
          <DropdownMenuContent align="end" className="w-[220px]">
            {models.length > 0
              ? models.flatMap((m) =>
                  (m.tiers.length ? m.tiers : ["High"]).map((tier) => (
                    <DropdownMenuItem key={`${m.label} ${tier}`} onSelect={() => setSelectedModel(`${m.label} ${tier}`)}>
                      {m.label} {tier}
                    </DropdownMenuItem>
                  )),
                )
              : (
                <>
                  <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Extra High")}>5.5 Extra High</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => setSelectedModel("5.5 High")}>5.5 High</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Medium")}>5.5 Medium</DropdownMenuItem>
                  <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Low")}>5.5 Low</DropdownMenuItem>
                  <DropdownMenuSeparator />
                  <DropdownMenuItem onSelect={() => setSelectedModel("4.6")}>4.6</DropdownMenuItem>
                </>
              )}
          </DropdownMenuContent>
        </DropdownMenu>
        {streaming ? (
          <Button
            size="iconSm"
            onClick={onStop}
            aria-label="Stop generating"
            className="rounded-full bg-[color:var(--color-text-primary)] text-background hover:bg-[color:var(--color-text-primary)]/90"
          >
            <Square className="!size-3 fill-current" />
          </Button>
        ) : (
          <Button
            size="iconSm"
            onClick={submit}
            aria-label="Send message"
            className="rounded-full bg-[color:var(--color-text-primary)] text-background hover:bg-[color:var(--color-text-primary)]/90 disabled:opacity-40"
            disabled={!text.trim() && attachments.length === 0}
          >
            <ArrowUp />
          </Button>
        )}
      </div>
      <MentionsPopover
        open={mentionsOpen}
        query={token?.query ?? ""}
        anchorEl={null}
        anchorRect={token?.rect ?? null}
        onPick={(label) => editorRef.current?.replaceToken(label, "@")}
        onClose={() => setToken(null)}
      />
      <SlashCommandsPopover
        open={slashOpen}
        query={token?.query ?? ""}
        anchorEl={null}
        anchorRect={token?.rect ?? null}
        onPick={(cmd) => {
          // NET-NEW (mock only): the original dispatches the slash command to the
          // controller; here we clear the token and surface a placeholder toast.
          editorRef.current?.removeToken();
          setText("");
          toast(`${cmd.name} — coming soon`);
        }}
        onClose={() => setToken(null)}
      />
    </div>
    </>
  );
}
