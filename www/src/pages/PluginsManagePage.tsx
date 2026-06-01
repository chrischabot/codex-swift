import * as React from "react";
import { useNavigate } from "react-router-dom";
import {
  Search,
  ChevronDown,
  MoreHorizontal,
  Terminal,
  Store,
  Sparkles,
  Webhook,
} from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { Tabs, TabsList, TabsTrigger } from "@/components/ui/tabs";
import { Badge } from "@/components/ui/badge";
import {
  Dialog,
  DialogContent,
  DialogFooter,
  DialogHeader,
  DialogTitle,
  DialogTrigger,
} from "@/components/ui/dialog";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuSeparator,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { useAppData, dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";
import type { McpServer } from "@/domain/models";

// MCP server status → Badge variant. Mirrors the original mcp-settings status pill.
function mcpStatusVariant(status: McpServer["status"]): "success" | "warning" | "danger" | "outline" {
  switch (status) {
    case "connected":
      return "success";
    case "connecting":
      return "warning";
    case "error":
      return "danger";
    default:
      return "outline";
  }
}

const sampleMarketplace = [
  { id: "claudette",     name: "Claudette",   author: "@igentai", price: "Free",   description: "Curated automation pack for Claude Code." },
];

export function PluginsManagePage() {
  const navigate = useNavigate();
  const { apps, plugins, mcpServers, skills, hooks } = useAppData();
  const [tab, setTab] = React.useState("apps");
  const [q, setQ] = React.useState("");

  // Controlled enable/disable state for MCPs / Skills / Hooks, seeded from the
  // real store snapshot (original dispatches enable/disable with toast feedback).
  // A server is considered enabled unless its status is "disabled".
  const [mcpEnabled, setMcpEnabled] = React.useState<Record<string, boolean>>(
    () => Object.fromEntries(mcpServers.map((m) => [m.id, m.status !== "disabled"])),
  );
  const [skillEnabled, setSkillEnabled] = React.useState<Record<string, boolean>>(
    () => Object.fromEntries(skills.map((s) => [s.id, s.enabled])),
  );
  const [hookEnabled, setHookEnabled] = React.useState<Record<string, boolean>>(
    () => Object.fromEntries(hooks.map((h) => [h.id, h.enabled])),
  );

  const installedPlugins = plugins.filter((p) => p.installed);

  const filteredApps = apps.filter((a) => a.name.toLowerCase().includes(q.toLowerCase()));
  const filteredMCPs = mcpServers.filter((m) => m.name.toLowerCase().includes(q.toLowerCase()));
  const filteredSkills = skills.filter((s) => s.name.toLowerCase().includes(q.toLowerCase()));
  const filteredHooks = hooks.filter(
    (h) =>
      h.event.toLowerCase().includes(q.toLowerCase()) ||
      h.command.toLowerCase().includes(q.toLowerCase()),
  );

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div className="flex items-center gap-1 text-[13px]">
          <button onClick={() => navigate("/plugins")} className="text-[color:var(--color-text-secondary)] hover:underline">
            Plugins
          </button>
          <span className="text-[color:var(--color-text-tertiary)]">›</span>
          <span className="font-medium">Manage</span>
        </div>
        <div className="flex items-center gap-1.5">
          <Button size="sm" className="rounded-md">
            Create <ChevronDown className="!size-3.5" />
          </Button>
          <Button variant="ghost" size="iconSm">
            <MoreHorizontal />
          </Button>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-8">
        <div className="mx-auto max-w-[680px] pt-4">
          <div className="flex items-center justify-between">
            <Tabs value={tab} onValueChange={setTab}>
              <TabsList>
                <TabsTrigger value="plugins">
                  Plugins <span className="text-[color:var(--color-text-tertiary)]">{installedPlugins.length}</span>
                </TabsTrigger>
                <TabsTrigger value="apps">
                  Apps <span className="text-[color:var(--color-text-tertiary)]">{apps.length}</span>
                </TabsTrigger>
                <TabsTrigger value="mcps">
                  MCPs <span className="text-[color:var(--color-text-tertiary)]">{mcpServers.length}</span>
                </TabsTrigger>
                <TabsTrigger value="skills">
                  Skills <span className="text-[color:var(--color-text-tertiary)]">{skills.length}</span>
                </TabsTrigger>
                <TabsTrigger value="hooks">
                  Hooks <span className="text-[color:var(--color-text-tertiary)]">{hooks.length}</span>
                </TabsTrigger>
                <TabsTrigger value="marketplace">
                  Marketplace <span className="text-[color:var(--color-text-tertiary)]">{sampleMarketplace.length}</span>
                </TabsTrigger>
              </TabsList>
            </Tabs>
            <div className="relative w-[200px]">
              <Search className="pointer-events-none absolute left-2.5 top-1/2 size-3.5 -translate-y-1/2 text-[color:var(--color-text-tertiary)]" />
              <Input value={q} onChange={(e) => setQ(e.target.value)} placeholder="Search" className="h-8 pl-7 text-[12.5px]" />
            </div>
          </div>

          <div className="mt-3">
            {tab === "plugins" && (
              installedPlugins.length === 0 ? (
                <EmptyTab message="No installed plugins.">
                  <Button variant="outline" size="sm" onClick={() => navigate("/plugins")}>
                    Open gallery
                  </Button>
                </EmptyTab>
              ) : (
                <ul className="divide-y divide-[color:var(--color-divider)]">
                  {installedPlugins
                    .filter((p) => p.name.toLowerCase().includes(q.toLowerCase()))
                    .map((p) => (
                      <li key={p.id} className="flex items-center gap-3 py-3">
                        <div
                          className="flex size-8 items-center justify-center rounded-md text-[12px] font-semibold"
                          style={{
                            background: p.iconBg ?? "var(--color-tile-fallback)",
                            color: p.iconBg ? "var(--color-on-brand)" : "var(--color-tile-fallback-foreground)",
                          }}
                        >
                          {p.icon.slice(0, 2)}
                        </div>
                        <div className="min-w-0 flex-1">
                          <div className="text-[13px] font-medium">{p.name}</div>
                          <div className="truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{p.description}</div>
                        </div>
                        <DropdownMenu>
                          <DropdownMenuTrigger asChild>
                            <Button variant="ghost" size="iconSm" aria-label="Plugin actions">
                              <MoreHorizontal />
                            </Button>
                          </DropdownMenuTrigger>
                          <DropdownMenuContent align="end" className="w-[180px]">
                            <DropdownMenuItem onSelect={() => navigate(`/plugins/${p.id}`)}>Edit</DropdownMenuItem>
                            <DropdownMenuItem onSelect={() => toast("Copied link")}>Copy link</DropdownMenuItem>
                            <DropdownMenuItem onSelect={() => toast(`Shared ${p.name}`)}>Share</DropdownMenuItem>
                            <DropdownMenuItem
                              onSelect={() => {
                                dispatch.togglePlugin(p.id, false);
                                toast("Plugin disabled");
                              }}
                            >
                              Disable
                            </DropdownMenuItem>
                            <DropdownMenuSeparator />
                            <DropdownMenuItem
                              onSelect={() => {
                                dispatch.togglePlugin(p.id, false);
                                toast(`Uninstalled ${p.name}`);
                              }}
                              className="text-[color:var(--color-red-500)] focus:text-[color:var(--color-red-500)]"
                            >
                              Uninstall
                            </DropdownMenuItem>
                          </DropdownMenuContent>
                        </DropdownMenu>
                      </li>
                    ))}
                </ul>
              )
            )}

            {tab === "apps" && (
              filteredApps.length === 0 ? (
                <EmptyTab message="No apps found." />
              ) : (
                filteredApps.map((a) => (
                  <div
                    key={a.id}
                    className="flex items-center gap-3 border-b border-[color:var(--color-divider)] py-3 last:border-b-0"
                  >
                    <div
                      className="flex size-8 items-center justify-center rounded-md text-[12px] font-semibold text-white"
                      style={{ background: a.iconBg }}
                    >
                      {a.iconLetter}
                    </div>
                    <div className="min-w-0 flex-1">
                      <div className="text-[13px] font-medium">{a.name}</div>
                      <div className="truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{a.description}</div>
                    </div>
                    <Switch
                      checked={a.enabled}
                      onCheckedChange={(v) => {
                        dispatch.togglePlugin(a.id, v);
                        toast(v ? "App enabled" : "App disabled");
                      }}
                    />
                  </div>
                ))
              )
            )}

            {tab === "mcps" && (
              filteredMCPs.length === 0 ? (
                <EmptyTab message="No MCP servers connected.">
                  <Button variant="outline" size="sm">Add MCP server</Button>
                </EmptyTab>
              ) : (
                <ul className="divide-y divide-[color:var(--color-divider)]">
                  {filteredMCPs.map((m) => (
                    <li key={m.id} className="flex items-start gap-3 py-3">
                      <Terminal className="mt-0.5 size-4 text-[color:var(--color-text-secondary)]" />
                      <div className="min-w-0 flex-1">
                        <div className="flex flex-wrap items-center gap-2 text-[13px] font-medium">
                          {m.name}
                          <Badge variant={mcpStatusVariant(m.status)}>{m.status}</Badge>
                          <span className="text-[11px] font-normal text-[color:var(--color-text-tertiary)]">
                            {m.toolCount} {m.toolCount === 1 ? "tool" : "tools"}
                          </span>
                          {m.source && (
                            <span className="text-[11px] font-normal text-[color:var(--color-text-tertiary)]">
                              {m.source}
                            </span>
                          )}
                        </div>
                        <code className="block truncate font-mono text-[11.5px] text-[color:var(--color-text-tertiary)]">
                          {m.command}
                        </code>
                      </div>
                      <Button variant="outline" size="xs">Edit</Button>
                      <Switch
                        checked={mcpEnabled[m.id] ?? m.status !== "disabled"}
                        onCheckedChange={(v) => {
                          setMcpEnabled((prev) => ({ ...prev, [m.id]: v }));
                          toast(v ? "Enable MCP server" : "Disable MCP server");
                        }}
                      />
                    </li>
                  ))}
                  <li className="py-3 text-center">
                    <Button variant="outline" size="sm">Add MCP server</Button>
                  </li>
                </ul>
              )
            )}

            {tab === "skills" && (
              filteredSkills.length === 0 ? (
                <EmptyTab message="No skills found." />
              ) : (
                <ul className="divide-y divide-[color:var(--color-divider)]">
                  {filteredSkills.map((s) => (
                    <li key={s.id} className="flex items-center gap-3 py-3">
                      <Sparkles className="size-4 text-[color:var(--color-text-secondary)]" />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2 text-[13px] font-medium">
                          {s.name}
                          {s.source && (
                            <span className="text-[11px] font-normal text-[color:var(--color-text-tertiary)]">
                              {s.source}
                            </span>
                          )}
                        </div>
                        <div className="truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{s.description}</div>
                      </div>
                      <Switch
                        checked={skillEnabled[s.id] ?? s.enabled}
                        onCheckedChange={(v) => {
                          setSkillEnabled((prev) => ({ ...prev, [s.id]: v }));
                          toast(v ? "Enable skill" : "Disable skill");
                        }}
                      />
                    </li>
                  ))}
                </ul>
              )
            )}

            {tab === "hooks" && (
              filteredHooks.length === 0 ? (
                <EmptyTab message="No hooks configured." />
              ) : (
                <ul className="divide-y divide-[color:var(--color-divider)]">
                  {filteredHooks.map((h) => (
                    <li key={h.id} className="flex items-center gap-3 py-3">
                      <Webhook className="size-4 text-[color:var(--color-text-secondary)]" />
                      <div className="min-w-0 flex-1">
                        <div className="flex items-center gap-2 text-[13px] font-medium">
                          <Badge variant="outline">{h.event}</Badge>
                        </div>
                        <code className="mt-0.5 block truncate font-mono text-[11.5px] text-[color:var(--color-text-tertiary)]">
                          {h.command}
                        </code>
                      </div>
                      <Switch
                        checked={hookEnabled[h.id] ?? h.enabled}
                        onCheckedChange={(v) => {
                          setHookEnabled((prev) => ({ ...prev, [h.id]: v }));
                          toast(v ? "Enable hook" : "Disable hook");
                        }}
                      />
                    </li>
                  ))}
                </ul>
              )
            )}

            {tab === "marketplace" && (
              <div className="space-y-3">
                <div className="flex justify-end">
                  <AddMarketplaceDialog />
                </div>
                {sampleMarketplace.length === 0 ? (
                  <EmptyTab message="No marketplaces found.">
                    <AddMarketplaceDialog />
                  </EmptyTab>
                ) : (
                  <div className="grid grid-cols-1 gap-2.5">
                    {sampleMarketplace.map((p) => (
                      <div key={p.id} className="flex items-center gap-3 rounded-xl border border-[color:var(--border)] p-3">
                        <div className="flex size-9 items-center justify-center rounded-md bg-foreground text-background">
                          <Store className="size-4" />
                        </div>
                        <div className="min-w-0 flex-1">
                          <div className="text-[13px] font-medium">{p.name} <span className="text-[11px] text-[color:var(--color-text-tertiary)]">{p.author}</span></div>
                          <div className="truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{p.description}</div>
                        </div>
                        <Badge>{p.price}</Badge>
                        <Button size="xs">Install</Button>
                      </div>
                    ))}
                  </div>
                )}
              </div>
            )}
          </div>
        </div>
      </div>
    </div>
  );
}

function EmptyTab({ message, children }: { message: string; children?: React.ReactNode }) {
  return (
    <div className="flex flex-col items-center gap-3 py-12 text-center text-[12.5px] text-[color:var(--color-text-tertiary)]">
      {message}
      {children}
    </div>
  );
}

function AddMarketplaceDialog() {
  const [open, setOpen] = React.useState(false);
  return (
    <Dialog open={open} onOpenChange={setOpen}>
      <DialogTrigger asChild>
        <Button variant="outline" size="sm">Add marketplace</Button>
      </DialogTrigger>
      <DialogContent className="max-w-[460px]">
        <DialogHeader>
          <DialogTitle>Add marketplace</DialogTitle>
        </DialogHeader>
        <p className="text-[12.5px] text-[color:var(--color-text-secondary)]">
          Add a plugin marketplace from a GitHub repo, Git URL, or local folder
        </p>
        <div className="space-y-3 pt-1">
          <div className="space-y-1.5">
            <Label htmlFor="mp-source">Source</Label>
            <Input id="mp-source" placeholder="openai/plugins or git@github.com:org/repo.git" />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="mp-ref">Git ref</Label>
            <Input id="mp-ref" placeholder="main" />
          </div>
          <div className="space-y-1.5">
            <Label htmlFor="mp-sparse">Sparse paths</Label>
            <Input id="mp-sparse" placeholder="plugins/codex" />
          </div>
        </div>
        <DialogFooter>
          <Button variant="ghost" size="sm" onClick={() => setOpen(false)}>Cancel</Button>
          <Button
            size="sm"
            onClick={() => {
              setOpen(false);
              toast("Added marketplace");
            }}
          >
            Add marketplace
          </Button>
        </DialogFooter>
      </DialogContent>
    </Dialog>
  );
}
