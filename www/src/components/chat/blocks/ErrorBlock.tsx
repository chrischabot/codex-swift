import { AlertOctagon, RefreshCcw } from "lucide-react";
import { Button } from "@/components/ui/button";

interface Props {
  message: string;
  code?: string;
  retryable?: boolean;
  onRetry?: () => void;
}

export function ErrorBlock({ message, code, retryable, onRetry }: Props) {
  return (
    <div className="my-3 flex items-start gap-2.5 rounded-lg border border-[color:var(--color-red-500)]/35 bg-[color:var(--color-red-500)]/5 px-3 py-2.5">
      <AlertOctagon className="mt-0.5 size-4 shrink-0 text-[color:var(--color-red-500)]" />
      <div className="min-w-0 flex-1">
        <div className="text-[13px] font-medium text-foreground">{message}</div>
        {code && (
          <code className="mt-0.5 inline-block rounded bg-[color:var(--color-red-500)]/10 px-1 py-0.5 font-mono text-[11px] text-[color:var(--color-red-500)]">
            {code}
          </code>
        )}
      </div>
      {retryable && (
        <Button variant="outline" size="xs" onClick={onRetry} className="shrink-0">
          <RefreshCcw className="!size-3" /> Retry
        </Button>
      )}
    </div>
  );
}
