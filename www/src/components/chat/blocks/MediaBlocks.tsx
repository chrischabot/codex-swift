import * as React from "react";
import { FileText, Image as ImageIcon, FileAudio2, FileVideo2, ExternalLink, Link as LinkIcon, Box } from "lucide-react";

interface BaseProps {
  url: string;
  filename?: string;
}

export function ImageBlock({ url, alt }: { url: string; alt?: string }) {
  const [errored, setErrored] = React.useState(false);
  if (errored) {
    return (
      <div className="my-3 flex items-center gap-2 rounded-lg border border-[color:var(--border)] bg-background px-3 py-3 text-[12px] text-[color:var(--color-text-tertiary)]">
        <ImageIcon className="size-4" /> Image unavailable
        <a
          href={url}
          target="_blank"
          rel="noreferrer"
          className="ml-auto inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
        >
          Open <ExternalLink className="size-3" />
        </a>
      </div>
    );
  }
  return (
    <a
      href={url}
      target="_blank"
      rel="noreferrer"
      title="Open image"
      className="my-3 block overflow-hidden rounded-lg border border-[color:var(--border)] bg-background"
    >
      <img
        src={url}
        alt={alt ?? ""}
        onError={() => setErrored(true)}
        className="block max-h-[440px] w-full cursor-zoom-in object-contain"
      />
    </a>
  );
}

export function AudioBlock({ url, filename }: BaseProps) {
  return (
    <div className="my-3 flex items-center gap-3 rounded-lg border border-[color:var(--border)] bg-background px-3 py-2">
      <FileAudio2 className="size-4 text-[color:var(--color-text-secondary)]" />
      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] font-medium">{filename ?? "audio"}</div>
        <audio controls src={url} className="mt-1 w-full" />
      </div>
    </div>
  );
}

export function VideoBlock({ url, filename }: BaseProps) {
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] px-3 py-1.5 text-[12px] text-[color:var(--color-text-tertiary)]">
        <FileVideo2 className="size-3.5" />
        <span className="truncate">{filename ?? "video"}</span>
      </div>
      <video controls src={url} className="block w-full" />
    </div>
  );
}

export function DocumentBlock({ url, filename, mime }: BaseProps & { mime?: string }) {
  const isPdf = mime?.includes("pdf") || filename?.toLowerCase().endsWith(".pdf");
  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex items-center gap-2 border-b border-[color:var(--color-divider)] px-3 py-1.5 text-[12px]">
        <FileText className="size-3.5 text-[color:var(--color-text-secondary)]" />
        <span className="truncate font-medium">{filename}</span>
        <a
          href={url}
          target="_blank"
          rel="noreferrer"
          className="ml-auto inline-flex items-center gap-1 rounded px-1.5 py-0.5 text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]"
        >
          Open <ExternalLink className="size-3" />
        </a>
      </div>
      {isPdf ? (
        <iframe title={filename} src={url} className="block h-[440px] w-full" />
      ) : (
        <div className="flex items-center gap-2 px-3 py-3 text-[12px] text-[color:var(--color-text-secondary)]">
          <FileText className="size-4" /> Document preview available — open externally.
        </div>
      )}
    </div>
  );
}

export function RefBlock({
  uri,
  title,
  refKind,
}: {
  uri: string;
  title?: string;
  refKind?: "resource" | "file" | "artifact";
}) {
  const Icon = refKind === "file" ? FileText : refKind === "artifact" ? Box : LinkIcon;
  return (
    <a
      href={uri}
      target="_blank"
      rel="noreferrer"
      className="my-2 inline-flex items-center gap-2 rounded-lg border border-[color:var(--border)] bg-background px-3 py-1.5 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
    >
      <Icon className="size-3.5 text-[color:var(--color-text-secondary)]" />
      <span className="font-medium">{title ?? uri}</span>
      <ExternalLink className="size-3 text-[color:var(--color-text-quaternary)]" />
    </a>
  );
}

export function CitationsBlock({
  items,
}: {
  items: { title?: string; url: string; snippet?: string }[];
}) {
  return (
    <div className="my-3 rounded-lg border border-[color:var(--border)] bg-[color:var(--sidebar)] p-3">
      <div className="mb-1.5 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">Sources</div>
      <ol className="list-decimal space-y-1.5 pl-5 text-[12.5px] marker:text-[color:var(--color-text-quaternary)]">
        {items.map((c, i) => (
          <li key={i}>
            <a
              href={c.url}
              target="_blank"
              rel="noreferrer"
              className="text-[color:var(--color-blue-400)] hover:underline"
            >
              {c.title ?? c.url}
            </a>
            {c.snippet && (
              <div className="text-[11.5px] text-[color:var(--color-text-tertiary)]">{c.snippet}</div>
            )}
          </li>
        ))}
      </ol>
    </div>
  );
}
