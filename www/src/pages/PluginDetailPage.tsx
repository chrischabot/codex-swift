import * as React from "react";
import { useNavigate, useParams } from "react-router-dom";
import {
  ChevronLeft,
  ExternalLink,
  Check,
  Plus,
  Sparkles,
  Wrench,
  Share2,
  MoreHorizontal,
  Loader2,
  UserPlus,
  Link2,
  ChevronDown,
} from "lucide-react";
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
import { Input } from "@/components/ui/input";
import { useAppData, dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";

const BRAND = "Diminuendo";

export function PluginDetailPage() {
  const { pluginId } = useParams();
  const navigate = useNavigate();
  const { plugins } = useAppData();
  const plugin = plugins.find((p) => p.id === pluginId);
  const [installed, setInstalled] = React.useState(plugin?.installed ?? false);
  const [adding, setAdding] = React.useState(false);

  if (!plugin) {
    // Original surfaces "Failed to load plugin" for load errors; for a missing id we keep
    // a not-found message consistent with the rest of the app.
    return (
      <div className="flex flex-1 items-center justify-center text-[color:var(--color-text-tertiary)]">
        Failed to load plugin
      </div>
    );
  }

  const addOrEnable = () => {
    const next = !installed;
    if (next) {
      setAdding(true);
      window.setTimeout(() => {
        setAdding(false);
        setInstalled(true);
        dispatch.togglePlugin(plugin.id, true);
        toast("App enabled");
      }, 500);
    } else {
      setInstalled(false);
      dispatch.togglePlugin(plugin.id, false);
      toast("App disabled");
    }
  };

  const ctaLabel = adding
    ? `Adding to ${BRAND}`
    : installed
      ? "Enabled"
      : `Add to ${BRAND}`;

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div className="flex items-center gap-1 text-[13px]">
          <button onClick={() => navigate("/plugins")} className="flex items-center gap-1 text-[color:var(--color-text-secondary)] hover:underline">
            <ChevronLeft className="size-3.5" />
            Plugins
          </button>
          <span className="text-[color:var(--color-text-tertiary)]">›</span>
          <span className="font-medium">{plugin.name}</span>
        </div>
        <div className="flex items-center gap-1.5">
          <ShareDialog pluginName={plugin.name} />
          <DropdownMenu>
            <DropdownMenuTrigger asChild>
              <Button variant="ghost" size="iconSm" aria-label="More actions">
                <MoreHorizontal />
              </Button>
            </DropdownMenuTrigger>
            <DropdownMenuContent align="end" className="w-[200px]">
              <DropdownMenuItem onSelect={() => toast("Opening on ChatGPT…")}>
                Manage on ChatGPT
              </DropdownMenuItem>
              <DropdownMenuItem onSelect={() => navigate("/plugins/manage")}>
                Manage in settings
              </DropdownMenuItem>
              <DropdownMenuItem
                onSelect={() => {
                  setInstalled(false);
                  dispatch.togglePlugin(plugin.id, false);
                  toast("App disabled");
                }}
              >
                Disable
              </DropdownMenuItem>
              <DropdownMenuItem
                onSelect={() => {
                  setInstalled(false);
                  dispatch.togglePlugin(plugin.id, false);
                  toast(`Uninstalled ${plugin.name}`);
                }}
                className="text-[color:var(--color-red-500)] focus:text-[color:var(--color-red-500)]"
              >
                Uninstall
              </DropdownMenuItem>
            </DropdownMenuContent>
          </DropdownMenu>
        </div>
      </div>
      <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-8">
        <div className="mx-auto max-w-[720px] pt-6">
          <div className="flex items-start gap-4">
            <div
              className="flex size-14 items-center justify-center rounded-xl text-[18px] font-semibold text-white"
              style={{
                background: plugin.iconBg ?? "var(--color-tile-fallback)",
                color: plugin.iconBg ? "var(--color-on-brand)" : "var(--color-tile-fallback-foreground)",
              }}
            >
              {plugin.icon.slice(0, 2)}
            </div>
            <div className="min-w-0 flex-1">
              <h1 className="text-[20px] font-semibold">{plugin.name}</h1>
              <p className="mt-1 text-[13px] text-[color:var(--color-text-secondary)]">
                {plugin.description}
              </p>
              <div className="mt-3 flex items-center gap-2">
                <Button
                  onClick={addOrEnable}
                  disabled={adding}
                  size="sm"
                  variant={installed ? "outline" : "default"}
                >
                  {adding ? (
                    <><Loader2 className="!size-3.5 animate-spin" /> {ctaLabel}</>
                  ) : installed ? (
                    <><Check className="!size-3.5" /> {ctaLabel}</>
                  ) : (
                    <><Plus className="!size-3.5" /> {ctaLabel}</>
                  )}
                </Button>
                <Button size="sm" variant="ghost" asChild>
                  <a href="#" target="_blank" rel="noreferrer">
                    Learn more <ExternalLink className="!size-3.5" />
                  </a>
                </Button>
              </div>
            </div>
          </div>

          <Section title="Description">
            <p className="text-[13px] leading-[1.6] text-[color:var(--color-text-secondary)]">
              {plugin.name} extends {BRAND} with read/write access to the underlying service.
              You can reference it inline by typing{" "}
              <code className="rounded bg-[color:var(--color-surface-hover)] px-1 font-mono text-[12px]">@{plugin.name.toLowerCase()}</code>{" "}
              in the composer.
            </p>
          </Section>

          <Section title="Capabilities">
            <ul className="space-y-2 text-[13px]">
              {capabilities.map((c) => (
                <li key={c.label} className="flex items-start gap-2.5">
                  <Sparkles className="mt-0.5 size-3.5 text-[color:var(--color-text-tertiary)]" />
                  <div>
                    <div className="font-medium">{c.label}</div>
                    <div className="text-[12px] text-[color:var(--color-text-secondary)]">{c.detail}</div>
                  </div>
                </li>
              ))}
            </ul>
          </Section>

          <Section title="Details">
            <dl className="grid grid-cols-[120px_1fr] gap-y-2 text-[13px]">
              {details.map((d) => (
                <React.Fragment key={d.label}>
                  <dt className="text-[color:var(--color-text-tertiary)]">{d.label}</dt>
                  <dd className="text-[color:var(--color-text-secondary)]">{d.value}</dd>
                </React.Fragment>
              ))}
            </dl>
          </Section>

          <Section title="Includes">
            <ul className="space-y-2 text-[13px]">
              {includes.map((i) => (
                <li key={i} className="flex items-center gap-2 text-[color:var(--color-text-secondary)]">
                  <Check className="size-3.5 text-[color:var(--color-text-tertiary)]" />
                  {i}
                </li>
              ))}
            </ul>
          </Section>

          <Section title="Available tools for this app">
            <ul className="space-y-2 text-[13px]">
              {tools.map((t) => (
                <li key={t.name} className="flex items-start gap-2.5">
                  <Wrench className="mt-0.5 size-3.5 text-[color:var(--color-text-tertiary)]" />
                  <div>
                    <code className="font-mono text-[12.5px] font-medium">{t.name}</code>
                    <div className="text-[12px] text-[color:var(--color-text-secondary)]">{t.detail}</div>
                  </div>
                </li>
              ))}
            </ul>
          </Section>
        </div>
      </div>
    </div>
  );
}

function ShareDialog({ pluginName }: { pluginName: string }) {
  const [access, setAccess] = React.useState<"view" | "edit">("view");
  return (
    <Dialog>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">
          <Share2 className="!size-3.5" /> Share
        </Button>
      </DialogTrigger>
      <DialogContent className="max-w-[460px]">
        <DialogHeader>
          <DialogTitle>Share {pluginName}</DialogTitle>
        </DialogHeader>
        <div className="space-y-3">
          <div className="flex items-center gap-2">
            <div className="relative flex-1">
              <UserPlus className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-[color:var(--color-text-tertiary)]" />
              <Input placeholder="Add people" className="h-9 pl-8" />
            </div>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-9">
                  {access === "edit" ? "Can edit" : "Can view"} <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                <DropdownMenuItem onSelect={() => setAccess("view")}>Can view</DropdownMenuItem>
                <DropdownMenuItem onSelect={() => setAccess("edit")}>Can edit</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
          <div className="flex items-center justify-between rounded-lg border border-[color:var(--border)] px-3 py-2.5">
            <div className="text-[12.5px] text-[color:var(--color-text-secondary)]">
              Anyone at workspace with the link
            </div>
            <Button
              variant="ghost"
              size="sm"
              onClick={() => toast("Copied link")}
            >
              <Link2 className="!size-3.5" /> Copy link
            </Button>
          </div>
        </div>
      </DialogContent>
    </Dialog>
  );
}

function Section({ title, children }: { title: string; children: React.ReactNode }) {
  return (
    <section className="mt-8">
      <h2 className="mb-2 text-[14px] font-medium">{title}</h2>
      {children}
    </section>
  );
}

const capabilities = [
  { label: "Read", detail: "List, search and reference entities from the service." },
  { label: "Write", detail: "Create, update and reply to entities on your behalf." },
  { label: "Stream", detail: `Receive live updates while ${BRAND} is working.` },
];
const details = [
  { label: "Type", value: "App" },
  { label: "Developer", value: "OpenAI" },
  { label: "Category", value: "Productivity" },
  { label: "Version", value: "1.0.0" },
];
const includes = ["1 MCP server", "Account connection", "Inline @ reference"];
const tools = [
  { name: "search", detail: "Search entities scoped to your account." },
  { name: "create", detail: "Create a new entity on the service." },
  { name: "reply", detail: "Reply to an existing entity." },
];
