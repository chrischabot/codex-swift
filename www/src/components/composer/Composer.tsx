import * as React from "react";
import { Plus, ArrowUp, ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { cn } from "@/lib/utils";
import type { SendOptions } from "@/runtime/connector";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
  DropdownMenuSeparator,
} from "@/components/ui/dropdown-menu";
import {
  Tooltip,
  TooltipContent,
  TooltipTrigger,
} from "@/components/ui/tooltip";
import { WorkspaceChip } from "./WorkspaceChip";
import { useAppData, dispatch } from "@/state/store";
import {
  RichTextEditor,
  type RichTextEditorHandle,
  type CaretToken,
} from "./RichTextEditor";
import { MentionsPopover } from "./MentionsPopover";
import { SlashCommandsPopover } from "./SlashCommandsPopover";
import {
  ThreadGoalPanel,
  BackgroundSubagentsRow,
  type ThreadGoalPanelProps,
  type BackgroundSubagentsRowProps,
} from "./AboveComposerSurfaces";
import { toast } from "@/components/ui/sonner";

// Reasoning-effort tiers mirror the original composer model picker:
// Low / Medium / High / Extra High.
type ModelTier = "Low" | "Medium" | "High" | "Extra High";

interface ComposerProps {
  placeholder?: string;
  project?: string;
  approval?: "Full access" | "Approval required" | "Read only";
  modelLabel?: string;
  modelTier?: ModelTier;
  onSubmit?: (text: string, opts?: SendOptions) => void;
  /** Prop-gated above-composer thread-goal row (default off). */
  goal?: ThreadGoalPanelProps;
  /** Prop-gated above-composer background-subagents summary row (default off). */
  subagents?: BackgroundSubagentsRowProps;
}

export function Composer({
  placeholder = "Ask Codex to do anything",
  project = "diminuendo",
  approval = "Full access",
  modelLabel = "5.5",
  modelTier = "High",
  onSubmit,
  goal,
  subagents,
}: ComposerProps) {
  const [selectedApproval, setSelectedApproval] = React.useState(approval);
  const [selectedModel, setSelectedModel] = React.useState(
    `${modelLabel} ${modelTier}`,
  );
  const [text, setText] = React.useState("");
  const editorRef = React.useRef<RichTextEditorHandle | null>(null);
  const [token, setToken] = React.useState<CaretToken | null>(null);
  // Home-composer attachments: uploaded to the connector's "shared" bucket
  // (threadId=null) and adopted into the thread created on submit.
  const fileInputRef = React.useRef<HTMLInputElement | null>(null);
  const [attachments, setAttachments] = React.useState<string[]>([]);

  const uploadFiles = (files: File[]) => {
    for (const file of files) {
      setAttachments((a) => [...a, file.name]);
      dispatch.uploadFile(null, file)
        .then(() => toast(`Attached ${file.name}`))
        .catch(() => { setAttachments((a) => a.filter((n) => n !== file.name)); toast(`Upload failed: ${file.name}`); });
    }
  };

  const mentionsOpen = token?.trigger === "@";
  const slashOpen = token?.trigger === "/";

  const submit = () => {
    if (!text.trim()) return;
    const opts: SendOptions = {
      approval: selectedApproval === "Full access" ? "full-access"
        : selectedApproval === "Approval required" ? "approval-required" : "read-only",
      modelLabel: selectedModel.split(" ")[0],
      modelTier: selectedModel.split(" ").slice(1).join(" ") as SendOptions["modelTier"],
    };
    onSubmit?.(text, opts);
    editorRef.current?.clear();
    setText("");
    setToken(null);
    setAttachments([]);
  };

  const approvalDot =
    selectedApproval === "Full access"
      ? "bg-[color:var(--color-red-500)]"
      : selectedApproval === "Approval required"
        ? "bg-[color:var(--color-orange-500)]"
        : "bg-[color:var(--color-text-quaternary)]";
  const approvalText =
    selectedApproval === "Full access"
      ? "text-[color:var(--color-red-500)] hover:bg-[color:var(--color-red-500)]/8"
      : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]";

  return (
    <div className="w-full">
      {/* Prop-gated above-composer surfaces (default off). */}
      {goal && <ThreadGoalPanel {...goal} first={!subagents} />}
      {subagents && <BackgroundSubagentsRow {...subagents} first />}
      <div
        className={cn(
          "border border-[color:var(--border)] bg-background shadow-[var(--shadow-card)] transition-shadow focus-within:shadow-[var(--shadow-card-hover)]",
          goal || subagents ? "rounded-b-2xl" : "rounded-2xl",
        )}
      >
        <RichTextEditor
          ref={editorRef}
          value={text}
          onChange={setText}
          onSubmit={submit}
          onToken={setToken}
          popoverOpen={mentionsOpen || slashOpen}
          placeholder={placeholder}
          aria-label="Message composer"
        />
        {attachments.length > 0 && (
          <div className="flex flex-wrap gap-1.5 px-3 pb-1 pt-1">
            {attachments.map((n, i) => (
              <span key={i} className="inline-flex items-center gap-1 rounded-md border border-[color:var(--border)] px-2 py-0.5 text-[11.5px] text-[color:var(--color-text-secondary)]">
                {n}
                <button type="button" aria-label={`Remove ${n}`} onClick={() => setAttachments((a) => a.filter((_, j) => j !== i))} className="text-[color:var(--color-text-tertiary)] hover:text-foreground">×</button>
              </span>
            ))}
          </div>
        )}
        {/* Bottom controls */}
        <div className="flex items-center gap-2 px-2 pb-2">
          <input
            ref={fileInputRef}
            type="file"
            multiple
            className="hidden"
            onChange={(e) => { uploadFiles(Array.from(e.target.files ?? [])); e.target.value = ""; }}
          />
          <Button variant="ghost" size="iconSm" aria-label="Add attachment" className="text-[color:var(--color-text-secondary)]" onClick={() => fileInputRef.current?.click()}>
            <Plus />
          </Button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                type="button"
                className={cn(
                  "flex h-7 items-center gap-1.5 rounded-md px-2 text-base font-medium",
                  approvalText,
                )}
              >
                <span className={cn("size-1.5 rounded-full", approvalDot)} />
                {selectedApproval}
                <ChevronDown className="size-3 opacity-60" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="start" className="w-[220px]">
              <Tooltip>
                <TooltipTrigger asChild>
                  <DropdownMenuItem onSelect={() => setSelectedApproval("Full access")}>
                    <span className="size-1.5 rounded-full bg-[color:var(--color-red-500)]" /> Full access
                  </DropdownMenuItem>
                </TooltipTrigger>
                <TooltipContent side="right">
                  Codex can read, edit, and run commands without asking.
                </TooltipContent>
              </Tooltip>
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
            <DropdownMenuContent align="end" className="w-[200px]">
              <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Extra High")}>5.5 Extra High</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => setSelectedModel("5.5 High")}>5.5 High</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Medium")}>5.5 Medium</DropdownMenuItem>
              <DropdownMenuItem onSelect={() => setSelectedModel("5.5 Low")}>5.5 Low</DropdownMenuItem>
              <DropdownMenuSeparator />
              <DropdownMenuItem onSelect={() => setSelectedModel("4.6")}>4.6</DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>

          <Button
            size="iconSm"
            onClick={submit}
            aria-label="Send message"
            className="rounded-full bg-[color:var(--color-text-primary)] text-background hover:bg-[color:var(--color-text-primary)]/90 disabled:opacity-40"
            disabled={!text.trim()}
          >
            <ArrowUp />
          </Button>
        </div>
      </div>
      {/* Workspace chip under composer */}
      <div className="mt-2 flex items-center gap-1.5 px-1">
        <WorkspaceChip activeProjectId={projectIdForName(useAppData().projects, project)} />
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
  );
}

function projectIdForName(projects: { id: string; name: string }[], name?: string) {
  if (!name) return undefined;
  return projects.find((p) => p.name === name)?.id;
}
