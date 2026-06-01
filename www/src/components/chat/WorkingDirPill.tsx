import { Folder, Check } from "lucide-react";
import * as React from "react";

interface Props {
  project: string;
  path: string;
}

// Working-directory indicator shown above/with the composer. Re-modeled on the
// original composer footer label (composer-external-footer.js:
// `composer-footer__label--xs max-w-40 truncate` with an icon-xs) rather than
// the invented black two-line terminal chip. It's a compact, muted, truncated
// inline label with a folder icon. Click-to-copy is preserved.
export function WorkingDirPill({ project, path }: Props) {
  const [copied, setCopied] = React.useState(false);
  return (
    <button
      type="button"
      title={path}
      onClick={() => {
        navigator.clipboard?.writeText(path);
        setCopied(true);
        setTimeout(() => setCopied(false), 1000);
      }}
      className="mb-1.5 flex max-w-full items-center gap-1.5 rounded-md px-1.5 py-0.5 text-left text-[12px] text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-[color:var(--color-text-secondary)]"
    >
      {copied ? (
        <Check className="size-3.5 shrink-0" />
      ) : (
        <Folder className="size-3.5 shrink-0" />
      )}
      <span className="max-w-40 truncate font-medium">{project}</span>
      <span className="min-w-0 truncate text-[color:var(--color-text-quaternary)]">{path}</span>
    </button>
  );
}
