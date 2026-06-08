import * as React from "react";
import { Save, X, Eye, Pencil } from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { toast } from "@/components/ui/sonner";
import { cn } from "@/lib/utils";
import { WikiMarkdown } from "@/components/wiki/WikiMarkdown";
import { CodeMirrorEditor } from "./CodeMirrorEditor";

interface Props {
  /** Existing page to edit; omit for a new (blank) page. */
  pageId?: string;
  /** Called with the saved page id (created or updated). */
  onSaved?: (id: string) => void;
  onCancel?: () => void;
}

type Mode = "edit" | "preview";

/**
 * Wiki page editor: an inline title + a CM6 markdown body with a Save / Cancel
 * / Edit-Preview toolbar. Status-gated like the rest of the wiki surface — load
 * waits for the connected handshake, and `saveWikiPage` is optional on the
 * Connector (the mock omits it), so Save is disabled when it isn't wired.
 *
 * Create vs. edit: with no `pageId` we start blank; saving creates the page and
 * reports the new id via onSaved (the host navigates to it). With a `pageId` we
 * load the existing page and overwrite it on save.
 */
export function WikiEditor({ pageId, onSaved, onCancel }: Props) {
  const { connector, status } = useRuntime();
  const connected = status.kind === "connected";
  const canSave = connected && typeof connector.saveWikiPage === "function";

  const [title, setTitle] = React.useState("");
  const [body, setBody] = React.useState("");
  const [mode, setMode] = React.useState<Mode>("edit");
  const [loading, setLoading] = React.useState(false);
  const [saving, setSaving] = React.useState(false);
  const [dirty, setDirty] = React.useState(false);

  // Load the existing page (edit mode). New-page mode resets to a blank draft.
  React.useEffect(() => {
    if (!pageId || !connector.getWikiPage || !connected) {
      if (!pageId) {
        setTitle("");
        setBody("");
        setDirty(false);
      }
      return;
    }
    let alive = true;
    setLoading(true);
    connector
      .getWikiPage(pageId)
      .then((p) => {
        if (!alive) return;
        setTitle(p?.title ?? "");
        setBody(p?.content ?? "");
        setDirty(false);
      })
      .catch(() => {
        if (alive) toast.error("Failed to load page");
      })
      .finally(() => {
        if (alive) setLoading(false);
      });
    return () => {
      alive = false;
    };
  }, [connector, connected, pageId]);

  // Skip trailing setState after unmount (slow save + navigate-away).
  const aliveRef = React.useRef(true);
  React.useEffect(() => () => { aliveRef.current = false; }, []);

  const save = React.useCallback(async () => {
    // Single source of truth for the gate (button + keyboard agree).
    if (!canSave || saving || !dirty || !connector.saveWikiPage) return;
    setSaving(true);
    try {
      const res = await connector.saveWikiPage({ id: pageId, title: title.trim(), body });
      if (!aliveRef.current) return;
      if (!res) {
        toast.error("Save failed");
        return;
      }
      setDirty(false);
      toast.success(pageId ? "Page saved" : "Page created");
      onSaved?.(res.id);
    } catch (err) {
      if (aliveRef.current) toast.error(err instanceof Error ? err.message : "Save failed");
    } finally {
      if (aliveRef.current) setSaving(false);
    }
  }, [canSave, connector, saving, dirty, pageId, title, body, onSaved]);

  // Cmd/Ctrl-S saves — but only intercept the browser shortcut when a save is
  // actually possible, so it isn't silently swallowed when nothing can save.
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (!((e.metaKey || e.ctrlKey) && e.key.toLowerCase() === "s")) return;
      if (!canSave || !dirty || saving || mode === "preview") return;
      e.preventDefault();
      void save();
    };
    document.addEventListener("keydown", onKey);
    return () => document.removeEventListener("keydown", onKey);
  }, [save, canSave, dirty, saving, mode]);

  const onTitleChange = (v: string) => {
    setTitle(v);
    setDirty(true);
  };
  const onBodyChange = (v: string) => {
    setBody(v);
    setDirty(true);
  };

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      {/* Toolbar */}
      <div className="flex shrink-0 items-center gap-2 border-b border-[color:var(--border)] px-4 py-2">
        <div className="flex items-center gap-1">
          <Button
            variant={mode === "edit" ? "outlineActive" : "outline"}
            size="xs"
            onClick={() => setMode("edit")}
            aria-pressed={mode === "edit"}
          >
            <Pencil className="size-3.5" />
            Edit
          </Button>
          <Button
            variant={mode === "preview" ? "outlineActive" : "outline"}
            size="xs"
            onClick={() => setMode("preview")}
            aria-pressed={mode === "preview"}
          >
            <Eye className="size-3.5" />
            Preview
          </Button>
        </div>
        <div className="ml-auto flex items-center gap-2">
          {onCancel && (
            <Button variant="ghost" size="xs" onClick={onCancel}>
              <X className="size-3.5" />
              Cancel
            </Button>
          )}
          <Button
            variant="default"
            size="xs"
            onClick={() => void save()}
            disabled={!canSave || !dirty || saving}
            loading={saving}
            title={canSave ? undefined : "Saving is not available with this connection"}
          >
            {!saving && <Save className="size-3.5" />}
            Save
          </Button>
        </div>
      </div>

      {/* Title */}
      <div className="shrink-0 px-4 pt-4">
        <Input
          value={title}
          onChange={(e) => onTitleChange(e.currentTarget.value)}
          placeholder="Untitled"
          className="h-auto border-0 px-0 py-0 text-[22px] font-semibold tracking-tight shadow-none focus-visible:ring-0"
        />
      </div>

      {/* Body — editor or rendered preview */}
      <div className="min-h-0 flex-1 px-4 pb-4 pt-2">
        {loading ? (
          <div className="text-[13px] text-[color:var(--color-text-secondary)]">Loading…</div>
        ) : mode === "preview" ? (
          <div className="h-full overflow-auto">
            <WikiMarkdown content={body} />
          </div>
        ) : (
          <CodeMirrorEditor
            value={body}
            onChange={onBodyChange}
            className={cn("h-full rounded-md")}
          />
        )}
      </div>
    </div>
  );
}
