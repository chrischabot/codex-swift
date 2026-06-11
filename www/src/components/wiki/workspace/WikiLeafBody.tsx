import * as React from "react";
import { useLocation } from "react-router-dom";
import { Pencil, FileText } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Settings as SettingsIcon } from "lucide-react";
import { ScrollArea } from "@/components/ui/scroll-area";
import { useWikiPage } from "@/state/wiki";
import { useRuntime } from "@/runtime/RuntimeProvider";
import { WikiEditor } from "@/components/wiki/editor/WikiEditor";
import { WikiReadingView } from "@/components/wiki/WikiReadingView";
import { WikiCanvasView } from "@/components/wiki/canvas/WikiCanvasView";
import { WikiBaseView } from "@/components/wiki/bases/WikiBaseView";
import { isCanvasDoc } from "@/components/wiki/canvas/canvasSchema";
import { isBaseBody } from "@/components/wiki/bases/basesSchema";
import { BookmarkButton } from "@/components/wiki/panels/BookmarkButton";
import { DeletePageButton } from "@/components/wiki/panels/DeletePageButton";
import type { Leaf } from "./wikiWorkspace";

export interface LeafBodyCallbacks {
  /** Resolve + open a wikilink target within THIS pane. */
  onWikiLink: (target: string) => void;
  onTag: (tag: string) => void;
  onJump: (slug: string) => void;
  resolveWikiLink: (title: string) => string | undefined;
  /** Navigate to an already-resolved in-app route (used by the source-editor
   *  Cmd/Ctrl+click and anything that already has a finished `/wiki/...` path).
   *  `newTab` opens it in a new browser tab. */
  onNavigatePath: (path: string, opts: { newTab: boolean }) => void;
  /** Open settings (gear). */
  onOpenSettings: () => void;
  /** Navigate the pane after a page is deleted / its body changes id. */
  onDeleted: () => void;
  /** Force the right rail (and anything keyed on it) to refetch after a save. */
  onPageSaved: (id: string) => void;
}

interface Props {
  leaf: Leaf;
  isActive: boolean;
  callbacks: LeafBodyCallbacks;
}

/**
 * Renders ONE workspace leaf's content. An empty leaf shows a placeholder; a
 * page leaf fetches its body and dispatches to the canvas / base / markdown
 * surface (markdown gets the reading view + an inline edit toggle). This is the
 * per-pane equivalent of the single-pane WikiPage main area; the right rail and
 * section overlays stay global in WikiPage, following the ACTIVE leaf.
 */
export function WikiLeafBody({ leaf, isActive, callbacks }: Props) {
  if (leaf.state.type === "empty") {
    return (
      <div className="flex min-h-0 flex-1 flex-col items-center justify-center gap-2 text-center text-[color:var(--color-text-quaternary)]">
        <FileText className="size-8 opacity-40" />
        <div className="text-[13px]">No page open in this pane</div>
        <div className="text-[12px]">Open one from the explorer, or press ⌘O to switch pages.</div>
      </div>
    );
  }
  return <PageLeafBody pageId={leaf.state.pageId} isActive={isActive} callbacks={callbacks} />;
}

function PageLeafBody({
  pageId,
  isActive,
  callbacks,
}: {
  pageId: string;
  isActive: boolean;
  callbacks: LeafBodyCallbacks;
}) {
  const { connector, status } = useRuntime();
  const location = useLocation();
  const [reloadKey, setReloadKey] = React.useState(0);
  const [editing, setEditing] = React.useState(false);
  const { page, loading } = useWikiPage(pageId, reloadKey);

  // Leave edit mode whenever the pane's page changes.
  React.useEffect(() => setEditing(false), [pageId]);

  const docKind: "canvas" | "base" | "page" = page
    ? isCanvasDoc(page.content)
      ? "canvas"
      : isBaseBody(page.content)
        ? "base"
        : "page"
    : "page";

  if (loading && !page) {
    return <div className="p-6 text-[13px] text-[color:var(--color-text-secondary)]">Loading…</div>;
  }
  if (!page) {
    return <div className="p-6 text-[13px] text-[color:var(--color-text-secondary)]">Page not found.</div>;
  }

  if (docKind === "canvas") {
    return (
      <div className="relative flex min-h-0 flex-1">
        <WikiCanvasView pageId={pageId} onOpenPage={callbacks.onWikiLink} className="flex-1" />
        <div className="absolute left-3 top-3 z-20">
          <DeletePageButton pageId={pageId} title={page.title} onDeleted={callbacks.onDeleted} />
        </div>
      </div>
    );
  }
  if (docKind === "base") {
    return (
      <div className="relative flex min-h-0 flex-1">
        <WikiBaseView pageId={pageId} />
        <div className="absolute right-3 top-3 z-20">
          <DeletePageButton pageId={pageId} title={page.title} onDeleted={callbacks.onDeleted} />
        </div>
      </div>
    );
  }

  if (editing) {
    return (
      <WikiEditor
        pageId={pageId}
        resolveWikiLink={callbacks.resolveWikiLink}
        onNavigate={callbacks.onNavigatePath}
        onSaved={(id) => {
          // An in-pane editor always edits an existing page, so the saved id
          // matches pageId; reload this pane's body and refresh the live page
          // list + right rail (titles may have changed).
          setEditing(false);
          setReloadKey((k) => k + 1);
          callbacks.onPageSaved(id);
        }}
        onCancel={() => setEditing(false)}
      />
    );
  }

  return (
    <ScrollArea className="min-h-0 flex-1">
      <div className="mx-auto w-full max-w-[820px] px-6 pb-16 pt-6">
        <div className="mb-2 flex justify-end gap-1.5">
          <BookmarkButton pageId={page.id} title={page.title} />
          <Button variant="outline" size="xs" onClick={() => setEditing(true)}>
            <Pencil className="mr-1 size-3" /> Edit
          </Button>
          {isActive && (
            <Button variant="outline" size="xs" onClick={callbacks.onOpenSettings} aria-label="Wiki settings">
              <SettingsIcon className="size-3" />
            </Button>
          )}
          <DeletePageButton pageId={page.id} title={page.title} onDeleted={callbacks.onDeleted} />
        </div>
        <WikiReadingView
          page={page}
          onWikiLink={callbacks.onWikiLink}
          onTag={callbacks.onTag}
          resolveWikiLink={callbacks.resolveWikiLink}
          fragment={isActive ? decodeURIComponent(location.hash.replace(/^#/, "")) || null : null}
          onPageSaved={callbacks.onPageSaved}
          onOpenPage={(id) => callbacks.onNavigatePath(`/wiki/${id}`, { newTab: false })}
        />
      </div>
    </ScrollArea>
  );
}
