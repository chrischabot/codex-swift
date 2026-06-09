// useCanvasDoc — load + debounced-save bridge between a canvas board and the
// wiki connector. A canvas lives inside a WikiPage: we `getWikiPage(id)` to read
// `content`, parse the frontmatter + JSON, and hand back a `Canvas`. Mutations
// from the board are pushed in via `setCanvas`, debounced, reserialized through
// `serializeCanvasDoc`, and persisted with `saveWikiPage`.
//
// Saving is ref-driven so the latest canvas is always flushed (debounce timer
// reads from a ref, and an unmount/visibility flush covers the trailing edit).
// Both connector methods are optional on the Connector interface, so we guard
// for their presence and surface a `canSave` flag for the toolbar.

import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage } from "@/runtime/connector";
import {
  type Canvas,
  parseCanvasDoc,
  serializeCanvasDoc,
} from "./canvasSchema";

const SAVE_DEBOUNCE_MS = 600;

export type CanvasDocStatus = "loading" | "ready" | "missing" | "error";

export interface UseCanvasDoc {
  canvas: Canvas;
  status: CanvasDocStatus;
  /** The owning wiki page's title (for the header / fallback label). */
  title: string;
  /** Whether the connector exposes saveWikiPage (else read-only). */
  canSave: boolean;
  /** "saved" | "saving" | "dirty" — for a subtle status hint. */
  saveState: "saved" | "saving" | "dirty";
  /** Replace the canvas and schedule a debounced persist. */
  setCanvas: (next: Canvas) => void;
  /** Force an immediate flush (e.g. before navigating away). */
  flush: () => void;
}

export function useCanvasDoc(pageId: string | undefined): UseCanvasDoc {
  const { connector, status: rtStatus } = useRuntime();
  const connected = rtStatus.kind === "connected";

  const [canvas, setCanvasState] = React.useState<Canvas>({ nodes: [], edges: [] });
  const [status, setStatus] = React.useState<CanvasDocStatus>("loading");
  const [title, setTitle] = React.useState("");
  const [saveState, setSaveState] = React.useState<"saved" | "saving" | "dirty">("saved");

  const canSave = connected && typeof connector.saveWikiPage === "function";

  // Refs the debounced save / flush read from so they never go stale.
  const canvasRef = React.useRef<Canvas>(canvas);
  const frontmatterRef = React.useRef<Record<string, string>>({});
  const pageIdRef = React.useRef<string | undefined>(pageId);
  const dirtyRef = React.useRef(false);
  const timerRef = React.useRef<ReturnType<typeof setTimeout> | null>(null);
  const savingRef = React.useRef(false);

  React.useEffect(() => {
    pageIdRef.current = pageId;
  }, [pageId]);

  // Load (and reload) on page / connection change.
  React.useEffect(() => {
    if (!pageId) {
      setStatus("missing");
      return;
    }
    if (!connector.getWikiPage || !connected) {
      // Wait for the handshake; stay in loading until connected.
      if (rtStatus.kind === "error") setStatus("error");
      return;
    }
    let cancelled = false;
    setStatus("loading");
    connector
      .getWikiPage(pageId)
      .then((page: WikiPage | null) => {
        if (cancelled) return;
        if (!page) {
          setStatus("missing");
          return;
        }
        // A reload can re-fire on reconnect / rtStatus changes. If the user has
        // an unsaved local edit (dirtyRef), the server copy is STALE — adopting
        // it would silently discard the edit, and the pending debounce save
        // would then no-op (dirty already cleared). Keep the local doc; only
        // leave the loading state. The queued save still flushes the edit.
        if (dirtyRef.current) {
          setTitle(page.title ?? "");
          setStatus("ready");
          return;
        }
        const { frontmatter, canvas: parsed } = parseCanvasDoc(page.content);
        frontmatterRef.current = frontmatter;
        canvasRef.current = parsed;
        dirtyRef.current = false;
        setCanvasState(parsed);
        setTitle(page.title ?? "");
        setSaveState("saved");
        setStatus("ready");
      })
      .catch(() => {
        if (!cancelled) setStatus("error");
      });
    return () => {
      cancelled = true;
    };
  }, [pageId, connector, connected, rtStatus.kind]);

  const persist = React.useCallback(() => {
    const id = pageIdRef.current;
    if (!id || !connector.saveWikiPage) return;
    if (!dirtyRef.current) return;
    // Serialize saves: if one is already in flight, leave the doc dirty and let
    // that save's completion re-trigger persist (below). Without this gate a
    // debounce-timer save could race an in-flight save and persist a stale body.
    if (savingRef.current) return;
    savingRef.current = true;
    setSaveState("saving");
    const body = serializeCanvasDoc(canvasRef.current, stripType(frontmatterRef.current));
    dirtyRef.current = false;
    connector
      .saveWikiPage({ id, body })
      .then(() => {
        savingRef.current = false;
        // If another edit landed mid-save, flush it now (chained, not concurrent).
        if (dirtyRef.current) {
          persist();
        } else {
          setSaveState("saved");
        }
      })
      .catch(() => {
        savingRef.current = false;
        dirtyRef.current = true;
        setSaveState("dirty");
      });
  }, [connector]);

  const schedule = React.useCallback(() => {
    dirtyRef.current = true;
    setSaveState("dirty");
    if (!connector.saveWikiPage || !pageIdRef.current) return;
    if (timerRef.current) clearTimeout(timerRef.current);
    timerRef.current = setTimeout(persist, SAVE_DEBOUNCE_MS);
  }, [connector, persist]);

  const setCanvas = React.useCallback(
    (next: Canvas) => {
      canvasRef.current = next;
      setCanvasState(next);
      schedule();
    },
    [schedule],
  );

  const flush = React.useCallback(() => {
    if (timerRef.current) {
      clearTimeout(timerRef.current);
      timerRef.current = null;
    }
    persist();
  }, [persist]);

  // Flush on unmount / page change so the trailing edit is never lost.
  React.useEffect(() => {
    return () => {
      if (timerRef.current) clearTimeout(timerRef.current);
      if (dirtyRef.current) persist();
    };
  }, [pageId, persist]);

  return { canvas, status, title, canSave, saveState, setCanvas, flush };
}

/** Strip the managed `wiki_type` key so serialize re-adds it canonically. */
function stripType(fm: Record<string, string>): Record<string, string> {
  const { wiki_type: _omit, ...rest } = fm;
  return rest;
}
