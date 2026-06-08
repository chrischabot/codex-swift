import { useState } from "react";
import { ChevronRight, RotateCcw } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  DEFAULT_GRAPH_SETTINGS,
  GRAPH_DEPTH_SLIDER,
  GRAPH_DISPLAY_SLIDERS,
  GRAPH_FORCE_SLIDERS,
  type GraphColorBy,
  type GraphSettings,
  type GraphSliderSpec,
} from "./GraphControls";

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
