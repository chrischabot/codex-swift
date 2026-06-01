import { Globe, ExternalLink, Loader2, CheckCircle2, XCircle } from "lucide-react";

interface Props {
  url: string;
  title?: string;
  status?: "fetching" | "ok" | "error";
  contentSnippet?: string;
}

export function WebFetchBlock({ url, title, status = "ok", contentSnippet }: Props) {
  const host = safeHost(url);
  return (
    <a
      href={url}
      target="_blank"
      rel="noreferrer"
      className="my-2 block rounded-lg border border-[color:var(--border)] bg-background p-3 hover:bg-[color:var(--color-surface-hover)]"
    >
      <div className="flex items-center gap-2 text-[12.5px]">
        <Globe className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <span className="truncate font-medium">{title ?? url}</span>
        {status === "fetching" && <Loader2 className="size-3 animate-spin text-[color:var(--color-blue-400)]" />}
        {status === "ok"       && <CheckCircle2 className="size-3 text-[color:var(--color-green-500)]" />}
        {status === "error"    && <XCircle className="size-3 text-[color:var(--color-red-500)]" />}
        <ExternalLink className="ml-auto size-3 text-[color:var(--color-text-tertiary)]" />
      </div>
      <div className="mt-0.5 truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{host}</div>
      {contentSnippet && (
        <div className="mt-1 line-clamp-2 text-[12px] text-[color:var(--color-text-secondary)]">{contentSnippet}</div>
      )}
    </a>
  );
}

function safeHost(u: string): string {
  try {
    return new URL(u).host;
  } catch {
    return u;
  }
}
