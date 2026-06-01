import { Activity } from "lucide-react";

interface Props {
  input: number;
  output: number;
  cacheRead?: number;
  cost?: number;
}

export function TokenUsageBlock({ input, output, cacheRead, cost }: Props) {
  const fmt = (n: number) => n.toLocaleString();
  return (
    <div className="my-2 inline-flex items-center gap-2 rounded-md bg-[color:var(--color-surface-hover)] px-2 py-1 font-mono text-[12px] text-[color:var(--color-text-tertiary)]">
      <Activity className="size-3" />
      <span><span className="text-foreground">{fmt(input)}</span> in</span>
      <span><span className="text-foreground">{fmt(output)}</span> out</span>
      {cacheRead != null && cacheRead > 0 && <span><span className="text-foreground">{fmt(cacheRead)}</span> cache</span>}
      {cost != null && <span>· ${cost.toFixed(4)}</span>}
    </div>
  );
}
