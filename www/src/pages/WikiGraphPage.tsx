import { useState } from "react";
import { useNavigate } from "react-router-dom";
import { ArrowLeft, Globe } from "lucide-react";
import { Button } from "@/components/ui/button";
import { WikiGraphView } from "@/components/wiki/graph/WikiGraphView";

/**
 * Full-screen Memory Wiki graph (route /wiki/graph). Starts on the whole
 * entity/edge graph; clicking a node re-seeds a local neighborhood (explore).
 * "Whole graph" resets the seed. Entities are not pages, so a click explores the
 * graph rather than navigating.
 */
export function WikiGraphPage() {
  const navigate = useNavigate();
  const [seed, setSeed] = useState<{ id: string; label: string } | null>(null);

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex shrink-0 items-center gap-2 border-b border-[color:var(--border)] px-4 py-2">
        <Button variant="ghost" size="iconSm" onClick={() => navigate("/wiki")} aria-label="Back to wiki">
          <ArrowLeft />
        </Button>
        <span className="text-[13px] font-medium text-foreground">Graph</span>
        {seed ? (
          <>
            <span className="text-[12px] text-[color:var(--color-text-quaternary)]">›</span>
            <span className="text-[12px] text-[color:var(--color-text-secondary)]">{seed.label}</span>
            <Button variant="ghost" size="xs" className="ml-1" onClick={() => setSeed(null)}>
              <Globe className="mr-1 size-3" /> Whole graph
            </Button>
          </>
        ) : (
          <span className="text-[12px] text-[color:var(--color-text-quaternary)]">entire wiki</span>
        )}
      </div>
      <div className="min-h-0 flex-1 p-3">
        <WikiGraphView
          seedEntityId={seed?.id}
          depth={2}
          onSelectEntity={(id, canonical) => setSeed({ id, label: canonical })}
          className="h-full w-full"
        />
      </div>
    </div>
  );
}
