import * as React from "react";
import { useNavigate } from "react-router-dom";
import { Search, ChevronDown, Plus, Check, Loader2, Play, Sparkles } from "lucide-react";
import type { Plugin, PluginCategory } from "@/domain/models";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { useAppData, dispatch } from "@/state/store";
import { toast } from "@/components/ui/sonner";
import { cn } from "@/lib/utils";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";

type AuthorFilter = "All" | "Built by OpenAI" | "Community";
type CategoryFilter = "All" | PluginCategory;

export function PluginsPage() {
  const navigate = useNavigate();
  const { plugins } = useAppData();
  const [query, setQuery] = React.useState("");
  const [author, setAuthor] = React.useState<AuthorFilter>("All");
  const [category, setCategory] = React.useState<CategoryFilter>("All");

  // Derive category list from real plugin data (mirrors original `Category` enum source).
  const categories = React.useMemo<CategoryFilter[]>(() => {
    const set = new Set<PluginCategory>();
    plugins.forEach((p) => p.category.forEach((c) => set.add(c)));
    return ["All", ...Array.from(set)];
  }, [plugins]);

  const filtered = plugins.filter((p) => {
    const matchesQuery = p.name.toLowerCase().includes(query.toLowerCase());
    const matchesAuthor =
      author === "All" ||
      (author === "Built by OpenAI"
        ? p.category.includes("Built by OpenAI")
        : !p.category.includes("Built by OpenAI"));
    const matchesCategory = category === "All" || p.category.includes(category as PluginCategory);
    return matchesQuery && matchesAuthor && matchesCategory;
  });

  return (
    <div className="flex min-h-0 flex-1 flex-col">
      <div className="flex h-9 shrink-0 items-center justify-between px-4">
        <div className="flex items-center gap-1.5 text-[13px]">
          <span className="font-medium">Plugins</span>
          <span className="text-[color:var(--color-text-tertiary)]">Skills</span>
        </div>
        <div className="flex items-center gap-1.5">
          <Button variant="ghost" size="sm" onClick={() => navigate("/plugins/manage")}>
            Manage
          </Button>
          <Button size="sm" className="rounded-md">
            Create <ChevronDown className="!size-3.5" />
          </Button>
        </div>
      </div>

      <div className="min-h-0 flex-1 overflow-y-auto px-4 pb-8">
        <div className="mx-auto max-w-[820px] pt-6">
          <h1 className="text-center text-[22px] font-medium">Make Diminuendo work your way</h1>
          <div className="mt-5 flex items-center gap-2">
            <div className="relative flex-1">
              <Search className="pointer-events-none absolute left-3 top-1/2 size-4 -translate-y-1/2 text-[color:var(--color-text-tertiary)]" />
              <Input
                value={query}
                onChange={(e) => setQuery(e.target.value)}
                placeholder="Search plugins"
                className="h-9 pl-8"
              />
            </div>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-9">
                  {author} <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {(["All", "Built by OpenAI", "Community"] as AuthorFilter[]).map((a) => (
                  <DropdownMenuItem key={a} onSelect={() => setAuthor(a)}>
                    {a}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
            <DropdownMenu>
              <DropdownMenuTrigger asChild>
                <Button variant="outline" size="sm" className="h-9">
                  {category} <ChevronDown className="!size-3.5" />
                </Button>
              </DropdownMenuTrigger>
              <DropdownMenuContent align="end">
                {categories.map((c) => (
                  <DropdownMenuItem key={c} onSelect={() => setCategory(c)}>
                    {c}
                  </DropdownMenuItem>
                ))}
              </DropdownMenuContent>
            </DropdownMenu>
          </div>

          {/* Featured hero carousel */}
          <HeroCarousel onCreate={() => navigate("/plugins/manage")} />

          {/* Featured grid */}
          <h2 className="mt-6 text-[14px] font-medium">Featured</h2>
          {plugins.length === 0 ? (
            // No plugins available at all (vs. an active filter hiding them all).
            <div className="mt-3 flex flex-col items-center gap-3 rounded-2xl border border-dashed border-[color:var(--border)] py-14 text-center">
              <div className="flex size-10 items-center justify-center rounded-xl bg-[color:var(--color-surface-hover)]">
                <Sparkles className="size-5 text-[color:var(--color-text-tertiary)]" />
              </div>
              <div className="text-[13px] font-medium">No plugins yet</div>
              <div className="max-w-[340px] text-[12.5px] text-[color:var(--color-text-tertiary)]">
                Plugins extend Diminuendo with new tools, skills, and integrations. Create one or add a marketplace to get started.
              </div>
              <Button size="sm" onClick={() => navigate("/plugins/manage")}>
                <Plus className="!size-3.5" /> Create plugin
              </Button>
            </div>
          ) : filtered.length === 0 ? (
            <div className="py-12 text-center text-[12.5px] text-[color:var(--color-text-tertiary)]">
              No plugins match your filters.
            </div>
          ) : (
            <div className="mt-3 grid grid-cols-2 gap-2.5">
              {filtered.map((p) => (
                <PluginTile key={p.id} plugin={p} onOpen={() => navigate(`/plugins/${p.id}`)} />
              ))}
            </div>
          )}
        </div>
      </div>
    </div>
  );
}

interface HeroSlide {
  kind: "feature" | "create-plugin";
  title: string;
  description?: string;
  badge?: string;
  cta: string;
}

const heroSlides: HeroSlide[] = [
  {
    kind: "feature",
    title: "Draft replies for every email I'm behind on",
    description: "Connect Gmail and let Diminuendo triage your inbox.",
    cta: "Try in chat",
  },
  {
    kind: "feature",
    title: "Summarize this week's pull requests",
    description: "Hook up GitHub for a Monday-morning digest.",
    cta: "Try in chat",
  },
  {
    kind: "create-plugin",
    title: "Have a workflow in mind?",
    description: "Create a plugin for your team's tools, docs, and ways of working",
    badge: "NEW",
    cta: "Create plugin",
  },
];

function HeroCarousel({ onCreate }: { onCreate: () => void }) {
  const [index, setIndex] = React.useState(0);
  const slide = heroSlides[index];
  return (
    <div className="@container/plugin-hero w-full">
      <div className="relative mt-5 h-[160px] overflow-hidden rounded-2xl">
        {/* gradient with soft blobs */}
        <div
          aria-hidden
          className="absolute inset-0"
          style={{
            background:
              "radial-gradient(60% 90% at 20% 20%, var(--color-banner-blob-a) 0%, transparent 60%)," +
              "radial-gradient(70% 80% at 90% 80%, var(--color-banner-blob-b) 0%, transparent 60%)," +
              "linear-gradient(135deg, var(--color-banner-from) 0%, var(--color-banner-via) 50%, var(--color-banner-to) 100%)",
          }}
        />
        <div
          aria-hidden
          className="absolute inset-0 opacity-50"
          style={{
            backgroundImage:
              "repeating-linear-gradient(115deg, transparent 0px, transparent 3px, rgba(255,255,255,0.25) 4px, transparent 5px)",
            maskImage: "linear-gradient(180deg, rgba(0,0,0,0.3), rgba(0,0,0,0.85))",
          }}
        />
        <div className="relative flex h-full flex-col items-center justify-center gap-2 px-8 text-center text-[color:var(--color-on-brand)]">
          {slide.badge && (
            <span className="rounded-full bg-[color:var(--color-on-brand)]/20 px-2 py-0.5 text-[10px] font-semibold tracking-wide">
              {slide.badge}
            </span>
          )}
          <div className="text-[16px] font-medium">{slide.title}</div>
          {slide.description && (
            <div className="max-w-[460px] text-[12.5px] opacity-90">{slide.description}</div>
          )}
          <button
            onClick={slide.kind === "create-plugin" ? onCreate : () => toast("Try in chat")}
            className="mt-1 flex items-center gap-1.5 rounded-full bg-[color:var(--color-on-brand)]/15 px-3 py-1.5 text-[12px] font-medium text-[color:var(--color-on-brand)] backdrop-blur hover:bg-[color:var(--color-on-brand)]/25"
          >
            {slide.kind !== "create-plugin" && <Play className="size-3" />}
            {slide.cta}
          </button>
        </div>
      </div>
      {/* dot nav */}
      <div className="mt-2 flex items-center justify-center gap-1.5">
        {heroSlides.map((s, i) => (
          <button
            key={s.kind === "create-plugin" ? s.kind : s.title}
            aria-label={`Go to hero slide ${i + 1}`}
            onClick={() => setIndex(i)}
            className={cn(
              "size-1.5 rounded-full transition-colors",
              i === index ? "bg-foreground/80" : "bg-foreground/15 hover:bg-foreground/30",
            )}
          />
        ))}
      </div>
    </div>
  );
}

function PluginTile({ plugin, onOpen }: { plugin: Plugin; onOpen: () => void }) {
  const [installed, setInstalled] = React.useState(plugin.installed ?? false);
  const [pending, setPending] = React.useState(false);

  const toggle = () => {
    const next = !installed;
    setPending(true);
    setInstalled(next);
    dispatch.togglePlugin(plugin.id, next);
    toast(next ? "Plugin enabled" : "Plugin disabled");
    // brief pending feedback to mirror the original install flow
    window.setTimeout(() => setPending(false), 300);
  };

  return (
    <button
      onClick={onOpen}
      className="flex h-[58px] w-full items-center gap-3 rounded-xl border border-[color:var(--border)] bg-background px-3 text-left transition-colors hover:border-foreground/20 hover:bg-[color:var(--color-surface-hover)]"
    >
      <div
        className="flex size-8 items-center justify-center rounded-md text-[12px] font-semibold text-white"
        style={{
          background: plugin.iconBg ?? "var(--color-tile-fallback)",
          color: plugin.iconBg ? "var(--color-on-brand)" : "var(--color-tile-fallback-foreground)",
        }}
      >
        {plugin.icon.length <= 2 ? plugin.icon : plugin.icon.slice(0, 2)}
      </div>
      <div className="min-w-0 flex-1">
        <div className="truncate text-[13px] font-medium">{plugin.name}</div>
        <div className="truncate text-[11.5px] text-[color:var(--color-text-tertiary)]">{plugin.description}</div>
      </div>
      <div
        role="button"
        aria-label={installed ? "Disable plugin" : "Enable plugin"}
        title={installed ? "Disable plugin" : "Enable plugin"}
        onClick={(e) => {
          e.stopPropagation();
          if (!pending) toggle();
        }}
        className={cn(
          "flex size-7 items-center justify-center rounded-md transition-colors",
          installed
            ? "bg-[color:var(--color-green-500)]/10 text-[color:var(--color-green-500)]"
            : "text-[color:var(--color-text-secondary)] hover:bg-[color:var(--color-surface-hover)]",
        )}
      >
        {pending ? (
          <Loader2 className="size-4 animate-spin" />
        ) : installed ? (
          <Check className="size-4" />
        ) : (
          <Plus className="size-4" />
        )}
      </div>
    </button>
  );
}
