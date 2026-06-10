import * as React from "react";
import { Command } from "cmdk";
import { useNavigate } from "react-router-dom";
import { FileText, Loader2, Search } from "lucide-react";
import {
  Dialog,
  DialogContent,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { useWikiMetadataIndex } from "./useWikiMetadataIndex";
import { fuzzyRank } from "./fuzzyRank";

interface Props {
  open: boolean;
  onOpenChange: (o: boolean) => void;
}

const itemClass =
  "flex h-9 items-center gap-2 rounded-md px-2 text-[13px] text-foreground aria-selected:bg-[color:var(--color-surface-hover)]";

/**
 * Wiki Quick Switcher — granite's Cmd-O fuzzy switcher, ported as a www Dialog
 * over cmdk. On open it loads up to 500 pages via connector.listWikiPages, then
 * fuzzy-filters titles (cmdk's built-in scorer) and navigates to /wiki/<id> on
 * select. The page source renders as a muted suffix. Empty + loading states
 * mirror the original's "loading…" placeholder.
 *
 * We deliberately re-fetch on every open (not just mount) so the list reflects
 * pages created since the dialog was last shown; the fetch is gated on a live
 * connector + the optional listWikiPages capability (the mock omits it, yielding
 * a clean empty state rather than a throw).
 */
export function WikiQuickSwitcher({ open, onOpenChange }: Props) {
  const navigate = useNavigate();
  // The whole vault (no 500 cap), via the shared metadata index.
  const { pages, loading } = useWikiMetadataIndex();
  const [query, setQuery] = React.useState("");

  // Reset the query each time the dialog reopens.
  React.useEffect(() => {
    if (open) setQuery("");
  }, [open]);

  // Rank the entire vault in compute and render only the top matches, so 5k+
  // pages stay fast (rendering every page for cmdk to score does not).
  const ranked = React.useMemo(
    () => fuzzyRank(query, pages, (p) => p.title || "Untitled", 50),
    [query, pages],
  );

  const go = (id: string) => {
    onOpenChange(false);
    navigate(`/wiki/${id}`);
  };

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent className="max-w-[560px] p-0" showClose={false}>
        <DialogTitle className="sr-only">Jump to wiki page</DialogTitle>
        <DialogDescription className="sr-only">
          Fuzzy-search wiki pages by title and open one
        </DialogDescription>
        {/* We rank in compute (fuzzyRank) and render only the top matches, so
            cmdk does NOT filter — shouldFilter=false. */}
        <Command label="Jump to wiki page" shouldFilter={false}>
          <div className="flex items-center gap-2 border-b border-[color:var(--border)] px-3">
            <Search className="size-4 text-[color:var(--color-text-tertiary)]" />
            <Command.Input
              autoFocus
              value={query}
              onValueChange={setQuery}
              placeholder={loading ? "Loading pages…" : "Jump to page…"}
              className="h-11 flex-1 bg-transparent text-foreground outline-none placeholder:text-[color:var(--color-text-quaternary)]"
            />
          </div>
          <Command.List className="max-h-[400px] overflow-y-auto p-2">
            {loading ? (
              <div className="flex items-center justify-center gap-2 px-3 py-6 text-[13px] text-[color:var(--color-text-tertiary)]">
                <Loader2 className="size-4 animate-spin" />
                Loading pages…
              </div>
            ) : (
              <Command.Empty className="px-3 py-6 text-center text-[13px] text-[color:var(--color-text-tertiary)]">
                {pages.length === 0 ? "No wiki pages" : "No matching pages"}
              </Command.Empty>
            )}
            {ranked.map(({ item: p }) => (
              <Command.Item
                key={p.id}
                value={p.id}
                onSelect={() => go(p.id)}
                className={itemClass}
              >
                <FileText className="size-4 shrink-0 text-[color:var(--color-text-tertiary)]" />
                <span className="flex-1 truncate">{p.title || "Untitled"}</span>
                {p.source ? (
                  <span className="shrink-0 truncate text-xs text-[color:var(--color-text-quaternary)]">
                    {p.source}
                  </span>
                ) : null}
              </Command.Item>
            ))}
          </Command.List>
        </Command>
      </DialogContent>
    </Dialog>
  );
}
