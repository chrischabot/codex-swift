import * as React from "react";
import { Pencil, BookOpen, Network, Settings2, RotateCcw } from "lucide-react";
import { cn } from "@/lib/utils";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogDescription,
} from "@/components/ui/dialog";
import { ScrollArea } from "@/components/ui/scroll-area";
import { Switch } from "@/components/ui/switch";
import { Input } from "@/components/ui/input";
import {
  GRAPH_DISPLAY_SLIDERS,
  GRAPH_FORCE_SLIDERS,
  type GraphSettings,
  type GraphSliderSpec,
} from "../graph/GraphControls";
import {
  EDITOR_FONT_RANGE,
  READING_FONT_RANGE,
  WIKI_RAIL_TABS,
  useWikiSettings,
  type WikiRailTab,
} from "./useWikiSettings";

export interface WikiSettingsModalProps {
  open: boolean;
  onOpenChange: (open: boolean) => void;
}

type SectionId = "editor" | "reading" | "graph" | "general";

const SECTIONS: ReadonlyArray<{ id: SectionId; label: string; icon: React.ReactNode }> = [
  { id: "editor", label: "Editor", icon: <Pencil size={15} /> },
  { id: "reading", label: "Reading", icon: <BookOpen size={15} /> },
  { id: "graph", label: "Graph", icon: <Network size={15} /> },
  { id: "general", label: "General", icon: <Settings2 size={15} /> },
];

const RAIL_TAB_LABELS: Record<WikiRailTab, string> = {
  connections: "Links",
  graph: "Graph",
  tags: "Tags",
  outline: "Outline",
  bookmarks: "Saved",
  properties: "Info",
};

/**
 * Obsidian-style wiki Settings dialog: a left section nav + a right scrolling
 * pane of labeled controls. A www-idiomatic port of granite's SettingsModal,
 * rescoped to the preferences this wiki actually exposes (editor / reading /
 * graph / general) and bound to the localStorage-backed {@link useWikiSettings}.
 */
export function WikiSettingsModal({ open, onOpenChange }: WikiSettingsModalProps) {
  const { settings, update, updateGraph, reset } = useWikiSettings();
  const [section, setSection] = React.useState<SectionId>("editor");

  return (
    <Dialog open={open} onOpenChange={onOpenChange}>
      <DialogContent
        className="grid max-w-[min(46rem,94vw)] grid-rows-[auto_minmax(0,1fr)] gap-0 overflow-hidden p-0"
        // The modal is tall; let the right pane own its own scroll.
      >
        <DialogHeader className="border-b border-[color:var(--border)] px-5 py-4">
          <DialogTitle>Wiki settings</DialogTitle>
          <DialogDescription>
            Preferences are saved locally in this browser and sync across tabs.
          </DialogDescription>
        </DialogHeader>

        <div className="grid min-h-0 grid-cols-[10rem_minmax(0,1fr)]">
          {/* LEFT — section nav */}
          <nav className="flex min-h-0 flex-col gap-0.5 border-r border-[color:var(--border)] p-2">
            {SECTIONS.map((s) => (
              <button
                key={s.id}
                type="button"
                onClick={() => setSection(s.id)}
                aria-current={section === s.id}
                className={cn(
                  "flex items-center gap-2 rounded-md px-2.5 py-1.5 text-left text-sm transition-colors",
                  section === s.id
                    ? "bg-[color:var(--color-surface-hover)] font-medium text-foreground"
                    : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
                )}
              >
                <span className="shrink-0 text-[color:var(--color-text-tertiary)]">{s.icon}</span>
                {s.label}
              </button>
            ))}
            <button
              type="button"
              onClick={reset}
              className={cn(
                "mt-auto flex items-center gap-2 rounded-md px-2.5 py-1.5 text-left text-sm",
                "text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
              )}
            >
              <RotateCcw size={14} className="shrink-0" />
              Reset all
            </button>
          </nav>

          {/* RIGHT — controls for the active section */}
          <ScrollArea className="min-h-0">
            <div className="flex flex-col px-5 py-4">
              {section === "editor" && (
                <Group title="Editor">
                  <Row
                    name="Live preview"
                    desc="Render markdown inline as you type instead of raw source."
                    control={
                      <Switch
                        checked={settings.editorLivePreview}
                        onCheckedChange={(v) => update({ editorLivePreview: v })}
                        aria-label="Live preview"
                      />
                    }
                  />
                  <Row
                    name="Vim keybindings"
                    desc="Use Vim motions and modes in the editor."
                    control={
                      <Switch
                        checked={settings.editorVim}
                        onCheckedChange={(v) => update({ editorVim: v })}
                        aria-label="Vim keybindings"
                      />
                    }
                  />
                  <Row
                    name="Show line numbers"
                    desc="Display the line-number gutter."
                    control={
                      <Switch
                        checked={settings.showLineNumbers}
                        onCheckedChange={(v) => update({ showLineNumbers: v })}
                        aria-label="Show line numbers"
                      />
                    }
                  />
                  <Row
                    name="Auto-pair brackets"
                    desc="Auto-close brackets and quotes as you type."
                    control={
                      <Switch
                        checked={settings.autoPairBrackets}
                        onCheckedChange={(v) => update({ autoPairBrackets: v })}
                        aria-label="Auto-pair brackets"
                      />
                    }
                  />
                  <Row
                    name="Indent on input"
                    desc="Re-indent the line as you type."
                    control={
                      <Switch
                        checked={settings.indentOnInput}
                        onCheckedChange={(v) => update({ indentOnInput: v })}
                        aria-label="Indent on input"
                      />
                    }
                  />
                  <Row
                    name="Spellcheck"
                    desc="Native browser spellcheck in the editor."
                    control={
                      <Switch
                        checked={settings.spellcheck}
                        onCheckedChange={(v) => update({ spellcheck: v })}
                        aria-label="Spellcheck"
                      />
                    }
                  />
                  <Row
                    name="Readable line width"
                    desc="Constrain content to a comfortable max width."
                    control={
                      <Switch
                        checked={settings.readableLineWidth}
                        onCheckedChange={(v) => update({ readableLineWidth: v })}
                        aria-label="Readable line width"
                      />
                    }
                  />
                  <Row
                    name="Font size"
                    desc={`${settings.editorFontSize}px`}
                    control={
                      <SliderControl
                        value={settings.editorFontSize}
                        min={EDITOR_FONT_RANGE.min}
                        max={EDITOR_FONT_RANGE.max}
                        step={EDITOR_FONT_RANGE.step}
                        label="Editor font size"
                        onChange={(v) => update({ editorFontSize: v })}
                      />
                    }
                  />
                </Group>
              )}

              {section === "reading" && (
                <Group title="Reading">
                  <Row
                    name="Font size"
                    desc={`${settings.readingFontSize}px`}
                    control={
                      <SliderControl
                        value={settings.readingFontSize}
                        min={READING_FONT_RANGE.min}
                        max={READING_FONT_RANGE.max}
                        step={READING_FONT_RANGE.step}
                        label="Reading font size"
                        onChange={(v) => update({ readingFontSize: v })}
                      />
                    }
                  />
                </Group>
              )}

              {section === "graph" && (
                <>
                  <Group title="Graph display">
                    <Row
                      name="Color by"
                      desc="How nodes are colored in the graph."
                      control={
                        <SelectControl
                          value={settings.graphDefaults.colorBy}
                          label="Color by"
                          onChange={(v) => updateGraph("colorBy", v as GraphSettings["colorBy"])}
                          options={[
                            { value: "kind", label: "Entity kind" },
                            { value: "none", label: "Neutral" },
                          ]}
                        />
                      }
                    />
                    {GRAPH_DISPLAY_SLIDERS.map((spec) => (
                      <GraphSliderRow
                        key={spec.key}
                        spec={spec}
                        value={settings.graphDefaults[spec.key] as number}
                        onChange={updateGraph}
                      />
                    ))}
                  </Group>
                  <Group title="Graph forces">
                    {GRAPH_FORCE_SLIDERS.map((spec) => (
                      <GraphSliderRow
                        key={spec.key}
                        spec={spec}
                        value={settings.graphDefaults[spec.key] as number}
                        onChange={updateGraph}
                      />
                    ))}
                  </Group>
                </>
              )}

              {section === "general" && (
                <Group title="General">
                  <Row
                    name="Default rail tab"
                    desc="Which right-rail panel opens first on a page."
                    control={
                      <SelectControl
                        value={settings.defaultRailTab}
                        label="Default rail tab"
                        onChange={(v) => update({ defaultRailTab: v as WikiRailTab })}
                        options={WIKI_RAIL_TABS.map((t) => ({
                          value: t,
                          label: RAIL_TAB_LABELS[t],
                        }))}
                      />
                    }
                  />
                </Group>
              )}
            </div>
          </ScrollArea>
        </div>
      </DialogContent>
    </Dialog>
  );
}

interface GroupProps {
  title: string;
  children: React.ReactNode;
}

function Group({ title, children }: GroupProps) {
  return (
    <section className="mb-5 last:mb-0">
      <h3 className="mb-1 text-sm font-semibold uppercase tracking-[0.05em] text-[color:var(--color-text-tertiary)]">
        {title}
      </h3>
      <div className="flex flex-col divide-y divide-[color:var(--border)]">{children}</div>
    </section>
  );
}

interface RowProps {
  name: string;
  desc?: string;
  control: React.ReactNode;
}

function Row({ name, desc, control }: RowProps) {
  return (
    <div className="flex items-center justify-between gap-4 py-2.5">
      <div className="min-w-0">
        <div className="text-sm text-foreground">{name}</div>
        {desc ? (
          <div className="text-[12px] leading-snug text-[color:var(--color-text-tertiary)]">
            {desc}
          </div>
        ) : null}
      </div>
      <div className="flex shrink-0 items-center">{control}</div>
    </div>
  );
}

interface SliderControlProps {
  value: number;
  min: number;
  max: number;
  step: number;
  label: string;
  onChange: (value: number) => void;
}

function SliderControl({ value, min, max, step, label, onChange }: SliderControlProps) {
  return (
    <input
      type="range"
      min={min}
      max={max}
      step={step}
      value={value}
      aria-label={label}
      onChange={(e) => onChange(Number(e.currentTarget.value))}
      className={cn(
        "h-1 w-40 cursor-pointer appearance-none rounded-full",
        "bg-[color:var(--color-surface-hover)] accent-[color:var(--text-link)]",
      )}
    />
  );
}

interface SelectControlProps {
  value: string;
  label: string;
  options: ReadonlyArray<{ value: string; label: string }>;
  onChange: (value: string) => void;
}

function SelectControl({ value, label, options, onChange }: SelectControlProps) {
  return (
    <select
      value={value}
      aria-label={label}
      onChange={(e) => onChange(e.currentTarget.value)}
      className={cn(
        "h-8 w-40 rounded-md border border-[color:var(--border)] bg-transparent px-2 text-sm",
        "text-foreground focus:outline-none focus-visible:ring-2 focus-visible:ring-ring",
      )}
    >
      {options.map((o) => (
        <option key={o.value} value={o.value}>
          {o.label}
        </option>
      ))}
    </select>
  );
}

interface GraphSliderRowProps {
  spec: GraphSliderSpec;
  value: number;
  onChange: <K extends keyof GraphSettings>(key: K, value: GraphSettings[K]) => void;
}

function GraphSliderRow({ spec, value, onChange }: GraphSliderRowProps) {
  const display =
    Number.isInteger(spec.step) && Number.isInteger(value)
      ? String(value)
      : value.toFixed(spec.step < 0.01 ? 4 : spec.step < 1 ? 3 : 0);
  return (
    <Row
      name={spec.label}
      desc={display}
      control={
        <SliderControl
          value={value}
          min={spec.min}
          max={spec.max}
          step={spec.step}
          label={spec.label}
          onChange={(v) => onChange(spec.key, v as never)}
        />
      }
    />
  );
}
