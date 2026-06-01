import * as React from "react";
import {
  ChevronRight,
  Wrench,
  Terminal,
  FileText,
  Search,
  Edit3,
  FilePlus,
  Globe,
  Plug2,
  Loader2,
} from "lucide-react";
import { cn } from "@/lib/utils";
import { CodeBlock } from "./CodeBlock";

interface Props {
  tool: string;
  args: Record<string, unknown>;
  result?: string;
  status?: "running" | "ok" | "error";
}

// Generic tool-call card. NOTE: this is a deliberate simplification of the
// original Codex chrome, which splits tool activity into type-specific
// components (exec → ShellBlock, patch → diff card, mcp-tool-call card,
// web-search groups, and "collapsed-tool-activity" summaries). We keep a single
// collapsible card here, but route the *presentation* — the leading lucide
// icon and the one-line summary — per tool type (exec/bash, patch/edit, read,
// write, search, web-search, mcp), mirroring conversation-markdown.js's
// per-tool summary lines ("Searched web", "Read N lines", etc.). The body still
// renders args/result in JSON/text the way the original mcp tool card (E())
// does.
export function ToolCallBlock({ tool, args, result, status }: Props) {
  const [open, setOpen] = React.useState(false);
  const kind = classify(tool);
  const Icon = ICONS[kind];
  const summary = previewFor(kind, tool, args);
  const verb = labelFor(kind);
  return (
    <div className="my-2 overflow-hidden rounded-lg border border-[color:var(--border)] bg-[color:var(--color-card)]">
      <button
        type="button"
        onClick={() => setOpen((v) => !v)}
        aria-expanded={open}
        className="flex h-9 w-full items-center gap-2 px-3 text-left text-[12.5px] text-[color:var(--color-text-tertiary)] hover:bg-[color:var(--color-surface-hover)]"
      >
        <ChevronRight className={cn("size-3.5 transition-transform", open && "rotate-90")} />
        <Icon className="size-3.5 shrink-0" />
        <span className="shrink-0 font-medium text-foreground">{verb}</span>
        <span className="truncate font-mono text-[12px]">{summary}</span>
        <span className="ml-auto shrink-0 text-[11px]">
          {status === "running" && (
            <span className="flex items-center gap-1">
              <Loader2 className="size-3 animate-spin" /> Running
            </span>
          )}
          {status === "ok" && <span className="text-[color:var(--color-text-success)]">Success</span>}
          {status === "error" && <span className="text-[color:var(--color-text-danger)]">Error</span>}
        </span>
      </button>
      {open && (
        <div className="border-t border-[color:var(--border)] px-3 py-2 text-[12px]">
          <div className="text-[color:var(--color-text-tertiary)]">Args</div>
          <CodeBlock language="json" code={JSON.stringify(args, null, 2)} showHeader={false} />
          <div className="mt-2 text-[color:var(--color-text-tertiary)]">
            Result{!result && <span>: none</span>}
          </div>
          {result && (
            <pre className="mt-1 overflow-x-auto whitespace-pre-wrap font-mono text-[color:var(--color-text-secondary)]">
              {result}
            </pre>
          )}
        </div>
      )}
    </div>
  );
}

// The presentation buckets we route to. Each maps to a distinct icon + summary
// shape, matching the type-specific tool rendering in the original chrome.
type ToolKind = "exec" | "patch" | "read" | "write" | "search" | "web-search" | "mcp" | "generic";

const ICONS: Record<ToolKind, React.ComponentType<{ className?: string }>> = {
  exec: Terminal,
  patch: Edit3,
  read: FileText,
  write: FilePlus,
  search: Search,
  "web-search": Globe,
  mcp: Plug2,
  generic: Wrench,
};

// Route a tool name to its presentation bucket. MCP tool calls are namespaced
// (`server__tool` or `server.tool`); everything else matches on the leaf name.
function classify(tool: string): ToolKind {
  const t = tool.toLowerCase();
  if (t.includes("__") || (t.includes(".") && !t.endsWith(".sh"))) return "mcp";
  if (t === "bash" || t === "exec" || t === "shell" || t.endsWith("shell") || t.endsWith("_exec")) {
    return "exec";
  }
  if (t === "patch" || t === "edit" || t === "apply_patch" || t === "str_replace" || t === "multiedit") {
    return "patch";
  }
  if (t === "read" || t === "view" || t === "cat" || t === "open") return "read";
  if (t === "write" || t === "create" || t === "create_file") return "write";
  if (t === "websearch" || t === "web_search" || t === "web-search" || t === "fetch" || t === "webfetch") {
    return "web-search";
  }
  if (t === "search" || t === "grep" || t.startsWith("grep") || t.startsWith("find") || t === "glob") {
    return "search";
  }
  return "generic";
}

// Bold verb shown ahead of the summary (mirrors the original action labels:
// "Ran", "Edited", "Read", "Searched", "Searched web", "Called").
function labelFor(kind: ToolKind): string {
  switch (kind) {
    case "exec":
      return "Ran";
    case "patch":
      return "Edited";
    case "read":
      return "Read";
    case "write":
      return "Wrote";
    case "search":
      return "Searched";
    case "web-search":
      return "Searched web";
    case "mcp":
      return "Called";
    default:
      return "Tool";
  }
}

function previewFor(kind: ToolKind, tool: string, args: Record<string, unknown>): string {
  const str = (...keys: string[]): string => {
    for (const k of keys) {
      const v = args[k];
      if (v != null && v !== "") return String(v);
    }
    return "";
  };
  switch (kind) {
    case "exec":
      return str("command", "cmd", "script");
    case "patch":
    case "read":
    case "write":
      return str("file_path", "path", "filename", "file");
    case "search":
      return str("pattern", "query", "regex", "q");
    case "web-search":
      return str("query", "q", "url", "search");
    case "mcp":
      // Leaf tool name + compact args for MCP calls.
      return str("query", "q", "name", "path") || `${tool}(${JSON.stringify(args)})`;
    default:
      return JSON.stringify(args);
  }
}
