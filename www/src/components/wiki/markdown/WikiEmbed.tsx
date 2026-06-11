import * as React from "react";
import { FileText, Loader2, FileQuestion } from "lucide-react";
import { cn } from "@/lib/utils";
import { useWikiLive, WikiLiveProvider, MAX_EMBED_DEPTH } from "./WikiLiveContext";
import { parseFragment, sliceForFragment } from "./transclude";
// Circular import (WikiMarkdown imports WikiEmbed): safe because both reference
// each other only inside render, so ESM live bindings are populated by the time
// the embed actually mounts.
import { WikiMarkdown } from "../WikiMarkdown";

interface Props {
  /** The bare target name (no #heading / #^block suffix). */
  target: string;
  /** The full target including any #heading / #^block fragment. */
  fullTarget?: string;
  /** The display label (alias) if one was given, else the target. */
  display?: string;
  /** Optional click handler — wired by WikiMarkdown to navigate. */
  onOpen?: (target: string) => void;
  /** Optional DOM id (a `block-<id>` anchor hoisted from a `^blockid` on the
   *  embed line) so `[[Page#^id]]` can scroll to it. */
  anchorId?: string;
}

/** Shell chrome shared by every embed state (placeholder, loaded, error). */
function EmbedFrame({
  anchorId,
  onClick,
  children,
}: {
  anchorId?: string;
  onClick?: () => void;
  children: React.ReactNode;
}) {
  const clickable = typeof onClick === "function";
  return (
    <div
      id={anchorId}
      className={cn(
        "wiki-embed my-3 rounded-md border border-l-2 border-[color:var(--border)]",
        "border-l-[color:var(--text-link)] bg-[color:var(--code-surface)] px-3 py-2.5",
        clickable && "cursor-pointer hover:bg-[color:var(--color-surface-hover)]",
      )}
      role={clickable ? "button" : undefined}
      tabIndex={clickable ? 0 : undefined}
      onClick={clickable ? onClick : undefined}
      onKeyDown={
        clickable
          ? (e) => {
              if (e.key === "Enter" || e.key === " ") {
                e.preventDefault();
                onClick!();
              }
            }
          : undefined
      }
    >
      {children}
    </div>
  );
}

function EmbedHeader({ label, icon }: { label: string; icon: React.ReactNode }) {
  return (
    <div className="flex items-center gap-2 text-[13px] font-medium text-[color:var(--text-link)]">
      {icon}
      <span className="truncate">{label}</span>
    </div>
  );
}

type EmbedState =
  | { kind: "idle" }
  | { kind: "loading" }
  | { kind: "loaded"; id: string; title: string; body: string }
  | { kind: "missing" }
  | { kind: "cycle" }
  | { kind: "notfound" }; // page found, fragment missing

/**
 * Obsidian transclusion `![[Page]]` (M27). When the host supplies a page loader
 * (via WikiLiveContext) and we're under the depth cap, the referenced note —
 * or a `#Heading` section / `#^block` — is fetched and rendered INLINE with the
 * full wiki markdown pipeline (recursively, cycle-guarded). Without a loader, at
 * the depth cap, or on a cycle, it degrades to the previous clickable
 * placeholder card. A missing page / heading shows a small "not found" note.
 */
export function WikiEmbed({ target, fullTarget, display, onOpen, anchorId }: Props) {
  const { loadEmbed, embedDepth, embedChain } = useWikiLive();
  const frag = React.useMemo(() => parseFragment(fullTarget ?? target), [fullTarget, target]);
  const label = display && display.length > 0 ? display : (fullTarget ?? target);

  const canTransclude = !!loadEmbed && embedDepth < MAX_EMBED_DEPTH;
  const [state, setState] = React.useState<EmbedState>({
    kind: canTransclude ? "loading" : "idle",
  });

  React.useEffect(() => {
    if (!canTransclude || !loadEmbed) {
      setState({ kind: "idle" });
      return;
    }
    let alive = true;
    setState({ kind: "loading" });
    loadEmbed(frag.title)
      .then((page) => {
        if (!alive) return;
        if (!page) {
          setState({ kind: "missing" });
          return;
        }
        if (embedChain.has(page.id)) {
          setState({ kind: "cycle" });
          return;
        }
        const slice = sliceForFragment(page.content, frag);
        if (slice == null) {
          setState({ kind: "notfound" });
          return;
        }
        setState({ kind: "loaded", id: page.id, title: page.title, body: slice });
      })
      .catch(() => alive && setState({ kind: "missing" }));
    return () => {
      alive = false;
    };
  }, [canTransclude, loadEmbed, frag, embedChain]);

  const open = onOpen ? () => onOpen(fullTarget ?? target) : undefined;

  // Placeholder (no loader / depth cap): the original clickable card.
  if (!canTransclude) {
    return (
      <EmbedFrame anchorId={anchorId} onClick={open}>
        <EmbedHeader label={label} icon={<FileText className="size-4 shrink-0" aria-hidden />} />
        <div className="mt-0.5 text-[12px] text-[color:var(--color-text-tertiary)]">
          {embedDepth >= MAX_EMBED_DEPTH ? "Embed nested too deep" : "Embedded note"}
        </div>
      </EmbedFrame>
    );
  }

  if (state.kind === "loading") {
    return (
      <EmbedFrame anchorId={anchorId}>
        <div className="flex items-center gap-2 text-[12px] text-[color:var(--color-text-tertiary)]">
          <Loader2 className="size-3.5 shrink-0 animate-spin" aria-hidden />
          Loading {label}…
        </div>
      </EmbedFrame>
    );
  }

  if (state.kind === "missing" || state.kind === "notfound" || state.kind === "cycle") {
    const note =
      state.kind === "cycle"
        ? "Skipped (would loop back to a page already embedded)"
        : state.kind === "notfound"
          ? "Section not found in the referenced note"
          : "Referenced note not found";
    return (
      <EmbedFrame anchorId={anchorId} onClick={open}>
        <EmbedHeader label={label} icon={<FileQuestion className="size-4 shrink-0" aria-hidden />} />
        <div className="mt-0.5 text-[12px] text-[color:var(--color-text-tertiary)]">{note}</div>
      </EmbedFrame>
    );
  }

  // Loaded: render the slice inline with the full pipeline, recursion-guarded.
  if (state.kind !== "loaded") return null; // unreachable (idle handled above)
  const loaded = state;
  return (
    <EmbedFrame anchorId={anchorId}>
      <button
        type="button"
        onClick={open}
        className="mb-1.5 flex w-full items-center gap-2 text-left text-[12px] font-medium text-[color:var(--text-link)] hover:underline"
      >
        <FileText className="size-3.5 shrink-0" aria-hidden />
        <span className="truncate">{label}</span>
      </button>
      <div className="wiki-embed-body border-t border-[color:var(--border)] pt-2">
        <WikiLiveProvider
          value={{
            loadEmbed,
            embedDepth: embedDepth + 1,
            embedChain: new Set([...embedChain, loaded.id]),
            liveBlocks: false, // live blocks don't fire inside an embed
          }}
        >
          <WikiMarkdown content={loaded.body} onWikiLink={onOpen} />
        </WikiLiveProvider>
      </div>
    </EmbedFrame>
  );
}
