import * as React from "react";
import { useNavigate, useParams } from "react-router-dom";
import { ChevronLeft, ChevronDown, Play, Trash2, Save, Folder, GitBranch, MessageSquare } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Textarea } from "@/components/ui/textarea";
import { Label } from "@/components/ui/label";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { cn } from "@/lib/utils";
import { useAppData, dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";

// Schedule presets mirror automation-dialog.js `vt`.
const SCHEDULE_PRESETS = [
  { id: "hourly", label: "Hourly" },
  { id: "daily", label: "Daily" },
  { id: "weekdays", label: "Weekdays" },
  { id: "weekly", label: "Weekly" },
  { id: "custom", label: "Custom" },
] as const;
type ScheduleMode = (typeof SCHEDULE_PRESETS)[number]["id"];

// Weekday chips mirror automation-dialog.js `wt`.
const WEEKDAYS = [
  { id: "MO", short: "Mo", long: "Monday" },
  { id: "TU", short: "Tu", long: "Tuesday" },
  { id: "WE", short: "We", long: "Wednesday" },
  { id: "TH", short: "Th", long: "Thursday" },
  { id: "FR", short: "Fr", long: "Friday" },
  { id: "SA", short: "Sa", long: "Saturday" },
  { id: "SU", short: "Su", long: "Sunday" },
] as const;

// Run location mirrors automation-dialog.js `Ct`.
const RUN_LOCATIONS = [
  {
    id: "local",
    label: "Local",
    icon: Folder,
    help: "Runs directly in the selected project directory without creating a worktree.",
  },
  {
    id: "worktree",
    label: "Worktree",
    icon: GitBranch,
    help: "Runs in a dedicated Git worktree created from the selected project, keeping your current checkout untouched.",
  },
  {
    id: "thread",
    label: "Chat",
    icon: MessageSquare,
    help: "Sends messages directly into the selected chat instead of running in a project folder or worktree.",
  },
] as const;
type RunLocation = (typeof RUN_LOCATIONS)[number]["id"];

const MODELS = ["5.5 High", "5.5 Medium", "5.5 Low", "4.6"];

function scheduleToMode(schedule: string): ScheduleMode {
  const s = schedule.toLowerCase();
  if (s.includes("hour")) return "hourly";
  if (s.includes("weekday")) return "weekdays";
  if (s.includes("week")) return "weekly";
  if (s.includes("custom")) return "custom";
  return "daily";
}

export function AutomationEditPage() {
  const { automationId } = useParams();
  const navigate = useNavigate();
  const { automations, projects } = useAppData();
  const automation = automations.find((a) => a.id === automationId);

  const [name, setName] = React.useState(automation?.name ?? "");
  const [mode, setMode] = React.useState<ScheduleMode>(
    scheduleToMode(automation?.schedule ?? "Daily 09:00"),
  );
  const [time, setTime] = React.useState("09:00");
  const [days, setDays] = React.useState<Set<string>>(new Set(["MO", "TU", "WE", "TH", "FR"]));
  const [prompt, setPrompt] = React.useState(
    "Summarize yesterday's PRs in `diminuendo` and `podium`. Flag anything that touches the projection store.",
  );
  const [project, setProject] = React.useState(projects[0]?.id ?? "");
  const [runLocation, setRunLocation] = React.useState<RunLocation>("local");
  const [model, setModel] = React.useState(MODELS[0]);

  if (!automation) {
    return (
      <div className="flex flex-1 items-center justify-center text-[color:var(--color-text-tertiary)]">
        Automation not found
      </div>
    );
  }

  const toggleDay = (id: string) =>
    setDays((prev) => {
      const next = new Set(prev);
      if (next.has(id)) next.delete(id);
      else next.add(id);
      return next;
    });

  const presetLabel = SCHEDULE_PRESETS.find((p) => p.id === mode)?.label ?? "Daily";
  const projectName = projects.find((p) => p.id === project)?.name;
  const runLocationItem = RUN_LOCATIONS.find((r) => r.id === runLocation)!;

  const showDays = mode === "weekly";
  const showTime = mode !== "hourly" && mode !== "custom";

  const scheduleLabel = (() => {
    if (mode === "hourly") return "Hourly";
    if (mode === "custom") return "Custom";
    if (mode === "weekdays") return `Weekdays ${time}`;
    if (mode === "weekly") {
      const labels = WEEKDAYS.filter((d) => days.has(d.id)).map((d) => d.short);
      return `${labels.join(", ") || "—"} ${time}`;
    }
    return `Daily ${time}`;
  })();

  // Validation / requirements gating mirrors automation-dialog.js `{requirements} to save`.
  const requirements: string[] = [];
  if (!name.trim()) requirements.push("add title");
  if (!prompt.trim()) requirements.push("add prompt");
  if (!project) requirements.push("select project");
  if (mode === "weekly" && days.size === 0) requirements.push("fix the schedule");
  const canSave = requirements.length === 0;
  const requirementsSummary =
    requirements.length > 0
      ? `${requirements
          .map((r, i) => (i === 0 ? r.charAt(0).toUpperCase() + r.slice(1) : r))
          .join(", ")} to save`
      : null;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div className="flex items-center gap-1 text-[13px]">
          <button onClick={() => navigate("/automations")} className="flex items-center gap-1 text-[color:var(--color-text-secondary)] hover:underline">
            <ChevronLeft className="size-3.5" />
            Automations
          </button>
          <span className="text-[color:var(--color-text-tertiary)]">›</span>
          <span className="font-medium">{automation.name}</span>
        </div>
        <div className="flex items-center gap-1.5">
          <Button
            variant="outline"
            size="sm"
            onClick={() => { void dispatch.runAutomation(automation.id); toast(`Triggered "${name}"`); }}
          >
            <Play className="!size-3.5" /> Run now
          </Button>
          <Button
            variant="destructive"
            size="sm"
            onClick={() => {
              dispatch.deleteAutomation(automation.id);
              toast("Deleted automation");
              navigate("/automations");
            }}
          >
            <Trash2 className="!size-3.5" /> Delete
          </Button>
          <Button
            size="sm"
            disabled={!canSave}
            title={requirementsSummary ?? undefined}
            onClick={() => {
              dispatch.updateAutomation(automation.id, { name, schedule: scheduleLabel });
              toast("Saved automation");
            }}
          >
            <Save className="!size-3.5" /> Save
          </Button>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-6 py-4">
        <div className="mx-auto max-w-[640px] space-y-5">
          {/* Name */}
          <div className="space-y-1.5">
            <Label htmlFor="auto-name">Name</Label>
            <Input
              id="auto-name"
              value={name}
              onChange={(e) => setName(e.target.value)}
              placeholder="Automation title"
            />
          </div>

          {/* Prompt */}
          <div className="space-y-1.5">
            <Label htmlFor="auto-prompt">Prompt</Label>
            <Textarea
              id="auto-prompt"
              value={prompt}
              onChange={(e) => setPrompt(e.target.value)}
              placeholder="Add prompt e.g. look for crashes in $sentry"
              className="min-h-[120px] font-mono text-[12.5px]"
            />
          </div>

          {/* Schedule: preset selector + optional time + weekday chips */}
          <div className="space-y-2">
            <Label>Schedule</Label>
            <div className="flex flex-wrap items-center gap-2">
              <DropdownMenu>
                <DropdownMenuTrigger asChild>
                  <Button variant="outline" size="sm" className="h-9">
                    {presetLabel} <ChevronDown className="!size-3.5" />
                  </Button>
                </DropdownMenuTrigger>
                <DropdownMenuContent align="start" className="w-[160px]">
                  {SCHEDULE_PRESETS.map((p) => (
                    <DropdownMenuItem key={p.id} onSelect={() => setMode(p.id)}>
                      {p.label}
                    </DropdownMenuItem>
                  ))}
                </DropdownMenuContent>
              </DropdownMenu>
              {showTime && (
                <Input
                  type="time"
                  value={time}
                  onChange={(e) => setTime(e.target.value)}
                  className="h-9 w-[120px]"
                />
              )}
            </div>
            {showDays && (
              <div className="flex flex-wrap gap-1.5 pt-1">
                {WEEKDAYS.map((d) => (
                  <button
                    key={d.id}
                    type="button"
                    aria-label={d.long}
                    title={d.long}
                    aria-pressed={days.has(d.id)}
                    onClick={() => toggleDay(d.id)}
                    className={cn(
                      "flex size-8 items-center justify-center rounded-full border text-[12px] font-medium transition-colors",
                      days.has(d.id)
                        ? "border-transparent bg-foreground text-background"
                        : "border-[color:var(--border)] text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]",
                    )}
                  >
                    {d.short}
                  </button>
                ))}
              </div>
            )}
          </div>

          {/* Project (local-only) */}
          <div className="space-y-1.5">
            <Label>Project</Label>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-9 w-full justify-between">
                  {projectName ?? "Select project"} <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-[280px]">
                {projects.map((p) => (
                  <DropdownMenuItem key={p.id} onSelect={() => setProject(p.id)}>
                    {p.name}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
            <p className="text-[11.5px] text-[color:var(--color-text-tertiary)]">
              Automations can only be created for local projects
            </p>
          </div>

          {/* Run location: Local / Worktree / Chat */}
          <div className="space-y-1.5">
            <Label>Execution environment</Label>
            <div className="flex rounded-md border border-[color:var(--border)] p-0.5">
              {RUN_LOCATIONS.map((r) => {
                const Icon = r.icon;
                return (
                  <button
                    key={r.id}
                    type="button"
                    onClick={() => setRunLocation(r.id)}
                    className={cn(
                      "flex h-8 flex-1 items-center justify-center gap-1.5 rounded px-2 text-[12.5px] font-medium transition-colors",
                      runLocation === r.id
                        ? "bg-[color:var(--color-surface-active)] text-foreground"
                        : "text-[color:var(--color-text-secondary)] hover:text-foreground",
                    )}
                  >
                    <Icon className="size-3.5" />
                    {r.label}
                  </button>
                );
              })}
            </div>
            <p className="text-[11.5px] text-[color:var(--color-text-tertiary)]">{runLocationItem.help}</p>
          </div>

          {/* Model picker */}
          <div className="space-y-1.5">
            <Label>Model</Label>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-9 w-full justify-between">
                  {model ?? "Choose a model"} <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-[280px]">
                {MODELS.map((m) => (
                  <DropdownMenuItem key={m} onSelect={() => setModel(m)}>
                    {m}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>

          {requirementsSummary && (
            <p className="text-[12px] text-[color:var(--color-text-tertiary)]">{requirementsSummary}</p>
          )}
        </div>
      </div>
    </div>
  );
}
