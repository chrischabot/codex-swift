import { Cpu, ArrowRight } from "lucide-react";

interface Props {
  from?: string;
  to: string;
  reason?: string;
}

export function ModelSwitchBlock({ from, to, reason }: Props) {
  return (
    <div className="my-2 inline-flex items-center gap-2 rounded-md border border-[color:var(--color-blue-300)]/40 bg-[color:var(--color-blue-50)]/50 px-2 py-1 text-[12px]">
      <Cpu className="size-3 text-[color:var(--color-blue-400)]" />
      {from && (
        <>
          <span className="font-mono text-[color:var(--color-text-secondary)]">{from}</span>
          <ArrowRight className="size-3 text-[color:var(--color-text-tertiary)]" />
        </>
      )}
      <span className="font-mono font-medium">{to}</span>
      {reason && <span className="text-[color:var(--color-text-tertiary)]">· {reason}</span>}
    </div>
  );
}
