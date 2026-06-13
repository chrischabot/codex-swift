// The base view renderers (table / list / cards / map) + their shared cell
// helpers + the column key-select, extracted from WikiBaseView so the god
// component stays a layout + toolbar shell. Pure presentation over a fetched
// row set; all the data ops live in basesSchema.ts.

import * as React from "react";
import { useNavigate } from "react-router-dom";
import { ArrowDown, ArrowUp, MapPin } from "lucide-react";
import { Badge } from "@/components/ui/badge";
import { toast } from "@/components/ui/sonner";
import { computeSummary, SUMMARY_OPS, SUMMARY_LABEL, type SummaryOp } from "./baseSummaries";
import {
  type BaseConfig,
  type BaseRow,
  type ColumnKey,
  BUILTIN_COLUMNS,
  cellValue,
  collectMapPoints,
  defaultColumnLabel,
  formatCell,
  formulaColumnKeys,
} from "./basesSchema";

// ── Column key select ─────────────────────────────────────────────────────────

export function KeySelect({
  value,
  options,
  onChange,
}: {
  value: ColumnKey;
  options: ColumnKey[];
  onChange: (key: ColumnKey) => void;
}) {
  // Ensure the current value is always selectable even if not in `options`.
  const opts = options.includes(value) ? options : [value, ...options];
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.currentTarget.value as ColumnKey)}
      className="h-8 max-w-[8rem] rounded-md border border-[color:var(--border)] bg-transparent px-1 text-[12px] text-foreground"
    >
      {opts.map((k) => (
        <option key={k} value={k}>
          {defaultColumnLabel(k)}
        </option>
      ))}
    </select>
  );
}

/** Built-in + configured-column + discovered keys, de-duplicated. */
export function columnKeyOptions(config: BaseConfig, discoveredKeys: ColumnKey[]): ColumnKey[] {
  const seen = new Set<ColumnKey>();
  const out: ColumnKey[] = [];
  for (const k of [...BUILTIN_COLUMNS, ...config.columns.map((c) => c.key), ...discoveredKeys]) {
    if (!seen.has(k)) {
      seen.add(k);
      out.push(k);
    }
  }
  return out;
}

// ── Row open ──────────────────────────────────────────────────────────────────

function useOpenRow() {
  const navigate = useNavigate();
  return React.useCallback((row: BaseRow) => navigate(`/wiki/${row.page.id}`), [navigate]);
}

// ── Cell rendering ────────────────────────────────────────────────────────────

/** Is a column an editable scalar frontmatter property on this row? Built-in
 *  pseudo-columns and array (list/tags) values are not inline-editable. */
function isEditableCell(row: BaseRow, columnKey: ColumnKey, formulaKeys: Set<ColumnKey>): boolean {
  if ((BUILTIN_COLUMNS as string[]).includes(columnKey)) return false;
  if (formulaKeys.has(columnKey)) return false; // computed column → not a write target
  if (row.content == null) return false; // summary-only row → no write target
  const v = cellValue(row, columnKey);
  return !Array.isArray(v) && typeof v !== "object";
}

/**
 * An inline-editable scalar property cell. Click (or focus + Enter) enters edit
 * mode with an input; Enter/blur commits via `onCommit`, Escape cancels. Clicks
 * are stopped from bubbling so they don't trigger the row's open-on-click.
 */
function EditableCell({
  value,
  columnKey,
  onCommit,
}: {
  value: unknown;
  columnKey: ColumnKey;
  onCommit: (next: string) => Promise<string | null>;
}) {
  const initial = formatCell(value, columnKey);
  const [editing, setEditing] = React.useState(false);
  const [draft, setDraft] = React.useState(initial);
  const [busy, setBusy] = React.useState(false);

  const start = (e: React.MouseEvent) => {
    e.stopPropagation();
    setDraft(initial);
    setEditing(true);
  };
  const commit = async () => {
    if (busy) return;
    if (draft === initial) {
      setEditing(false);
      return;
    }
    setBusy(true);
    const err = await onCommit(draft);
    setBusy(false);
    setEditing(false);
    if (err) toast.error(err);
  };

  if (!editing) {
    return (
      <button
        type="button"
        onClick={start}
        title="Click to edit"
        className="-mx-1 min-h-[1.4em] w-[calc(100%+0.5rem)] rounded px-1 text-left hover:bg-[color:var(--color-surface-active)]"
      >
        {initial || <span className="text-[color:var(--color-text-quaternary)]">—</span>}
      </button>
    );
  }
  return (
    <input
      autoFocus
      value={draft}
      disabled={busy}
      onClick={(e) => e.stopPropagation()}
      onChange={(e) => setDraft(e.currentTarget.value)}
      onBlur={() => void commit()}
      onKeyDown={(e) => {
        e.stopPropagation();
        if (e.key === "Enter") {
          e.preventDefault();
          void commit();
        } else if (e.key === "Escape") {
          e.preventDefault();
          setEditing(false);
        }
      }}
      className="w-full rounded border border-[color:var(--text-link)] bg-[color:var(--color-card)] px-1 py-0.5 text-[13px] text-foreground outline-none"
    />
  );
}

function CellContent({ value, columnKey }: { value: unknown; columnKey: ColumnKey }) {
  if (columnKey === "tags" && Array.isArray(value)) {
    return (
      <span className="inline-flex flex-wrap gap-1">
        {value.map((t, i) => (
          <Badge key={`${String(t)}-${i}`} variant="outline" className="text-[10px]">
            #{String(t)}
          </Badge>
        ))}
      </span>
    );
  }
  if (columnKey === "source" && value) {
    return (
      <Badge variant="outline" className="text-[10px]">
        {String(value)}
      </Badge>
    );
  }
  return <>{formatCell(value, columnKey)}</>;
}

export interface ViewProps {
  config: BaseConfig;
  rows: ReadonlyArray<BaseRow>;
  grouped: Map<string, BaseRow[]> | null;
}

// ── Table view (sortable headers, click row → open) ────────────────────────────

export function TableView({
  config,
  rows,
  grouped,
  onChange,
  editCell,
}: ViewProps & {
  onChange: (next: BaseConfig) => void;
  editCell: (pageId: string, key: ColumnKey, value: string) => Promise<string | null>;
}) {
  const open = useOpenRow();
  const cols = config.columns;
  const formulaKeys = React.useMemo(() => formulaColumnKeys(cols), [cols]);

  const sortFor = (key: ColumnKey) => config.sort.find((s) => s.key === key);
  const toggleSort = (key: ColumnKey) => {
    const cur = sortFor(key);
    // Single-key sort on header click (replace the sort list).
    if (!cur) onChange({ ...config, sort: [{ key, dir: "asc" }] });
    else onChange({ ...config, sort: [{ key, dir: cur.dir === "asc" ? "desc" : "asc" }] });
  };

  const renderRows = (rs: ReadonlyArray<BaseRow>) =>
    rs.map((row) => (
      <tr
        key={row.page.id}
        tabIndex={0}
        onClick={() => open(row)}
        onKeyDown={(e) => {
          if (e.key === "Enter" || e.key === " ") {
            e.preventDefault();
            open(row);
          }
        }}
        className="cursor-pointer border-b border-[color:var(--border)] transition-colors hover:bg-[color:var(--color-surface-hover)] focus:bg-[color:var(--color-surface-hover)] focus:outline-none"
      >
        {cols.map((c) => (
          <td key={c.key} className="px-3 py-2 align-top text-[13px] text-foreground">
            {isEditableCell(row, c.key, formulaKeys) ? (
              <EditableCell
                value={cellValue(row, c.key)}
                columnKey={c.key}
                onCommit={(next) => editCell(row.page.id, c.key, next)}
              />
            ) : (
              <CellContent value={cellValue(row, c.key)} columnKey={c.key} />
            )}
          </td>
        ))}
      </tr>
    ));

  return (
    <table className="w-full border-collapse text-left">
      <thead>
        <tr className="border-b border-[color:var(--border)]">
          {cols.map((c) => {
            const s = sortFor(c.key);
            return (
              <th key={c.key} className="px-3 py-2 text-[11px] font-medium text-[color:var(--color-text-tertiary)]">
                <button
                  type="button"
                  onClick={() => toggleSort(c.key)}
                  className="inline-flex items-center gap-1 hover:text-foreground"
                >
                  {c.label}
                  {s && (s.dir === "asc" ? <ArrowUp className="size-3" /> : <ArrowDown className="size-3" />)}
                </button>
              </th>
            );
          })}
        </tr>
      </thead>
      <tbody>
        {grouped
          ? [...grouped.entries()].flatMap(([label, rs]) => [
              <tr key={`g-${label}`}>
                <td
                  colSpan={cols.length}
                  className="bg-[color:var(--color-surface-hover)] px-3 py-1.5 text-[11px] font-medium text-[color:var(--color-text-secondary)]"
                >
                  {label} · {rs.length}
                </td>
              </tr>,
              ...renderRows(rs),
            ])
          : renderRows(rows)}
      </tbody>
      <tfoot>
        <tr className="border-t-2 border-[color:var(--border)]">
          {cols.map((c) => {
            const op = (config.summaries?.[c.key] ?? "none") as SummaryOp;
            const value = computeSummary(rows, c.key, op);
            const setOp = (next: SummaryOp) => {
              const rest = { ...(config.summaries ?? {}) };
              if (next === "none") delete rest[c.key];
              else rest[c.key] = next;
              onChange({ ...config, summaries: rest });
            };
            return (
              <td key={c.key} className="px-3 py-1.5 align-middle text-[12px] text-[color:var(--color-text-tertiary)]">
                <span className="inline-flex items-center gap-1">
                  <select
                    aria-label={`${c.label} summary`}
                    value={op}
                    onChange={(e) => setOp(e.currentTarget.value as SummaryOp)}
                    className="cursor-pointer rounded border-0 bg-transparent text-[11px] text-[color:var(--color-text-quaternary)] hover:text-foreground focus:outline-none"
                  >
                    {SUMMARY_OPS.map((o) => (
                      <option key={o} value={o}>{SUMMARY_LABEL[o]}</option>
                    ))}
                  </select>
                  {value && <span className="font-medium tabular-nums text-[color:var(--color-text-secondary)]">{value}</span>}
                </span>
              </td>
            );
          })}
        </tr>
      </tfoot>
    </table>
  );
}

// ── List view ──────────────────────────────────────────────────────────────────

export function ListView({ config, rows, grouped }: ViewProps) {
  const open = useOpenRow();
  const metaCols = config.columns.filter((c) => c.key !== "title");

  const renderRows = (rs: ReadonlyArray<BaseRow>) =>
    rs.map((row) => (
      <button
        key={row.page.id}
        type="button"
        onClick={() => open(row)}
        className="flex w-full flex-col items-start gap-1 rounded-md border border-transparent px-3 py-2 text-left transition-colors hover:border-[color:var(--border)] hover:bg-[color:var(--color-surface-hover)]"
      >
        <span className="text-[14px] font-medium text-foreground">{row.page.title}</span>
        {metaCols.length > 0 && (
          <span className="flex flex-wrap gap-x-3 gap-y-1 text-[12px] text-[color:var(--color-text-tertiary)]">
            {metaCols.map((c) => {
              const val = cellValue(row, c.key);
              const text = formatCell(val, c.key);
              if (!text) return null;
              return (
                <span key={c.key} className="inline-flex items-center gap-1">
                  <span className="text-[color:var(--color-text-quaternary)]">{c.label}:</span>
                  <CellContent value={val} columnKey={c.key} />
                </span>
              );
            })}
          </span>
        )}
      </button>
    ));

  return (
    <div className="flex flex-col gap-1">
      {grouped
        ? [...grouped.entries()].map(([label, rs]) => (
            <div key={label} className="flex flex-col gap-1">
              <div className="px-3 pt-2 text-[11px] font-medium text-[color:var(--color-text-secondary)]">
                {label} · {rs.length}
              </div>
              {renderRows(rs)}
            </div>
          ))
        : renderRows(rows)}
    </div>
  );
}

// ── Cards view ─────────────────────────────────────────────────────────────────

export function CardsView({ config, rows, grouped }: ViewProps) {
  const open = useOpenRow();
  const kvCols = config.columns.filter((c) => c.key !== "title");

  const renderGrid = (rs: ReadonlyArray<BaseRow>) => (
    <div className="grid grid-cols-[repeat(auto-fill,minmax(15rem,1fr))] gap-2">
      {rs.map((row) => (
        <button
          key={row.page.id}
          type="button"
          onClick={() => open(row)}
          className="flex flex-col gap-2 rounded-lg border border-[color:var(--border)] p-3 text-left transition-colors hover:bg-[color:var(--color-surface-hover)]"
        >
          <span className="truncate text-[14px] font-medium text-foreground">{row.page.title}</span>
          <div className="grid grid-cols-[auto_1fr] gap-x-2 gap-y-1">
            {kvCols.map((c) => (
              <React.Fragment key={c.key}>
                <span className="text-[11px] text-[color:var(--color-text-quaternary)]">{c.label}</span>
                <span className="min-w-0 truncate text-[12px] text-[color:var(--color-text-secondary)]">
                  <CellContent value={cellValue(row, c.key)} columnKey={c.key} />
                </span>
              </React.Fragment>
            ))}
          </div>
        </button>
      ))}
    </div>
  );

  return (
    <div className="flex flex-col gap-3">
      {grouped
        ? [...grouped.entries()].map(([label, rs]) => (
            <div key={label} className="flex flex-col gap-2">
              <div className="text-[11px] font-medium text-[color:var(--color-text-secondary)]">
                {label} · {rs.length}
              </div>
              {renderGrid(rs)}
            </div>
          ))
        : renderGrid(rows)}
    </div>
  );
}

// ── Map view (geographic — rows with lat/long frontmatter on a world box) ──────

export function MapView({
  config,
  rows,
  discoveredKeys,
  onChange,
}: {
  config: BaseConfig;
  rows: ReadonlyArray<BaseRow>;
  discoveredKeys: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}) {
  const open = useOpenRow();
  const keyOptions = columnKeyOptions(config, discoveredKeys);
  const points = React.useMemo(() => collectMapPoints(rows, config), [rows, config]);
  const configured = Boolean(config.mapLatitude && config.mapLongitude);

  return (
    <div className="flex flex-col gap-2">
      <div className="flex flex-wrap items-center gap-2 text-[12px] text-[color:var(--color-text-tertiary)]">
        <span>Latitude</span>
        <KeySelect
          value={config.mapLatitude ?? ""}
          options={keyOptions}
          onChange={(key) => onChange({ ...config, mapLatitude: key })}
        />
        <span>Longitude</span>
        <KeySelect
          value={config.mapLongitude ?? ""}
          options={keyOptions}
          onChange={(key) => onChange({ ...config, mapLongitude: key })}
        />
        <span className="text-[color:var(--color-text-quaternary)]">
          {configured ? `${points.length} of ${rows.length} placed` : "pick lat/long properties"}
        </span>
      </div>

      {/* Equirectangular plot box (2:1). Points sit at their projected %. */}
      <div className="relative w-full overflow-hidden rounded-md border border-[color:var(--border)] bg-[color:var(--code-surface)]" style={{ aspectRatio: "2 / 1" }}>
        {/* graticule */}
        <div className="pointer-events-none absolute inset-0">
          <div className="absolute left-1/2 top-0 h-full w-px bg-[color:var(--border)]" />
          <div className="absolute left-0 top-1/2 h-px w-full bg-[color:var(--border)]" />
        </div>
        {!configured ? (
          <div className="absolute inset-0 flex items-center justify-center text-[12px] text-[color:var(--color-text-quaternary)]">
            Choose which properties hold latitude and longitude.
          </div>
        ) : points.length === 0 ? (
          <div className="absolute inset-0 flex items-center justify-center text-[12px] text-[color:var(--color-text-quaternary)]">
            No rows have valid coordinates.
          </div>
        ) : (
          points.map((p) => (
            <button
              key={p.row.page.id}
              type="button"
              onClick={() => open(p.row)}
              title={`${p.row.page.title} (${p.lat}, ${p.lng})`}
              style={{ left: `${p.xPct}%`, top: `${p.yPct}%` }}
              className="absolute -translate-x-1/2 -translate-y-1/2"
            >
              <MapPin className="size-4 text-[color:var(--text-link)] drop-shadow hover:scale-125" />
            </button>
          ))
        )}
      </div>
    </div>
  );
}
