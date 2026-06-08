import * as React from "react";
import { ChevronRight, Hash } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  Collapsible,
  CollapsibleContent,
  CollapsibleTrigger,
} from "@/components/ui/collapsible";
import { useWikiTags } from "@/state/wiki";

interface Props {
  /** Invoked when a tag is clicked. The integrator wires this to navigate to a
   *  tag-filtered view (e.g. `/wiki?tag=<tag>`). */
  onSelectTag?: (tag: string) => void;
  /** Currently-active tag (full path, e.g. "ai/ml") — highlights its row. */
  activeTag?: string;
}

/** A node in the hierarchical tag tree. Tags nest on "/" — `ai/ml` and `ai/nlp`
 *  produce an `ai` parent with `ml` / `nlp` children. `count` on a branch is the
 *  total of its own direct count plus all descendants (Obsidian tag-pane look). */
interface TagNode {
  /** The last path segment, e.g. "ml" for "ai/ml". Used as the visible label. */
  segment: string;
  /** The full slash-joined path, e.g. "ai/ml". Passed to `onSelectTag`. */
  fullName: string;
  /** Total count (own + descendants). */
  count: number;
  children: Map<string, TagNode>;
}

function makeNode(segment: string, fullName: string): TagNode {
  return { segment, fullName, count: 0, children: new Map() };
}

/** Build a hierarchical tree from the flat `{tag, count}[]` list, splitting each
 *  tag on "/". Intermediate path segments become branch nodes even when no tag
 *  terminates there (e.g. "ai/ml" alone still yields an "ai" branch). Branch
 *  counts roll up own + descendant counts. */
function buildTagTree(entries: ReadonlyArray<{ tag: string; count: number }>): TagNode {
  const root = makeNode("", "");
  for (const entry of entries) {
    const name = entry.tag.replace(/^#/, "");
    const parts = name.split("/");
    let cur = root;
    for (let i = 0; i < parts.length; i++) {
      const seg = parts[i];
      if (!seg) continue;
      let next = cur.children.get(seg);
      if (!next) {
        next = makeNode(seg, parts.slice(0, i + 1).join("/"));
        cur.children.set(seg, next);
      }
      cur = next;
    }
    // Accumulate (defensive against duplicate tags in the flat list).
    cur.count += entry.count;
  }

  const computeTotals = (node: TagNode): number => {
    let total = node.count;
    for (const child of node.children.values()) total += computeTotals(child);
    node.count = total;
    return total;
  };
  computeTotals(root);
  return root;
}

/** Sort by total count descending, then alphabetically by segment for stable ties. */
function sortNodes(nodes: Iterable<TagNode>): TagNode[] {
  return [...nodes].sort((a, b) => b.count - a.count || a.segment.localeCompare(b.segment));
}

const ROW_BASE_PAD = 8;
const DEPTH_INDENT = 16;

interface TagRowProps {
  node: TagNode;
  depth: number;
  onSelectTag?: (tag: string) => void;
  activeTag?: string;
}

function TagRow({ node, depth, onSelectTag, activeTag }: TagRowProps): React.JSX.Element {
  const hasChildren = node.children.size > 0;
  const isActive = activeTag === node.fullName;
  // Branch nodes default open so the tree reads as an expanded outline initially.
  const [open, setOpen] = React.useState(true);
  const padInlineStart = ROW_BASE_PAD + depth * DEPTH_INDENT;

  const row = (
    <div
      className={cn(
        "group flex items-center gap-1 rounded-sm py-1 pr-1.5 text-md",
        "hover:bg-[color:var(--color-surface-hover)]",
        isActive
          ? "bg-[color:var(--color-surface-active)] text-foreground"
          : "text-[color:var(--color-text-secondary)]",
      )}
      style={{ paddingInlineStart: padInlineStart }}
    >
      {hasChildren ? (
        <CollapsibleTrigger
          aria-label={open ? `Collapse ${node.fullName}` : `Expand ${node.fullName}`}
          className={cn(
            "inline-flex size-3.5 shrink-0 items-center justify-center rounded-sm",
            "text-[color:var(--color-text-tertiary)] hover:text-foreground",
          )}
        >
          <ChevronRight
            className={cn("size-3 transition-transform", open && "rotate-90")}
          />
        </CollapsibleTrigger>
      ) : (
        <span className="inline-block size-3.5 shrink-0" aria-hidden />
      )}

      <button
        type="button"
        className="flex min-w-0 flex-1 items-center gap-1.5 text-left hover:text-foreground"
        onClick={() => onSelectTag?.(node.fullName)}
        title={node.fullName}
      >
        <Hash className="size-3 shrink-0 text-[color:var(--color-text-tertiary)]" />
        <span className="truncate">{node.segment}</span>
      </button>

      <span className="ml-auto shrink-0 text-2xs tabular-nums text-[color:var(--color-text-quaternary)]">
        {node.count}
      </span>
    </div>
  );

  if (!hasChildren) return row;

  return (
    <Collapsible open={open} onOpenChange={setOpen}>
      {row}
      <CollapsibleContent>
        {sortNodes(node.children.values()).map((child) => (
          <TagRow
            key={child.fullName}
            node={child}
            depth={depth + 1}
            onSelectTag={onSelectTag}
            activeTag={activeTag}
          />
        ))}
      </CollapsibleContent>
    </Collapsible>
  );
}

/** Hierarchical, clickable tag tree for the wiki sidebar — an Obsidian-style tag
 *  pane. Builds its tree internally from `useWikiTags()`; tags nest on "/" with
 *  per-level count rollups and collapsible branch groups. */
export function WikiTagsPanel({ onSelectTag, activeTag }: Props): React.JSX.Element {
  const tags = useWikiTags();
  const roots = React.useMemo(() => sortNodes(buildTagTree(tags).children.values()), [tags]);

  if (roots.length === 0) {
    return (
      <div className="px-2 py-3 text-md text-[color:var(--color-text-tertiary)]">
        No tags yet
      </div>
    );
  }

  return (
    <div className="flex flex-col gap-px py-1 select-none">
      {roots.map((node) => (
        <TagRow
          key={node.fullName}
          node={node}
          depth={0}
          onSelectTag={onSelectTag}
          activeTag={activeTag}
        />
      ))}
    </div>
  );
}
