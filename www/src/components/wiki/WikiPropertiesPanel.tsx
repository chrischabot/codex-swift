import type { WikiPage } from "@/runtime/connector";
import { cn } from "@/lib/utils";

interface Props {
  page: WikiPage;
}

// Keys whose values are rendered by other panels / the header, or are internal
// plumbing — never shown in the properties table.
const HIDDEN_KEYS = new Set(["id", "title", "content", "tags", "connections", "excerpt"]);

const HTTP_RE = /^https?:\/\//i;

/** Format an epoch-ms or ISO-ish value as a short local date string. */
function formatDate(value: unknown): string | null {
  let ts: number | null = null;
  if (typeof value === "number" && Number.isFinite(value)) {
    ts = value;
  } else if (typeof value === "string" && value.trim()) {
    const parsed = Date.parse(value);
    if (Number.isFinite(parsed)) ts = parsed;
  }
  if (ts === null) return null;
  const d = new Date(ts);
  if (Number.isNaN(d.getTime())) return null;
  return d.toLocaleString(undefined, {
    year: "numeric",
    month: "short",
    day: "numeric",
    hour: "2-digit",
    minute: "2-digit",
  });
}

/** Turn a camelCase / snake_case key into a human label ("sourceURI" → "Source URI"). */
function humanizeKey(key: string): string {
  const spaced = key
    .replace(/[_-]+/g, " ")
    .replace(/([a-z0-9])([A-Z])/g, "$1 $2")
    .replace(/\b(uri|url|id)\b/gi, (m) => m.toUpperCase());
  return spaced.charAt(0).toUpperCase() + spaced.slice(1);
}

/** Render a scalar value to a display string; returns null for empties. */
function stringifyScalar(value: unknown): string | null {
  if (value === null || value === undefined) return null;
  if (typeof value === "boolean") return value ? "true" : "false";
  if (typeof value === "number") return Number.isFinite(value) ? String(value) : null;
  if (typeof value === "string") {
    const trimmed = value.trim();
    return trimmed.length > 0 ? trimmed : null;
  }
  return null;
}

interface RowSpec {
  key: string;
  label: string;
  node: React.ReactNode;
  mono: boolean;
}

function buildRows(page: WikiPage): RowSpec[] {
  const rows: RowSpec[] = [];
  // Iterate over arbitrary scalar fields on the page record so future backend
  // fields surface automatically without code changes.
  const record = page as unknown as Record<string, unknown>;
  for (const [key, value] of Object.entries(record)) {
    if (HIDDEN_KEYS.has(key)) continue;

    // Date-ish keys: format. `updatedAt` is epoch ms per the connector contract.
    if (key === "updatedAt" || /(^|_|[a-z])(at|date|time)$/i.test(key)) {
      const formatted = formatDate(value);
      if (formatted) {
        rows.push({ key, label: humanizeKey(key), node: formatted, mono: false });
        continue;
      }
    }

    const text = stringifyScalar(value);
    if (text === null) continue;

    // Render http(s) values as links (e.g. sourceURI).
    if (HTTP_RE.test(text)) {
      rows.push({
        key,
        label: humanizeKey(key),
        mono: true,
        node: (
          <a
            href={text}
            target="_blank"
            rel="noreferrer"
            className="break-all text-[color:var(--text-link)] hover:underline"
          >
            {text}
          </a>
        ),
      });
      continue;
    }

    rows.push({ key, label: humanizeKey(key), node: text, mono: false });
  }
  return rows;
}

export function WikiPropertiesPanel({ page }: Props) {
  const rows = buildRows(page);

  if (rows.length === 0) {
    return (
      <div className="px-3 py-4 text-sm text-[color:var(--color-text-quaternary)]">
        No properties
      </div>
    );
  }

  return (
    <div className="flex flex-col">
      {rows.map((row) => (
        <div
          key={row.key}
          className="grid grid-cols-[minmax(5rem,38%)_1fr] items-baseline gap-x-3 border-b border-[color:var(--border)] px-3 py-1.5 last:border-b-0"
        >
          <span
            className="truncate text-sm text-[color:var(--color-text-tertiary)]"
            title={row.label}
          >
            {row.label}
          </span>
          <span
            className={cn(
              "min-w-0 break-words text-md text-foreground",
              row.mono && "font-mono text-sm",
            )}
          >
            {row.node}
          </span>
        </div>
      ))}
    </div>
  );
}
