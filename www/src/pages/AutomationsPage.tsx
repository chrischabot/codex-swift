import * as React from "react";
import { useNavigate } from "react-router-dom";
import { Button } from "@/components/ui/button";
import {
  Dialog,
  DialogContent,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useAppData, dispatch } from "@/state/store";
import type { Automation } from "@/domain/models";
import { toast } from "@/components/ui/sonner";
import {
  ChevronDown,
  Clock,
  RefreshCw,
  BookOpen,
  ShieldAlert,
  Trash2,
  Pencil,
  Play,
  Pause,
  MoreHorizontal,
} from "lucide-react";

export function AutomationsPage() {
  const navigate = useNavigate();
  const { automationTemplates, automations } = useAppData();
  const [open, setOpen] = React.useState(false);
  // The store's Automation model has no status field; track paused rows locally so the
  // Current/Paused split and status pills (matching automations-page.js) are functional.
  const [paused, setPaused] = React.useState<Set<string>>(new Set());

  const togglePaused = (id: string, value: boolean) =>
    setPaused((prev) => {
      const next = new Set(prev);
      if (value) next.add(id);
      else next.delete(id);
      return next;
    });

  const createFromTemplate = (title: string) => {
    dispatch.addAutomation(stripTrailingPeriod(title), "Daily 09:00");
    setOpen(false);
  };

  const current = automations.filter((a) => !paused.has(a.id));
  const pausedList = automations.filter((a) => paused.has(a.id));

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div />
        <div className="flex items-center gap-1.5">
          <Dialog open={open} onOpenChange={setOpen}>
            <DialogTrigger asChild>
              <Button variant="ghost" size="sm">View templates</Button>
            </DialogTrigger>
            <DialogContent className="max-w-[680px]">
              <DialogHeader>
                <div className="flex items-center justify-between">
                  <DialogTitle>Automation templates</DialogTitle>
                  <Button variant="ghost" size="sm" onClick={() => createFromTemplate("New automation")}>
                    Set up manually
                  </Button>
                </div>
              </DialogHeader>
              <div className="grid grid-cols-2 gap-2.5">
                {automationTemplates.map((t) => (
                  <button
                    key={t.id}
                    onClick={() => createFromTemplate(t.title)}
                    className="flex h-[72px] gap-3 rounded-xl border border-[color:var(--border)] px-3 py-2.5 text-left hover:border-foreground/30 hover:bg-[color:var(--color-surface-hover)]"
                  >
                    <div
                      className="flex size-8 shrink-0 items-center justify-center rounded-md text-[14px]"
                      style={{ background: t.iconBg }}
                    >
                      {t.iconLetter}
                    </div>
                    <div className="text-[12.5px] leading-[1.45] text-foreground">{t.title}</div>
                  </button>
                ))}
              </div>
            </DialogContent>
          </Dialog>
          {/* New automation options: Create via chat / Create manually */}
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button size="sm" className="rounded-md" aria-label="New automation options">
                Create via chat <ChevronDown className="!size-3.5" />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-[180px]">
              <DropdownMenuItem
                onSelect={() => dispatch.addAutomation("Untitled automation", "Daily 09:00")}
              >
                Create via chat
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={() => createFromTemplate("New automation")}>
                Create manually
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto">
        {automations.length === 0 ? (
          <EmptyState onCreate={(name) => dispatch.addAutomation(name, "Daily 09:00")} />
        ) : (
          <div className="mx-auto flex max-w-[820px] flex-col gap-8 px-6 pb-12 pt-6">
            <h1 className="text-[18px] font-semibold">Automations</h1>

            {current.length > 0 && (
              <Section title="Current">
                {current.map((a) => (
                  <AutomationRow
                    key={a.id}
                    automation={a}
                    paused={false}
                    onOpen={() => navigate(`/automations/${a.id}`)}
                    onRunNow={() => { void dispatch.runAutomation(a.id); toast("Automation started"); }}
                    onPause={() => togglePaused(a.id, true)}
                    onDelete={() => dispatch.deleteAutomation(a.id)}
                  />
                ))}
              </Section>
            )}

            {pausedList.length > 0 && (
              <Section title="Paused">
                {pausedList.map((a) => (
                  <AutomationRow
                    key={a.id}
                    automation={a}
                    paused
                    onOpen={() => navigate(`/automations/${a.id}`)}
                    onRunNow={() => { void dispatch.runAutomation(a.id); toast("Automation started"); }}
                    onResume={() => togglePaused(a.id, false)}
                    onDelete={() => dispatch.deleteAutomation(a.id)}
                  />
                ))}
              </Section>
            )}
          </div>
        )}
      </div>
    </div>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="flex flex-col gap-2">
      <h2 className="text-[13px] font-medium text-[color:var(--color-text-secondary)]">{title}</h2>
      <div className="-mx-3 flex flex-col gap-1" role="list">
        {children}
      </div>
    </section>
  );
}

function scheduleIcon(schedule: string) {
  // Time-based schedules show a clock; recurring/custom show a refresh glyph.
  if (/custom|interval|hourly/i.test(schedule)) return RefreshCw;
  return Clock;
}

function AutomationRow({
  automation,
  paused,
  onOpen,
  onRunNow,
  onPause,
  onResume,
  onDelete,
}: {
  automation: Automation;
  paused: boolean;
  onOpen: () => void;
  onRunNow: () => void;
  onPause?: () => void;
  onResume?: () => void;
  onDelete: () => void;
}) {
  const ScheduleIcon = scheduleIcon(automation.schedule);
  return (
    <div
      role="listitem"
      onClick={onOpen}
      className="group flex h-11 cursor-pointer items-center gap-3 rounded-lg px-3 hover:bg-[color:var(--color-surface-hover)]"
    >
      <ScheduleIcon className="size-4 shrink-0 text-[color:var(--color-text-secondary)]" />
      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] font-medium">{automation.name}</div>
      </div>

      {/* Right side: schedule label / status, swapped for actions on hover */}
      <div className="relative inline-flex min-w-20 justify-end">
        {/* status pill */}
        <span className="text-[12.5px] text-[color:var(--color-text-secondary)] group-hover:opacity-0">
          {paused ? "Paused" : "In progress"}
        </span>
        {/* schedule label, hidden on hover */}
        <span className="ml-3 min-w-20 whitespace-nowrap text-right text-[12.5px] text-[color:var(--color-text-secondary)] group-hover:opacity-0">
          {automation.schedule}
        </span>

        {/* hover-revealed actions */}
        <span
          className="absolute inset-y-0 right-0 flex items-center gap-2.5 opacity-0 group-hover:opacity-100"
          onClick={(e) => e.stopPropagation()}
        >
          <button
            type="button"
            aria-label="Run now"
            title="Run now"
            onClick={onRunNow}
            className="flex items-center justify-center text-[color:var(--color-text-secondary)] hover:text-foreground"
          >
            <Play className="size-4" />
          </button>
          <button
            type="button"
            aria-label="Edit automation"
            title="Edit automation"
            onClick={onOpen}
            className="flex items-center justify-center text-[color:var(--color-text-secondary)] hover:text-foreground"
          >
            <Pencil className="size-4" />
          </button>
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <button
                type="button"
                aria-label="Automation actions"
                title="More options"
                className="flex items-center justify-center text-[color:var(--color-text-secondary)] hover:text-foreground"
              >
                <MoreHorizontal className="size-4" />
              </button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-[180px]">
              <DropdownMenuItem onSelect={onRunNow}>
                <Play className="!size-3.5" /> Run now
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={onOpen}>
                <Pencil className="!size-3.5" /> Edit automation
              </DropdownMenuItem>
              {!paused && onPause && (
                <DropdownMenuItem onSelect={onPause}>
                  <Pause className="!size-3.5" /> Pause
                </DropdownMenuItem>
              )}
              {paused && onResume && (
                <DropdownMenuItem onSelect={onResume}>
                  <Play className="!size-3.5" /> Resume
                </DropdownMenuItem>
              )}
              <DropdownMenuItem
                onSelect={onDelete}
                className="text-[color:var(--color-red-500)] focus:text-[color:var(--color-red-500)]"
              >
                <Trash2 className="!size-3.5" /> Delete
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </span>
      </div>
    </div>
  );
}

function EmptyState({ onCreate }: { onCreate: (name: string) => void }) {
  return (
    <div className="mx-auto max-w-[640px] px-6 pt-12 text-center">
      <h1 className="text-[22px] font-medium">Automations</h1>
      <p className="mt-1 text-[13px] text-[color:var(--color-text-secondary)]">
        Run chats on a schedule or whenever you need them.{" "}
        <a
          href="https://help.openai.com/en/articles/codex-automations"
          target="_blank"
          rel="noreferrer"
          className="text-[color:var(--color-blue-400)] hover:underline"
        >
          Learn more
        </a>
      </p>
      <div className="mt-16 flex flex-col items-center gap-4">
        <div className="flex size-12 items-center justify-center text-[color:var(--color-text-tertiary)]">
          <Cloud />
        </div>
        <div className="text-[14px] font-medium">Create your first automation</div>
        <div className="flex items-center gap-2">
          <ChipButton onClick={() => onCreate("Daily brief")} icon={<BookOpen className="size-3.5" />}>
            Daily brief
          </ChipButton>
          <ChipButton onClick={() => onCreate("Weekly review")} icon={<Clock className="size-3.5" />}>
            Weekly review
          </ChipButton>
          <ChipButton onClick={() => onCreate("Project monitor")} icon={<ShieldAlert className="size-3.5" />}>
            Project monitor
          </ChipButton>
        </div>
      </div>
    </div>
  );
}

function ChipButton({
  children,
  icon,
  onClick,
}: {
  children: React.ReactNode;
  icon: React.ReactNode;
  onClick: () => void;
}) {
  return (
    <button
      onClick={onClick}
      className="flex items-center gap-1.5 rounded-md border border-[color:var(--border)] bg-background px-3 py-1.5 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
    >
      {icon}
      {children}
    </button>
  );
}

function Cloud() {
  return (
    <svg width="56" height="56" viewBox="0 0 56 56" fill="none">
      <path
        d="M16.7 38.2c-4.6 0-8.3-3.7-8.3-8.3 0-4.3 3.3-7.8 7.5-8.2.5-7.1 6.4-12.7 13.6-12.7 6.4 0 11.9 4.5 13.3 10.5 4.4.7 7.7 4.5 7.7 9.1 0 5.1-4.1 9.2-9.2 9.2H16.7z"
        stroke="currentColor"
        strokeWidth="1.8"
        strokeLinejoin="round"
        fill="none"
      />
    </svg>
  );
}

function stripTrailingPeriod(s: string) {
  return s.endsWith(".") ? s.slice(0, -1) : s;
}
