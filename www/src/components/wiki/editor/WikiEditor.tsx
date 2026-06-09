import * as React from "react";
import { EditorView } from "@codemirror/view";
import { Save, X, Eye, Pencil, Bold, Italic, Code, Link2, Heading2, Quote, List, Highlighter } from "lucide-react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { toast } from "@/components/ui/sonner";
import { Tooltip, TooltipContent, TooltipTrigger } from "@/components/ui/tooltip";
import { cn } from "@/lib/utils";
import { WikiMarkdown } from "@/components/wiki/WikiMarkdown";
import { CodeMirrorEditor } from "./CodeMirrorEditor";
import { livePreview } from "./livePreview";
import { wikiAutocomplete } from "./autocomplete";
import { editorExtensions } from "./extensions";
import {
  formattingKeymap,
  boldCommand,
  italicCommand,
  codeCommand,
  highlightCommand,
  wikilinkCommand,
  headingCommand,
  quoteCommand,
  bulletCommand,
} from "./formatting";
import { useWikiSettings } from "@/components/wiki/settings/useWikiSettings";
import "./livePreview.css";

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

  // Known page titles (for `[[` autocomplete + unresolved-link styling).
  const [knownTitles, setKnownTitles] = React.useState<Set<string>>(new Set());
  React.useEffect(() => {
    if (!connector.listWikiPages || !connected) return;
    let alive = true;
    connector.listWikiPages({ limit: 1000 })
      .then((ps) => { if (alive) setKnownTitles(new Set(ps.map((p) => p.title.toLowerCase()))); })
      .catch(() => {});
    return () => { alive = false; };
  }, [connector, connected]);

  const { settings } = useWikiSettings();
  // Handle to the live EditorView so the formatting toolbar can dispatch the
  // same commands the keymap binds.
  const viewRef = React.useRef<EditorView | null>(null);
  const runCmd = React.useCallback((cmd: (v: EditorView) => boolean) => {
    if (viewRef.current) cmd(viewRef.current);
  }, []);

  // CM6 extension bundle for the editor: Live Preview (render-as-you-type, when
  // enabled in settings) + formatting keymap (Cmd-B/I/`/K) + autocomplete
  // ([[ / # / /) + folding + multi-cursor. Memoized so the editor only
  // reconfigures when the providers/resolver/settings change.
  const cmExtensions = React.useMemo(() => [
    formattingKeymap,
    ...(settings.editorLivePreview
      ? [livePreview({ isLinkResolved: (t) => knownTitles.has(t.split(/[#|]/)[0].trim().toLowerCase()) })]
      : []),
    wikiAutocomplete({
      pages: async () => {
        if (!connector.listWikiPages) return [];
        const ps = await connector.listWikiPages({ limit: 1000 });
        return ps.map((p) => ({ id: p.id, title: p.title }));
      },
      tags: async () => {
        if (!connector.getWikiTags) return [];
        const t = await connector.getWikiTags();
        return t.map((x) => x.tag);
      },
    }),
    editorExtensions({ fold: true }),
  ], [connector, knownTitles, settings.editorLivePreview]);

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

      {/* Formatting toolbar (edit mode only). Buttons dispatch the SAME commands
          the keymap binds (Cmd-B/I/`/K), so keyboard + click stay in sync. */}
      {mode === "edit" && (
        <div className="flex shrink-0 flex-wrap items-center gap-0.5 border-b border-[color:var(--border)] px-3 py-1">
          <FormatButton label="Bold (⌘B)" onClick={() => runCmd(boldCommand)}><Bold className="size-3.5" /></FormatButton>
          <FormatButton label="Italic (⌘I)" onClick={() => runCmd(italicCommand)}><Italic className="size-3.5" /></FormatButton>
          <FormatButton label="Code (⌘`)" onClick={() => runCmd(codeCommand)}><Code className="size-3.5" /></FormatButton>
          <FormatButton label="Highlight (⌘⇧H)" onClick={() => runCmd(highlightCommand)}><Highlighter className="size-3.5" /></FormatButton>
          <div className="mx-1 h-4 w-px bg-[color:var(--border)]" />
          <FormatButton label="Wikilink (⌘K)" onClick={() => runCmd(wikilinkCommand)}><Link2 className="size-3.5" /></FormatButton>
          <FormatButton label="Heading" onClick={() => runCmd(headingCommand(2))}><Heading2 className="size-3.5" /></FormatButton>
          <FormatButton label="Quote" onClick={() => runCmd(quoteCommand)}><Quote className="size-3.5" /></FormatButton>
          <FormatButton label="Bullet list" onClick={() => runCmd(bulletCommand)}><List className="size-3.5" /></FormatButton>
        </div>
      )}

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
            extensions={cmExtensions}
            viewRef={viewRef}
            className={cn("h-full rounded-md")}
          />
        )}
      </div>
    </div>
  );
}

/** A square icon button in the formatting toolbar. mousedown is prevented so the
 *  editor keeps its selection when a button is clicked. */
function FormatButton({
  label,
  onClick,
  children,
}: {
  label: string;
  onClick: () => void;
  children: React.ReactNode;
}) {
  return (
    <Tooltip>
      <TooltipTrigger asChild>
        <button
          type="button"
          aria-label={label}
          onMouseDown={(e) => e.preventDefault()}
          onClick={onClick}
          className="inline-flex size-7 items-center justify-center rounded text-[color:var(--color-text-tertiary)] transition-colors hover:bg-[color:var(--color-surface-hover)] hover:text-foreground"
        >
          {children}
        </button>
      </TooltipTrigger>
      <TooltipContent>{label}</TooltipContent>
    </Tooltip>
  );
}
