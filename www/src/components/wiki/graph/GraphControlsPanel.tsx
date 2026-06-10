import { useState } from "react";
import { ChevronRight, Plus, RotateCcw, X } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  DEFAULT_GRAPH_SETTINGS,
  GRAPH_DEPTH_SLIDER,
  GRAPH_DISPLAY_SLIDERS,
  GRAPH_FORCE_SLIDERS,
  type GraphColorBy,
  type GraphColorGroup,
  type GraphSettings,
  type GraphSliderSpec,
} from "./GraphControls";

/** Default color offered when adding a new group (first of the palette). */
const NEW_GROUP_COLOR = "#4aa3ff";

/** Best-effort unique id for a new color group (crypto when available). */
function newGroupId(): string {
  const c = typeof crypto !== "undefined" ? crypto : undefined;
  if (c && typeof c.randomUUID === "function") return c.randomUUID();
  return `grp-${Date.now().toString(36)}-${Math.floor(Math.random() * 1e6).toString(36)}`;
}

interface Props {
  settings: GraphSettings;
  onChange: (settings: GraphSettings) => void;
}

type SectionId = "filters" | "display" | "forces";

/**
 * Obsidian-style floating controls for the wiki graph view. A compact,
 * self-contained, controlled panel: the graph view owns the {@link GraphSettings}
 * state and passes value+onChange. Dependency-light — plain range inputs and a
 * native select styled with www tokens.
 */
export function GraphControlsPanel({ settings, onChange }: Props) {
  const [open, setOpen] = useState<Record<SectionId, boolean>>({
    filters: true,
    display: true,
    forces: false,
  });

  const set = <K extends keyof GraphSettings>(key: K, value: GraphSettings[K]) => {
    onChange({ ...settings, [key]: value });
  };

  const toggle = (id: SectionId) => setOpen((prev) => ({ ...prev, [id]: !prev[id] }));

  return (
    <div
      className={cn(
        "pointer-events-auto flex w-56 flex-col overflow-hidden rounded-lg",
        "border border-[color:var(--border)] bg-[color:var(--background)]/95 backdrop-blur",
        "text-foreground shadow-lg",
      )}
      // Stop pan/zoom handlers on the canvas behind the panel from firing.
      onMouseDown={(e) => e.stopPropagation()}
      onWheel={(e) => e.stopPropagation()}
    >
      <div className="flex items-center justify-between border-b border-[color:var(--border)] px-2.5 py-1.5">
        <span className="text-sm font-semibold uppercase tracking-[0.05em] text-[color:var(--color-text-tertiary)]">
          Graph
        </span>
        <button
          type="button"
          onClick={() => onChange({ ...DEFAULT_GRAPH_SETTINGS })}
          title="Reset to defaults"
          aria-label="Reset graph settings to defaults"
          className={cn(
            "flex items-center gap-1 rounded px-1.5 py-0.5 text-sm",
            "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
          )}
        >
          <RotateCcw size={11} />
          Reset
        </button>
      </div>

      <Section
        id="filters"
        title="Filters"
        open={open.filters}
        onToggle={() => toggle("filters")}
      >
        <Field label="Filter">
          <input
            type="text"
            value={settings.textFilter}
            onChange={(e) => set("textFilter", e.currentTarget.value)}
            placeholder="Label, or kind:person"
            aria-label="Filter nodes by label or kind"
            spellCheck={false}
            autoComplete="off"
            autoCapitalize="off"
            className={cn(
              "w-full rounded border border-[color:var(--border)] bg-transparent px-1.5 py-1 text-sm",
              "text-foreground placeholder:text-[color:var(--color-text-quaternary)]",
              "focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
            )}
          />
        </Field>
        <Field label="Color by">
          <select
            value={settings.colorBy}
            onChange={(e) => set("colorBy", e.currentTarget.value as GraphColorBy)}
            className={cn(
              "w-full rounded border border-[color:var(--border)] bg-transparent px-1.5 py-1 text-sm",
              "text-foreground focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
            )}
          >
            <option value="kind">Entity kind</option>
            <option value="none">Neutral</option>
          </select>
        </Field>
        <ColorGroupsEditor
          groups={settings.colorGroups}
          onChange={(groups) => set("colorGroups", groups)}
        />
        <SliderRow spec={GRAPH_DEPTH_SLIDER} value={settings.depth} onChange={set} />
        <p className="text-[11px] leading-snug text-[color:var(--color-text-quaternary)]">
          Depth controls how many hops out from a selected entity are explored.
        </p>
      </Section>

      <Section
        id="display"
        title="Display"
        open={open.display}
        onToggle={() => toggle("display")}
      >
        {GRAPH_DISPLAY_SLIDERS.map((spec) => (
          <SliderRow
            key={spec.key}
            spec={spec}
            value={settings[spec.key] as number}
            onChange={set}
          />
        ))}
      </Section>

      <Section
        id="forces"
        title="Forces"
        open={open.forces}
        onToggle={() => toggle("forces")}
        last
      >
        {GRAPH_FORCE_SLIDERS.map((spec) => (
          <SliderRow
            key={spec.key}
            spec={spec}
            value={settings[spec.key] as number}
            onChange={set}
          />
        ))}
      </Section>
    </div>
  );
}

interface SectionProps {
  id: SectionId;
  title: string;
  open: boolean;
  onToggle: () => void;
  last?: boolean;
  children: React.ReactNode;
}

function Section({ title, open, onToggle, last, children }: SectionProps) {
  return (
    <div className={cn(!last && "border-b border-[color:var(--border)]")}>
      <button
        type="button"
        onClick={onToggle}
        aria-expanded={open}
        className={cn(
          "flex w-full items-center gap-1 px-2.5 py-1.5 text-left",
          "text-sm font-semibold uppercase tracking-[0.05em] text-[color:var(--color-text-tertiary)]",
          "hover:text-foreground",
        )}
      >
        <ChevronRight
          size={12}
          className={cn("transition-transform", open && "rotate-90")}
        />
        {title}
      </button>
      {open ? <div className="flex flex-col gap-2 px-2.5 pb-2.5 pt-0.5">{children}</div> : null}
    </div>
  );
}

interface FieldProps {
  label: string;
  children: React.ReactNode;
}

function Field({ label, children }: FieldProps) {
  return (
    <label className="flex flex-col gap-1">
      <span className="text-[11px] font-medium text-[color:var(--color-text-secondary)]">
        {label}
      </span>
      {children}
    </label>
  );
}

interface ColorGroupsEditorProps {
  groups: ReadonlyArray<GraphColorGroup>;
  onChange: (groups: GraphColorGroup[]) => void;
}

/**
 * Compact CRUD editor for color groups. Each group is a {query, color} pair:
 * the query is a label substring or a `kind:` prefix; matching nodes render in
 * the chosen color (first match wins, overriding the default colorBy). Rows
 * edit in place; the trailing "Add group" button appends an empty group.
 */
function ColorGroupsEditor({ groups, onChange }: ColorGroupsEditorProps) {
  const update = (id: string, patch: Partial<GraphColorGroup>) =>
    onChange(groups.map((g) => (g.id === id ? { ...g, ...patch } : g)));
  const remove = (id: string) => onChange(groups.filter((g) => g.id !== id));
  const add = () =>
    onChange([...groups, { id: newGroupId(), query: "", color: NEW_GROUP_COLOR }]);

  return (
    <div className="flex flex-col gap-1.5">
      <span className="text-[11px] font-medium text-[color:var(--color-text-secondary)]">
        Color groups
      </span>
      {groups.length === 0 ? (
        <p className="text-[11px] leading-snug text-[color:var(--color-text-quaternary)]">
          No groups. Add one to tint matching nodes (label or <code>kind:</code>).
        </p>
      ) : (
        <ul className="flex flex-col gap-1">
          {groups.map((g) => (
            <li key={g.id} className="flex items-center gap-1.5">
              <input
                type="color"
                value={g.color}
                onChange={(e) => update(g.id, { color: e.currentTarget.value })}
                aria-label="Group color"
                className="h-6 w-6 shrink-0 cursor-pointer rounded border border-[color:var(--border)] bg-transparent p-0.5"
              />
              <input
                type="text"
                value={g.query}
                onChange={(e) => update(g.id, { query: e.currentTarget.value })}
                placeholder="Label or kind:x"
                aria-label="Group query"
                spellCheck={false}
                autoComplete="off"
                autoCapitalize="off"
                className={cn(
                  "min-w-0 flex-1 rounded border border-[color:var(--border)] bg-transparent px-1.5 py-1 text-sm",
                  "text-foreground placeholder:text-[color:var(--color-text-quaternary)]",
                  "focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
                )}
              />
              <button
                type="button"
                onClick={() => remove(g.id)}
                title="Remove group"
                aria-label="Remove color group"
                className={cn(
                  "flex h-6 w-6 shrink-0 items-center justify-center rounded",
                  "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
                )}
              >
                <X size={12} />
              </button>
            </li>
          ))}
        </ul>
      )}
      <button
        type="button"
        onClick={add}
        className={cn(
          "flex items-center justify-center gap-1 rounded border border-dashed py-1 text-[11px] font-medium",
          "border-[color:var(--border)] text-[color:var(--color-text-tertiary)]",
          "hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
        )}
      >
        <Plus size={11} />
        Add group
      </button>
    </div>
  );
}

interface SliderRowProps {
  spec: GraphSliderSpec;
  value: number;
  onChange: <K extends keyof GraphSettings>(key: K, value: GraphSettings[K]) => void;
}

function SliderRow({ spec, value, onChange }: SliderRowProps) {
  const display = Number.isInteger(spec.step) && Number.isInteger(value)
    ? String(value)
    : value.toFixed(spec.step < 0.01 ? 4 : spec.step < 1 ? 3 : 0);
  return (
    <label className="flex flex-col gap-0.5">
      <span className="flex items-center justify-between text-[11px] font-medium text-[color:var(--color-text-secondary)]">
        <span>{spec.label}</span>
        <span className="tabular-nums text-[color:var(--color-text-quaternary)]">{display}</span>
      </span>
      <input
        type="range"
        min={spec.min}
        max={spec.max}
        step={spec.step}
        value={value}
        aria-label={spec.label}
        onChange={(e) => onChange(spec.key, Number(e.currentTarget.value) as never)}
        className={cn(
          "h-1 w-full cursor-pointer appearance-none rounded-full",
          "bg-[color:var(--color-surface-hover)] accent-[color:var(--text-link)]",
        )}
      />
    </label>
  );
}
