import * as React from "react";
import { ProfileSection, UsageSection, ExperimentalSection } from "./SystemSettings";
import { Switch } from "@/components/ui/switch";
import { Button } from "@/components/ui/button";
import { useTheme, type ThemeMode } from "@/lib/theme";
import { cn } from "@/lib/utils";
import { dispatch, useAppData } from "@/state/store";
import { useModels } from "@/hooks/useModels";
import { toast } from "@/components/ui/sonner";
import {
  Sun,
  Moon,
  Monitor,
  Trash2,
  Download,
  Settings as SettingsIcon,
  User,
  Keyboard,
  AppWindow,
  ShieldHalf,
  GitBranch,
  Archive,
  Smile,
  Gauge,
  Globe,
  MousePointer2,
  LayoutGrid,
  GitFork,
  Boxes,
  Webhook,
  Blocks,
  Sparkles,
  PanelLeftClose,
  PanelLeftOpen,
  ArrowLeft,
  ChevronDown,
} from "lucide-react";
import { useNavigate } from "react-router-dom";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

// Section slugs/labels/icons mirror the original settings-shared.js label map and
// the settings-page.js `he` icon map. Grouping mirrors settings-page.js `_e` (App / Host).
type Slug =
  | "general-settings"
  | "profile"
  | "appearance"
  | "appshots"
  | "connections"
  | "git-settings"
  | "usage"
  | "agent"
  | "personalization"
  | "keyboard-shortcuts"
  | "mcp-settings"
  | "hooks-settings"
  | "browser-use"
  | "computer-use"
  | "local-environments"
  | "worktrees"
  | "data-controls"
  | "plugins-settings"
  | "skills-settings";

const sectionLabels: Record<Slug, string> = {
  "general-settings": "General",
  profile: "Profile",
  appearance: "Appearance",
  appshots: "Appshots",
  connections: "Connections",
  "git-settings": "Git",
  usage: "Usage & billing",
  agent: "Configuration",
  personalization: "Personalization",
  "keyboard-shortcuts": "Keyboard shortcuts",
  "mcp-settings": "MCP servers",
  "hooks-settings": "Hooks",
  "browser-use": "Browser",
  "computer-use": "Computer use",
  "local-environments": "Environments",
  worktrees: "Worktrees",
  "data-controls": "Archived chats",
  "plugins-settings": "Plugins",
  "skills-settings": "Skills",
};

const sectionIcons: Record<Slug, React.ComponentType<{ className?: string }>> = {
  "general-settings": SettingsIcon,
  profile: User,
  appearance: Sun,
  appshots: AppWindow,
  connections: Globe,
  "git-settings": GitBranch,
  usage: Gauge,
  agent: ShieldHalf,
  personalization: Smile,
  "keyboard-shortcuts": Keyboard,
  "mcp-settings": Boxes,
  "hooks-settings": Webhook,
  "browser-use": AppWindow,
  "computer-use": MousePointer2,
  "local-environments": LayoutGrid,
  worktrees: GitFork,
  "data-controls": Archive,
  "plugins-settings": Blocks,
  "skills-settings": Sparkles,
};

// Two groups: App + Host, matching settings-page.js `_e`. The original `plugins-settings`
// and `skills-settings` slugs also exist; we surface them at the end of the Host group.
const groups: { key: string; heading: string; slugs: Slug[] }[] = [
  {
    key: "app",
    heading: "App",
    slugs: [
      "general-settings",
      "profile",
      "appearance",
      "appshots",
      "connections",
      "git-settings",
      "usage",
    ],
  },
  {
    key: "host",
    heading: "Host",
    slugs: [
      "agent",
      "personalization",
      "keyboard-shortcuts",
      "mcp-settings",
      "hooks-settings",
      "browser-use",
      "computer-use",
      "local-environments",
      "worktrees",
      "plugins-settings",
      "skills-settings",
      "data-controls",
    ],
  },
];

export function SettingsPage() {
  const navigate = useNavigate();
  const [active, setActive] = React.useState<Slug>("general-settings");
  const [collapsed, setCollapsed] = React.useState(false);

  // Escape closes settings (settings-page.js keydown Escape -> back route)
  React.useEffect(() => {
    const onKey = (e: KeyboardEvent) => {
      if (e.key === "Escape") navigate(-1);
    };
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [navigate]);

  return (
    <div className="flex min-h-0 flex-1">
      <div
        className={cn(
          "flex shrink-0 flex-col border-r border-[color:var(--color-divider)] py-2 transition-[width]",
          collapsed ? "w-[52px]" : "w-[228px]",
        )}
      >
        {/* Header: Settings label + collapse toggle */}
        <div className="flex h-8 items-center justify-between px-2">
          {!collapsed && (
            <span className="px-1 text-[13px] font-semibold">Settings</span>
          )}
          <button
            onClick={() => setCollapsed((v) => !v)}
            aria-label={collapsed ? "Expand settings navigation" : "Collapse settings navigation"}
            title={collapsed ? "Expand settings navigation" : "Collapse settings navigation"}
            className={cn(
              "flex size-7 items-center justify-center rounded-md text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--ring)]",
              collapsed && "mx-auto",
            )}
          >
            {collapsed ? <PanelLeftOpen className="size-4" /> : <PanelLeftClose className="size-4" />}
          </button>
        </div>

        {/* Back to app */}
        <button
          onClick={() => navigate(-1)}
          className={cn(
            "mt-1 flex h-7 items-center gap-2 rounded-md px-2 text-[13px] text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--ring)]",
            collapsed && "justify-center px-0",
          )}
          title="Back to app"
          aria-label="Back to app"
        >
          <ArrowLeft className="size-4 shrink-0" />
          {!collapsed && <span>Back to app</span>}
        </button>

        {/* Host dropdown */}
        {!collapsed && (
          <div className="mt-2 px-2">
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <button className="flex h-7 w-full items-center justify-between rounded-md border border-[color:var(--border)] px-2 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]">
                  <span className="flex items-center gap-1.5">
                    <Globe className="size-3.5 text-[color:var(--color-text-secondary)]" />
                    This Mac
                  </span>
                  <ChevronDown className="size-3.5 text-[color:var(--color-text-tertiary)]" />
                </button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="start" className="w-[200px]">
                <DropdownMenuItem>This Mac</DropdownMenuItem>
                <DropdownMenuItem>Add host…</DropdownMenuItem>
              </DropdownMenuContent>
            </DropdownMenu>
          </div>
        )}

        {/* Grouped nav */}
        <div className="mt-2 flex min-h-0 flex-1 flex-col gap-3 overflow-y-auto px-2">
          {groups.map((g) => (
            <div key={g.key}>
              {!collapsed && (
                <div className="px-1 pb-1 text-[11px] font-medium uppercase tracking-wide text-[color:var(--color-text-tertiary)]">
                  {g.heading}
                </div>
              )}
              {g.slugs.map((slug) => {
                const Icon = sectionIcons[slug];
                const selected = active === slug;
                return (
                  <button
                    key={slug}
                    onClick={() => setActive(slug)}
                    aria-label={sectionLabels[slug]}
                    title={collapsed ? sectionLabels[slug] : undefined}
                    className={cn(
                      "flex h-7 w-full items-center gap-2 rounded-md px-2 text-left text-[13px] focus-visible:outline-none focus-visible:ring-2 focus-visible:ring-[color:var(--ring)]",
                      collapsed && "justify-center px-0",
                      selected
                        ? "bg-[color:var(--color-surface-active)] font-medium"
                        : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)] hover:text-foreground",
                    )}
                  >
                    <Icon className="size-4 shrink-0" />
                    {!collapsed && <span className="truncate">{sectionLabels[slug]}</span>}
                  </button>
                );
              })}
            </div>
          ))}
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-8 py-6">
        <div className="mx-auto max-w-[640px]">
          <h1 className="mb-6 text-[18px] font-semibold">{sectionLabels[active]}</h1>
          {active === "general-settings" && <GeneralSection />}
          {active === "appearance" && <AppearanceSection />}
          {active === "agent" && <AgentSection />}
          {active === "keyboard-shortcuts" && <ShortcutsSection />}
          {active === "data-controls" && <DataSection />}
          {active === "plugins-settings" && <PluginsSection />}
          {active === "skills-settings" && (
            <PlaceholderSection
              navigate={navigate}
              label="Manage your installed skills, scopes, and recommendations."
              cta={{ label: "Manage skills", to: "/plugins/manage" }}
            />
          )}
          {active === "usage" && <UsageSection />}
          {(active === "profile" || active === "connections") && <ProfileSection />}
          {active === "personalization" && <ExperimentalSection />}
          {active === "mcp-settings" && <McpSection />}
          {active === "hooks-settings" && <HooksSection />}
          {active === "local-environments" && <EnvironmentsSection />}
          {STUB_SECTIONS[active] && <StubSection text={STUB_SECTIONS[active]!} />}
        </div>
      </div>
    </div>
  );
}

// Faithful header stubs for sections whose full bodies are not yet ported.
const STUB_SECTIONS: Partial<Record<Slug, string>> = {
  appshots: "Configure appshot capture and sharing.",
  "git-settings": "Configure Git identity and behavior.",
  "browser-use": "Configure the in-app browser.",
  "computer-use": "Configure computer use approvals.",
  worktrees: "Manage Git worktrees.",
};

function StubSection({ text }: { text: string }) {
  return (
    <p className="text-[13px] text-[color:var(--color-text-secondary)]">{text}</p>
  );
}

// Read the backend config once and write individual keys back through
// config/value/write (optimistic local update + persisted to TOML).
function useConfig() {
  const [config, setConfig] = React.useState<Record<string, unknown>>({});
  React.useEffect(() => {
    let alive = true;
    dispatch.readConfig().then((c) => { if (alive) setConfig(c ?? {}); }).catch(() => {});
    return () => { alive = false; };
  }, []);
  const write = React.useCallback((keyPath: string, value: unknown) => {
    setConfig((c) => ({ ...c, [keyPath]: value }));
    void dispatch.writeConfig(keyPath, value);
  }, []);
  return { config, write };
}

// A toggle for a client-only preference (no backend equivalent) persisted to
// localStorage so it at least remembers state across reloads.
function LocalPrefSwitch({ keyName, defaultOn = false }: { keyName: string; defaultOn?: boolean }) {
  const [on, setOn] = React.useState<boolean>(() => {
    try { const v = localStorage.getItem(`pref.${keyName}`); return v == null ? defaultOn : v === "true"; }
    catch { return defaultOn; }
  });
  return (
    <Switch checked={on} onCheckedChange={(v) => { setOn(v); try { localStorage.setItem(`pref.${keyName}`, String(v)); } catch { /* ignore */ } }} />
  );
}

function ConfigSelect({ value, options, onChange }: { value: string; options: { value: string; label: string }[]; onChange: (v: string) => void }) {
  return (
    <select
      value={value}
      onChange={(e) => onChange(e.target.value)}
      className="h-8 rounded-md border border-[color:var(--border)] bg-background px-2 text-[12.5px]"
    >
      {options.map((o) => <option key={o.value} value={o.value}>{o.label}</option>)}
    </select>
  );
}

function Row({
  title,
  description,
  children,
}: {
  title: string;
  description?: string;
  children: React.ReactNode;
}) {
  return (
    <div className="flex items-center justify-between border-b border-[color:var(--color-divider)] py-3 last:border-b-0">
      <div>
        <div className="text-[13px] font-medium">{title}</div>
        {description && (
          <div className="mt-0.5 text-[12px] text-[color:var(--color-text-secondary)]">{description}</div>
        )}
      </div>
      <div className="ml-4 shrink-0">{children}</div>
    </div>
  );
}

function GeneralSection() {
  const { config, write } = useConfig();
  const approval = (config.approval_policy as string) ?? "on-request";
  const sandbox = (config.sandbox_mode as string) ?? "workspace-write";
  return (
    <>
      <Row title="Approval policy" description="When the agent must ask before running commands or applying edits.">
        <ConfigSelect
          value={approval}
          onChange={(v) => write("approval_policy", v)}
          options={[
            { value: "untrusted", label: "Untrusted (ask for everything)" },
            { value: "on-failure", label: "On failure" },
            { value: "on-request", label: "On request" },
            { value: "never", label: "Never (full auto)" },
          ]}
        />
      </Row>
      <Row title="Sandbox mode" description="Filesystem and network access granted to the agent.">
        <ConfigSelect
          value={sandbox}
          onChange={(v) => write("sandbox_mode", v)}
          options={[
            { value: "read-only", label: "Read only" },
            { value: "workspace-write", label: "Workspace write" },
            { value: "danger-full-access", label: "Full access (danger)" },
          ]}
        />
      </Row>
      <Row title="Show desktop notifications" description="Notify when long-running tasks finish.">
        <LocalPrefSwitch keyName="desktopNotifications" />
      </Row>
      <Row title="Open chats in tabs" description="Open new chats as tabs in the same window.">
        <LocalPrefSwitch keyName="openInTabs" defaultOn />
      </Row>
    </>
  );
}

function AppearanceSection() {
  const [mode, setMode] = useTheme();
  const options: { id: ThemeMode; label: string; icon: React.ReactNode }[] = [
    { id: "light", label: "Light", icon: <Sun className="size-3.5" /> },
    { id: "dark", label: "Dark", icon: <Moon className="size-3.5" /> },
    { id: "system", label: "System", icon: <Monitor className="size-3.5" /> },
  ];
  return (
    <>
      <Row title="Theme" description="Choose between light, dark, or matching your system.">
        <div className="flex rounded-md border border-[color:var(--border)] p-0.5">
          {options.map((o) => (
            <button
              key={o.id}
              onClick={() => setMode(o.id)}
              className={cn(
                "flex h-7 items-center gap-1.5 rounded px-2.5 text-[12px] font-medium transition-colors",
                mode === o.id
                  ? "bg-[color:var(--color-surface-active)] text-foreground"
                  : "text-[color:var(--color-text-secondary)] hover:text-foreground",
              )}
            >
              {o.icon}
              {o.label}
            </button>
          ))}
        </div>
      </Row>
      <Row title="Compact sidebar" description="Reduce row height in the sidebar list.">
        <Switch />
      </Row>
      <Row title="Reduce motion" description="Disable subtle animations and transitions.">
        <Switch />
      </Row>
    </>
  );
}

// Agent/model settings live under the original 'agent' (Configuration) section, not a
// standalone 'Models' section.
function AgentSection() {
  const { config, write } = useConfig();
  const models = useModels();
  const currentModel = (config.model as string) ?? "";
  const effort = (config.model_reasoning_effort as string) ?? "medium";
  const hideReasoning = config.hide_agent_reasoning === true;
  const modelOptions = models.length
    ? models.map((m) => ({ value: m.id, label: m.label }))
    : [{ value: "", label: "(backend default)" }];
  return (
    <>
      <Row title="Default model" description="Persisted to config; used when opening a new chat.">
        <ConfigSelect
          value={currentModel}
          onChange={(v) => write("model", v)}
          options={currentModel && !modelOptions.some((o) => o.value === currentModel)
            ? [{ value: currentModel, label: currentModel }, ...modelOptions]
            : modelOptions}
        />
      </Row>
      <Row title="Reasoning effort" description="How much the model deliberates before answering.">
        <ConfigSelect
          value={effort}
          onChange={(v) => write("model_reasoning_effort", v)}
          options={[
            { value: "low", label: "Low" },
            { value: "medium", label: "Medium" },
            { value: "high", label: "High" },
          ]}
        />
      </Row>
      <Row title="Show reasoning summaries" description="Display planning steps when models expose them.">
        <Switch checked={!hideReasoning} onCheckedChange={(v) => write("hide_agent_reasoning", !v)} />
      </Row>
    </>
  );
}

function ShortcutsSection() {
  const rows: [string, string][] = [
    ["New chat", "⌘N"],
    ["Search", "⌘K"],
    ["Toggle sidebar", "⌘\\"],
    ["Pin/unpin chat", "⌘P"],
    ["Archive chat", "⌘⇧A"],
    ["Reload thread", "⌘R"],
    ["Jump to pinned 1–9", "⌘1 … ⌘9"],
    ["Submit composer", "Enter"],
    ["Newline in composer", "Shift Enter"],
  ];
  return (
    <table className="w-full text-[13px]">
      <tbody>
        {rows.map(([action, keys]) => (
          <tr key={action} className="border-b border-[color:var(--color-divider)] last:border-b-0">
            <td className="py-2.5">{action}</td>
            <td className="py-2.5 text-right font-mono text-[12.5px] text-[color:var(--color-text-secondary)]">
              {keys}
            </td>
          </tr>
        ))}
      </tbody>
    </table>
  );
}

function DataSection() {
  const { threads } = useAppData();
  const onExport = () => {
    const blob = new Blob([JSON.stringify(threads, null, 2)], { type: "application/json" });
    const url = URL.createObjectURL(blob);
    const a = document.createElement("a");
    a.href = url;
    a.download = "codex-threads.json";
    a.click();
    URL.revokeObjectURL(url);
    toast(`Exported ${threads.length} chats`);
  };
  const onClearCache = () => {
    try { localStorage.clear(); } catch { /* ignore */ }
    toast("Local cache cleared");
  };
  const onDeleteAll = async () => {
    if (!window.confirm(`Archive all ${threads.length} chats? This removes them from the active list.`)) return;
    for (const t of threads) await dispatch.deleteThread(t.id);
    toast("All chats archived");
  };
  return (
    <>
      <Row title="Export chats" description="Download a JSON of all chats on this device.">
        <Button variant="outline" size="sm" onClick={onExport}>
          <Download className="!size-3.5" /> Export
        </Button>
      </Row>
      <Row title="Clear local cache" description="Remove cached UI state and preferences.">
        <Button variant="outline" size="sm" onClick={onClearCache}>Clear</Button>
      </Row>
      <Row title="Delete all chats" description="Archive every conversation on this device.">
        <Button variant="destructive" size="sm" onClick={onDeleteAll}>
          <Trash2 className="!size-3.5" /> Delete
        </Button>
      </Row>
    </>
  );
}

function McpSection() {
  const { mcpServers } = useAppData();
  return (
    <div className="space-y-3 text-[13px]">
      <div className="flex items-center justify-between">
        <p className="text-[color:var(--color-text-secondary)]">Model Context Protocol servers registered with this host.</p>
        <Button variant="outline" size="sm" onClick={() => { void dispatch.reloadMcpServers(); toast("Reloading MCP servers…"); }}>Reload</Button>
      </div>
      {mcpServers.length === 0
        ? <p className="text-[color:var(--color-text-secondary)]">No MCP servers configured.</p>
        : mcpServers.map((s) => (
            <div key={s.id} className="flex items-center justify-between border-b border-[color:var(--color-divider)] py-2">
              <div className="min-w-0">
                <div className="font-medium">{s.name}</div>
                <div className="truncate text-[12px] text-[color:var(--color-text-secondary)]">{s.command || "—"}</div>
              </div>
              <div className="ml-4 flex shrink-0 items-center gap-2 text-[12px]">
                <span className="text-[color:var(--color-text-secondary)]">{s.toolCount} tools</span>
                <StatusDot status={s.status} />
              </div>
            </div>
          ))}
    </div>
  );
}

function StatusDot({ status }: { status: "connected" | "connecting" | "error" | "disabled" }) {
  const color = status === "connected" ? "var(--color-green-500)"
    : status === "connecting" ? "var(--color-orange-400)"
    : status === "error" ? "var(--color-red-500)" : "var(--color-text-quaternary)";
  return <span className="inline-flex items-center gap-1"><span className="size-2 rounded-full" style={{ background: `color-mix(in oklab, ${color}, transparent 0%)` }} />{status}</span>;
}

function HooksSection() {
  const { hooks } = useAppData();
  return (
    <div className="space-y-2 text-[13px]">
      <p className="text-[color:var(--color-text-secondary)]">Lifecycle hooks registered with this host.</p>
      {hooks.length === 0
        ? <p className="text-[color:var(--color-text-secondary)]">No hooks configured.</p>
        : hooks.map((h) => (
            <div key={h.id} className="flex items-center justify-between border-b border-[color:var(--color-divider)] py-2">
              <div className="min-w-0">
                <div className="font-medium">{h.event}</div>
                <div className="truncate font-mono text-[12px] text-[color:var(--color-text-secondary)]">{h.command}</div>
              </div>
              <span className="ml-4 shrink-0 text-[12px] text-[color:var(--color-text-secondary)]">{h.enabled ? "enabled" : "disabled"}</span>
            </div>
          ))}
    </div>
  );
}

function EnvironmentsSection() {
  const [id, setId] = React.useState("");
  const [url, setUrl] = React.useState("");
  const [remote, setRemote] = React.useState<Record<string, unknown>>({});
  React.useEffect(() => { let a = true; dispatch.remoteControlStatus().then((r) => { if (a) setRemote(r); }).catch(() => {}); return () => { a = false; }; }, []);
  const enabled = remote.enabled === true || remote.status === "enabled";
  return (
    <div className="space-y-4 text-[13px]">
      <div>
        <div className="mb-1 font-medium">Add remote environment</div>
        <p className="mb-2 text-[12px] text-[color:var(--color-text-secondary)]">Register a remote exec server the agent can run in.</p>
        <div className="flex gap-1.5">
          <input className="h-8 flex-1 rounded-md border border-[color:var(--border)] bg-background px-2 text-[12.5px]" placeholder="environment id" value={id} onChange={(e) => setId(e.target.value)} />
          <input className="h-8 flex-1 rounded-md border border-[color:var(--border)] bg-background px-2 text-[12.5px]" placeholder="exec server URL" value={url} onChange={(e) => setUrl(e.target.value)} />
          <Button size="sm" disabled={!id.trim() || !url.trim()} onClick={async () => { await dispatch.addEnvironment(id.trim(), url.trim()); setId(""); setUrl(""); toast("Environment added"); }}>Add</Button>
        </div>
      </div>
      <div className="border-t border-[color:var(--color-divider)] pt-3">
        <Row title="Remote control" description="Allow controlling this agent from another device.">
          <Switch checked={enabled} onCheckedChange={async (v) => { if (v) await dispatch.enableRemoteControl(); else await dispatch.disableRemoteControl(); setRemote((r) => ({ ...r, enabled: v })); }} />
        </Row>
      </div>
    </div>
  );
}

function PluginsSection() {
  const navigate = useNavigate();
  return (
    <div className="space-y-2 text-[13px]">
      <p className="text-[color:var(--color-text-secondary)]">
        Plugin authoring and per-plugin settings live in the Plugins surface.
      </p>
      <div className="flex gap-2 pt-1">
        <Button variant="outline" size="sm" onClick={() => navigate("/plugins")}>Browse plugins</Button>
        <Button variant="outline" size="sm" onClick={() => navigate("/plugins/manage")}>Manage installed</Button>
      </div>
    </div>
  );
}

function PlaceholderSection({
  navigate,
  label,
  cta,
}: {
  navigate: ReturnType<typeof useNavigate>;
  label: string;
  cta: { label: string; to: string };
}) {
  return (
    <div className="space-y-2 text-[13px]">
      <p className="text-[color:var(--color-text-secondary)]">{label}</p>
      <div className="pt-1">
        <Button variant="outline" size="sm" onClick={() => navigate(cta.to)}>
          {cta.label}
        </Button>
      </div>
    </div>
  );
}
