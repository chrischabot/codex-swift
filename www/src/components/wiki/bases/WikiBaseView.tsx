// WikiBaseView.tsx — a database view over wiki pages. The base config lives in
// a wiki document (see basesSchema.ts); the rows ARE wiki pages selected by the
// base's source (a tag or a search query). Filtering / sorting / grouping all
// happen client-side over the fetched rows.
//
// Renders one of three layouts (table / list / cards) plus a toolbar to switch
// the view, edit the source, add/edit filters, set sort, and add/remove columns.

import * as React from "react";
import {
  ArrowDown,
  ArrowUp,
  ChevronDown,
  Columns3,
  Filter as FilterIcon,
  LayoutGrid,
  List as ListIcon,
  Loader2,
  MapPin,
  Plus,
  Table2,
  Tag,
  Trash2,
  X,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Badge } from "@/components/ui/badge";
import {
  Popover,
  PopoverContent,
  PopoverTrigger,
} from "@/components/ui/popover";
import { TableView, ListView, CardsView, MapView, KeySelect, columnKeyOptions } from "./baseViews";
import {
  type BaseConfig,
  type BaseFilter,
  type BaseViewType,
  type ColumnKey,
  type FilterOp,
  type SortDir,
  BUILTIN_COLUMNS,
  FILTER_OPS,
  FILTER_OP_LABEL,
  UNARY_OPS,
  applyFormulas,
  defaultColumnLabel,
  discoverColumnKeys,
  filterRows,
  groupRows,
  sortRows,
} from "./basesSchema";
import { useBaseDoc, useBaseRows } from "./useBaseDoc";

interface Props {
  pageId: string;
}

// ─────────────────────────────────────────────────────────────────────────────
// Top-level
// ─────────────────────────────────────────────────────────────────────────────

export function WikiBaseView({ pageId }: Props) {
  const { title, config, loading, saving, error, update } = useBaseDoc(pageId);
  const { rows: allRows, loading: rowsLoading, error: rowsError, editCell } = useBaseRows(config);

  // Compute formula columns first (their values are injected into row props), so
  // filter / sort / group / summaries all see them. Then filter → sort → group.
  const computedRows = React.useMemo(
    () => applyFormulas(allRows, config.columns),
    [allRows, config.columns],
  );
  const visibleRows = React.useMemo(() => {
    const filtered = filterRows(computedRows, config.filters);
    return sortRows(filtered, config.sort);
  }, [computedRows, config.filters, config.sort]);

  const grouped = React.useMemo(
    () => (config.group ? groupRows(visibleRows, config.group) : null),
    [visibleRows, config.group],
  );

  const discoveredKeys = React.useMemo(() => discoverColumnKeys(allRows), [allRows]);

  if (loading) {
    return (
      <div className="flex h-full items-center justify-center text-[color:var(--color-text-tertiary)]">
        <Loader2 className="mr-2 size-4 animate-spin" /> Loading base…
      </div>
    );
  }
  if (error) {
    return (
      <div className="flex h-full flex-col items-center justify-center gap-2 text-center text-[color:var(--color-text-tertiary)]">
        <Table2 className="size-8 opacity-50" />
        <div className="text-sm">{error}</div>
      </div>
    );
  }

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <Toolbar
        title={title}
        config={config}
        saving={saving}
        matchCount={visibleRows.length}
        discoveredKeys={discoveredKeys}
        onChange={update}
      />
      {rowsError && (
        <div className="mx-3 mt-2 rounded-md border border-[color:var(--color-red-500)]/30 bg-[color:var(--color-red-500)]/10 px-3 py-2 text-[12px] text-[color:var(--color-red-500)]">
          {rowsError}
        </div>
      )}
      <div className="min-h-0 flex-1 overflow-auto p-3">
        {rowsLoading ? (
          <div className="flex h-32 items-center justify-center text-[13px] text-[color:var(--color-text-tertiary)]">
            <Loader2 className="mr-2 size-4 animate-spin" /> Loading rows…
          </div>
        ) : visibleRows.length === 0 ? (
          <EmptyState hasSource={Boolean(config.source.tag || config.source.query)} />
        ) : config.view === "list" ? (
          <ListView config={config} rows={visibleRows} grouped={grouped} />
        ) : config.view === "cards" ? (
          <CardsView config={config} rows={visibleRows} grouped={grouped} />
        ) : config.view === "map" ? (
          <MapView config={config} rows={visibleRows} discoveredKeys={discoveredKeys} onChange={update} />
        ) : (
          <TableView config={config} rows={visibleRows} grouped={grouped} onChange={update} editCell={editCell} />
        )}
      </div>
    </div>
  );
}

function EmptyState({ hasSource }: { hasSource: boolean }) {
  return (
    <div className="flex h-48 flex-col items-center justify-center gap-2 text-center text-[color:var(--color-text-quaternary)]">
      <Table2 className="size-8 opacity-40" />
      <div className="text-[13px]">
        {hasSource ? "No pages match this base." : "Set a source (tag or query) to populate this base."}
      </div>
    </div>
  );
}

// ─────────────────────────────────────────────────────────────────────────────
// Toolbar
// ─────────────────────────────────────────────────────────────────────────────

const VIEW_OPTIONS: ReadonlyArray<{ key: BaseViewType; label: string; icon: typeof Table2 }> = [
  { key: "table", label: "Table", icon: Table2 },
  { key: "list", label: "List", icon: ListIcon },
  { key: "cards", label: "Cards", icon: LayoutGrid },
  { key: "map", label: "Map", icon: MapPin },
];

interface ToolbarProps {
  title: string;
  config: BaseConfig;
  saving: boolean;
  matchCount: number;
  discoveredKeys: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}

function Toolbar({ title, config, saving, matchCount, discoveredKeys, onChange }: ToolbarProps) {
  return (
    <div className="flex flex-wrap items-center gap-2 border-b border-[color:var(--border)] px-3 py-2">
      <span className="mr-1 text-[13px] font-medium text-foreground">{title || "Base"}</span>
      <span className="text-[12px] text-[color:var(--color-text-quaternary)]">
        {matchCount} {matchCount === 1 ? "row" : "rows"}
      </span>

      {/* VIEW SWITCH */}
      <div className="ml-2 inline-flex overflow-hidden rounded-lg border border-[color:var(--border)]">
        {VIEW_OPTIONS.map((v) => {
          const Icon = v.icon;
          const active = config.view === v.key;
          return (
            <button
              key={v.key}
              type="button"
              onClick={() => onChange({ ...config, view: v.key })}
              aria-pressed={active}
              className={cn(
                "flex items-center gap-1 px-2 py-1 text-[12px] transition-colors",
                active
                  ? "bg-[color:var(--color-surface-active)] text-foreground"
                  : "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]",
              )}
            >
              <Icon className="size-3.5" /> {v.label}
            </button>
          );
        })}
      </div>

      <SourcePopover config={config} onChange={onChange} />
      <FiltersPopover config={config} discoveredKeys={discoveredKeys} onChange={onChange} />
      <SortPopover config={config} discoveredKeys={discoveredKeys} onChange={onChange} />
      <ColumnsPopover config={config} discoveredKeys={discoveredKeys} onChange={onChange} />

      {saving && (
        <span className="ml-auto inline-flex items-center gap-1 text-[11px] text-[color:var(--color-text-quaternary)]">
          <Loader2 className="size-3 animate-spin" /> Saving…
        </span>
      )}
    </div>
  );
}

function ToolbarButton({
  icon: Icon,
  label,
  count,
}: {
  icon: typeof FilterIcon;
  label: string;
  count?: number;
}) {
  return (
    <Button variant="outline" size="xs" className="gap-1">
      <Icon className="size-3.5" />
      {label}
      {count ? (
        <Badge variant="default" className="ml-0.5 px-1 text-[10px]">
          {count}
        </Badge>
      ) : null}
      <ChevronDown className="size-3 opacity-60" />
    </Button>
  );
}

// ── Source ───────────────────────────────────────────────────────────────────

function SourcePopover({
  config,
  onChange,
}: {
  config: BaseConfig;
  onChange: (next: BaseConfig) => void;
}) {
  const [tag, setTag] = React.useState(config.source.tag ?? "");
  const [query, setQuery] = React.useState(config.source.query ?? "");
  React.useEffect(() => setTag(config.source.tag ?? ""), [config.source.tag]);
  React.useEffect(() => setQuery(config.source.query ?? ""), [config.source.query]);

  const commit = () => {
    const next: { tag?: string; query?: string } = {};
    if (tag.trim()) next.tag = tag.trim().replace(/^#/, "");
    if (query.trim()) next.query = query.trim();
    onChange({ ...config, source: next });
  };

  const summary = config.source.query
    ? `"${config.source.query}"`
    : config.source.tag
      ? `#${config.source.tag}`
      : "all";

  return (
    <Popover>
      <PopoverTrigger asChild>
        <Button variant="outline" size="xs" className="gap-1">
          <Tag className="size-3.5" />
          <span className="max-w-[10rem] truncate">{summary}</span>
          <ChevronDown className="size-3 opacity-60" />
        </Button>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-72 space-y-3">
        <div className="text-[12px] font-medium text-foreground">Source</div>
        <label className="block space-y-1">
          <span className="text-[11px] text-[color:var(--color-text-tertiary)]">Search query</span>
          <Input
            value={query}
            onChange={(e) => setQuery(e.currentTarget.value)}
            onBlur={commit}
            onKeyDown={(e) => e.key === "Enter" && commit()}
            placeholder="full-text query…"
            className="h-8 text-[13px]"
          />
        </label>
        <label className="block space-y-1">
          <span className="text-[11px] text-[color:var(--color-text-tertiary)]">Tag filter</span>
          <Input
            value={tag}
            onChange={(e) => setTag(e.currentTarget.value)}
            onBlur={commit}
            onKeyDown={(e) => e.key === "Enter" && commit()}
            placeholder="e.g. project"
            className="h-8 text-[13px]"
          />
        </label>
        <p className="text-[11px] leading-snug text-[color:var(--color-text-quaternary)]">
          A query searches the wiki; the tag further filters rows whose page has that tag. Leave both
          empty to list recent pages.
        </p>
      </PopoverContent>
    </Popover>
  );
}

// ── Filters ──────────────────────────────────────────────────────────────────

function FiltersPopover({
  config,
  discoveredKeys,
  onChange,
}: {
  config: BaseConfig;
  discoveredKeys: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}) {
  const keyOptions = columnKeyOptions(config, discoveredKeys);

  const setFilter = (i: number, patch: Partial<BaseFilter>) => {
    const filters = config.filters.map((f, idx) => (idx === i ? { ...f, ...patch } : f));
    onChange({ ...config, filters });
  };
  const removeFilter = (i: number) =>
    onChange({ ...config, filters: config.filters.filter((_, idx) => idx !== i) });
  const addFilter = () =>
    onChange({
      ...config,
      filters: [...config.filters, { key: keyOptions[0] ?? "title", op: "contains", value: "" }],
    });

  return (
    <Popover>
      <PopoverTrigger asChild>
        <span>
          <ToolbarButton icon={FilterIcon} label="Filter" count={config.filters.length} />
        </span>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-[24rem] space-y-2">
        <div className="text-[12px] font-medium text-foreground">Filters</div>
        {config.filters.length === 0 && (
          <div className="text-[12px] text-[color:var(--color-text-quaternary)]">No filters yet.</div>
        )}
        {config.filters.map((f, i) => (
          <div key={i} className="flex items-center gap-1">
            <KeySelect
              value={f.key}
              options={keyOptions}
              onChange={(key) => setFilter(i, { key })}
            />
            <select
              value={f.op}
              onChange={(e) => setFilter(i, { op: e.currentTarget.value as FilterOp })}
              className="h-8 rounded-md border border-[color:var(--border)] bg-transparent px-1 text-[12px] text-foreground"
            >
              {FILTER_OPS.map((op) => (
                <option key={op} value={op}>
                  {FILTER_OP_LABEL[op]}
                </option>
              ))}
            </select>
            {!UNARY_OPS.has(f.op) && (
              <Input
                value={f.value}
                onChange={(e) => setFilter(i, { value: e.currentTarget.value })}
                placeholder="value"
                className="h-8 flex-1 text-[12px]"
              />
            )}
            <Button variant="ghost" size="iconSm" onClick={() => removeFilter(i)} aria-label="Remove filter">
              <X className="size-3" />
            </Button>
          </div>
        ))}
        <Button variant="outline" size="xs" className="gap-1" onClick={addFilter}>
          <Plus className="size-3" /> Add filter
        </Button>
      </PopoverContent>
    </Popover>
  );
}

// ── Sort ─────────────────────────────────────────────────────────────────────

function SortPopover({
  config,
  discoveredKeys,
  onChange,
}: {
  config: BaseConfig;
  discoveredKeys: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}) {
  const keyOptions = columnKeyOptions(config, discoveredKeys);
  const setSort = (i: number, patch: { key?: ColumnKey; dir?: SortDir }) => {
    const sort = config.sort.map((s, idx) => (idx === i ? { ...s, ...patch } : s));
    onChange({ ...config, sort });
  };
  const removeSort = (i: number) =>
    onChange({ ...config, sort: config.sort.filter((_, idx) => idx !== i) });
  const addSort = () =>
    onChange({ ...config, sort: [...config.sort, { key: keyOptions[0] ?? "title", dir: "asc" }] });

  return (
    <Popover>
      <PopoverTrigger asChild>
        <span>
          <ToolbarButton icon={ArrowDown} label="Sort" count={config.sort.length} />
        </span>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-80 space-y-2">
        <div className="text-[12px] font-medium text-foreground">Sort</div>
        {config.sort.length === 0 && (
          <div className="text-[12px] text-[color:var(--color-text-quaternary)]">No sort.</div>
        )}
        {config.sort.map((s, i) => (
          <div key={i} className="flex items-center gap-1">
            <KeySelect value={s.key} options={keyOptions} onChange={(key) => setSort(i, { key })} />
            <Button
              variant="outline"
              size="xs"
              className="gap-1"
              onClick={() => setSort(i, { dir: s.dir === "asc" ? "desc" : "asc" })}
            >
              {s.dir === "asc" ? <ArrowUp className="size-3" /> : <ArrowDown className="size-3" />}
              {s.dir}
            </Button>
            <Button variant="ghost" size="iconSm" onClick={() => removeSort(i)} aria-label="Remove sort">
              <X className="size-3" />
            </Button>
          </div>
        ))}
        <div className="flex items-center justify-between pt-1">
          <Button variant="outline" size="xs" className="gap-1" onClick={addSort}>
            <Plus className="size-3" /> Add sort
          </Button>
          <GroupSelect config={config} keyOptions={keyOptions} onChange={onChange} />
        </div>
      </PopoverContent>
    </Popover>
  );
}

function GroupSelect({
  config,
  keyOptions,
  onChange,
}: {
  config: BaseConfig;
  keyOptions: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}) {
  return (
    <label className="flex items-center gap-1 text-[11px] text-[color:var(--color-text-tertiary)]">
      Group by
      <select
        value={config.group ?? ""}
        onChange={(e) => {
          const v = e.currentTarget.value;
          const next = { ...config };
          if (v) next.group = v as ColumnKey;
          else delete (next as { group?: ColumnKey }).group;
          onChange(next);
        }}
        className="h-7 rounded-md border border-[color:var(--border)] bg-transparent px-1 text-[12px] text-foreground"
      >
        <option value="">none</option>
        {keyOptions.map((k) => (
          <option key={k} value={k}>
            {defaultColumnLabel(k)}
          </option>
        ))}
      </select>
    </label>
  );
}

// ── Columns ──────────────────────────────────────────────────────────────────

function ColumnsPopover({
  config,
  discoveredKeys,
  onChange,
}: {
  config: BaseConfig;
  discoveredKeys: ColumnKey[];
  onChange: (next: BaseConfig) => void;
}) {
  const present = new Set(config.columns.map((c) => c.key));
  const available = [...BUILTIN_COLUMNS, ...discoveredKeys].filter((k) => !present.has(k));

  const addColumn = (key: ColumnKey) =>
    onChange({ ...config, columns: [...config.columns, { key, label: defaultColumnLabel(key) }] });
  const removeColumn = (key: ColumnKey) =>
    onChange({ ...config, columns: config.columns.filter((c) => c.key !== key) });
  const relabel = (key: ColumnKey, label: string) =>
    onChange({
      ...config,
      columns: config.columns.map((c) => (c.key === key ? { ...c, label } : c)),
    });
  const setFormula = (key: ColumnKey, formula: string) =>
    onChange({
      ...config,
      columns: config.columns.map((c) =>
        c.key === key ? (formula.trim() ? { ...c, formula } : { key: c.key, label: c.label }) : c,
      ),
    });
  const addFormulaColumn = () => {
    // A unique synthetic key so the computed value has a stable home in props.
    let n = 1;
    const keys = new Set(config.columns.map((c) => c.key));
    while (keys.has(`formula_${n}`)) n++;
    const key = `formula_${n}`;
    onChange({ ...config, columns: [...config.columns, { key, label: `Formula ${n}`, formula: "" }] });
  };

  return (
    <Popover>
      <PopoverTrigger asChild>
        <span>
          <ToolbarButton icon={Columns3} label="Columns" count={config.columns.length} />
        </span>
      </PopoverTrigger>
      <PopoverContent align="start" className="w-72 space-y-2">
        <div className="text-[12px] font-medium text-foreground">Columns</div>
        {config.columns.map((c) => (
          <div key={c.key} className="space-y-1">
            <div className="flex items-center gap-1">
              <Input
                value={c.label}
                onChange={(e) => relabel(c.key, e.currentTarget.value)}
                className="h-8 flex-1 text-[12px]"
              />
              <span className="max-w-[6rem] truncate text-[11px] text-[color:var(--color-text-quaternary)]">
                {c.formula !== undefined ? "ƒ" : c.key}
              </span>
              <Button variant="ghost" size="iconSm" onClick={() => removeColumn(c.key)} aria-label="Remove column">
                <Trash2 className="size-3" />
              </Button>
            </div>
            {c.formula !== undefined && (
              <Input
                value={c.formula}
                onChange={(e) => setFormula(c.key, e.currentTarget.value)}
                placeholder="formula, e.g. round(price * qty, 2)"
                className="h-7 w-full font-mono text-[11px]"
                aria-label={`${c.label} formula`}
              />
            )}
          </div>
        ))}
        <div className="border-t border-[color:var(--border)] pt-2">
          {available.length > 0 && (
            <>
              <div className="mb-1 text-[11px] text-[color:var(--color-text-tertiary)]">Add column</div>
              <div className="mb-2 flex flex-wrap gap-1">
                {available.map((k) => (
                  <Button
                    key={k}
                    variant="outline"
                    size="xs"
                    className="gap-1"
                    onClick={() => addColumn(k)}
                  >
                    <Plus className="size-3" /> {defaultColumnLabel(k)}
                  </Button>
                ))}
              </div>
            </>
          )}
          <Button variant="outline" size="xs" className="gap-1" onClick={addFormulaColumn}>
            <Plus className="size-3" /> Formula column
          </Button>
        </div>
      </PopoverContent>
    </Popover>
  );
}

