import * as React from "react";
import { Shield, AlertTriangle, ChevronDown } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import {
  DropdownMenu,
  DropdownMenuContent,
  DropdownMenuItem,
  DropdownMenuTrigger,
} from "@/components/ui/dropdown-menu";
import { cn } from "@/lib/utils";
import { toast } from "@/components/ui/sonner";
import { dispatch } from "@/state/store";
import type { QuestionField } from "@/domain/models";

type Decision = "allow_once" | "allow_always" | "deny_once" | "deny_always" | "cancel";

interface Props {
  approvalId: string;
  kind: "exec" | "patch" | "network" | "delivery" | "custom";
  title: string;
  detail?: string;
  risk?: "safe" | "low" | "modify" | "network" | "destructive";
  command?: string[];
  cwd?: string;
  patch?: string;
  decisions?: Decision[];
  decided?: "allowed" | "denied" | "cancelled";
  // Some approval requests double as an MCP-server elicitation: instead of a
  // plain allow/deny they ask the user to fill in structured fields (a
  // text/choice/boolean schema) before the call can continue. When `fields`
  // is present we render the field form and submit the answer through the
  // approval response channel. Additive — existing callers omit these.
  prompt?: string;
  fields?: QuestionField[];
  // When true this card is an MCP elicitation: submitting replies with the
  // collected field values through the {action, content} channel, not a
  // plain allow/deny decision.
  elicitation?: boolean;
}

// Inline approval-required card. Mirrors output/webview/pending-request-item-panel.js
// (the pending-request approval surface): a label/value detail grid, the proposed
// command/patch in an editor-style mono panel, and a right-aligned action row with a
// primary "Yes" submit (with ⏎ kbd hint) plus a "Cancel" dismiss. "Always allow"
// decisions are offered through a scope dropdown rather than a separate button.

// kbd badge — mirrors je() in pending-request-item-panel.js.
function Kbd({ children, variant }: { children: React.ReactNode; variant?: "primary" | "secondary" }) {
  return (
    <kbd
      aria-hidden
      className={cn(
        "inline-flex h-4 min-w-4 items-center justify-center rounded-md border-0 bg-current/10 px-1.5 py-0 font-sans text-xs leading-4 text-current shadow-none",
        variant === "primary" && "text-primary-foreground",
      )}
    >
      {children}
    </kbd>
  );
}

// Label/value row — mirrors Pe() grid: sm:grid-cols-[96px_minmax(0,1fr)].
function DetailRow({ label, children }: { label: string; children: React.ReactNode }) {
  return (
    <div className="grid min-h-5 items-start gap-x-3 gap-y-0.5 text-[13px] leading-5 sm:grid-cols-[96px_minmax(0,1fr)]">
      <div className="min-w-0 break-words text-[color:var(--color-text-secondary)]">{label}</div>
      <div className="min-w-0 break-words text-foreground">{children}</div>
    </div>
  );
}

// Verbose, context-specific copy for the primary "Yes…" action, mirroring the
// original execApprovalRequest / patchApprovalRequest menu strings.
function primaryLabel(kind: Props["kind"]): string {
  switch (kind) {
    case "exec":    return "Yes, run this command";
    case "patch":   return "Yes, make these changes";
    case "network": return "Yes, just this once";
    case "delivery":return "Yes, send this";
    default:        return "Yes";
  }
}

// "Always allow" scope options surfaced through the dropdown.
function alwaysLabel(kind: Props["kind"]): string {
  switch (kind) {
    case "exec":    return "Yes, and don't ask again this session";
    case "patch":   return "Yes, and don't ask again this session";
    case "network": return "Yes, and allow this host for this conversation";
    default:        return "Yes, and don't ask again this session";
  }
}

export function ApprovalBlock(props: Props) {
  const [state, setState] = React.useState<Props["decided"]>(props.decided);
  const decisions = props.decisions ?? ["deny_once", "allow_once", "allow_always"];
  const hasAlways = decisions.includes("allow_always");
  const canAllow = decisions.some((d) => d.startsWith("allow"));
  const showCaution = props.risk === "destructive" || props.risk === "network" || props.risk === "modify";
  const hasFields = (props.fields?.length ?? 0) > 0;

  const decide = (d: Decision) => {
    const outcome: NonNullable<Props["decided"]> = d.startsWith("allow")
      ? "allowed"
      : d === "cancel"
        ? "cancelled"
        : "denied";
    setState(outcome);
    // Unblock the waiting tool call through the connector; the local `state`
    // update is the optimistic UI half (mirrors InboxTab.decide). "Always" maps
    // to a session-scoped grant (backend acceptForSession).
    void dispatch.respondToApproval(props.approvalId, outcome, d === "allow_always" ? "session" : "once");
    toast(outcome === "allowed" ? "Approved" : outcome === "cancelled" ? "Cancelled" : "Denied");
  };

  // Elicitation form path: render structured fields. For an MCP elicitation we
  // reply with the collected values over the {action, content} channel; a plain
  // field-bearing approval falls back to an allow/deny decision.
  if (hasFields) {
    const submit = (values: Record<string, unknown>) => {
      setState("allowed");
      if (props.elicitation) {
        void dispatch.answerElicitation(props.approvalId, true, values);
        toast("Submitted");
      } else {
        decide("allow_once");
      }
    };
    const cancel = () => {
      setState("cancelled");
      if (props.elicitation) {
        void dispatch.answerElicitation(props.approvalId, false);
        toast("Cancelled");
      } else {
        decide("cancel");
      }
    };
    return (
      <ElicitationForm
        title={props.title}
        prompt={props.prompt ?? props.detail}
        fields={props.fields ?? []}
        showCaution={showCaution}
        decided={state}
        onSubmit={submit}
        onCancel={cancel}
      />
    );
  }

  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex flex-col gap-2 px-3 pb-2 pt-2.5">
        <div className="flex items-start gap-2">
          {showCaution && (
            <AlertTriangle className="mt-0.5 size-3.5 shrink-0 text-[color:var(--color-orange-500)]" />
          )}
          <div className="min-w-0 flex-1 text-[13px] font-medium leading-5 text-foreground">{props.title}</div>
        </div>

        {props.detail && (
          <div className="text-[13px] leading-5 text-[color:var(--color-text-secondary)]">{props.detail}</div>
        )}

        {(props.command || props.cwd) && (
          <div className="flex flex-col gap-0.5">
            {props.command && (
              <DetailRow label="Command">
                <span className="font-mono">{props.command.join(" ")}</span>
              </DetailRow>
            )}
            {props.cwd && (
              <DetailRow label="Working dir">
                <span className="font-mono">{props.cwd}</span>
              </DetailRow>
            )}
          </div>
        )}

        {props.command && (
          <div className="px-0">
            <div className="flex max-h-80 w-full flex-col overflow-y-auto rounded-md bg-[color:var(--sidebar)] px-2 py-2 font-mono text-[12px] font-medium text-[color:var(--color-text-secondary)]">
              <span className="block whitespace-pre-wrap break-words">{props.command.join(" ")}</span>
            </div>
          </div>
        )}

        {props.patch && (
          <pre className="max-h-[200px] overflow-auto rounded-md bg-[color:var(--sidebar)] p-2 font-mono text-[12px] text-foreground">
            {props.patch}
          </pre>
        )}
      </div>

      {state ? (
        <div className="flex items-center gap-1.5 border-t border-[color:var(--border)]/50 px-3 py-2 text-[12px]">
          <Shield className="size-3.5 text-[color:var(--color-text-tertiary)]" />
          <span className={state === "allowed" ? "text-[color:var(--color-green-500)]" : "text-[color:var(--color-red-500)]"}>
            {state}
          </span>
        </div>
      ) : (
        <div className="flex flex-col gap-2 border-t border-[color:var(--border)]/50 px-3 py-2 sm:flex-row sm:items-center sm:justify-end">
          <Button
            variant="ghost"
            size="sm"
            className="group shrink-0"
            onClick={() => decide("cancel")}
          >
            <span className="text-[color:var(--color-text-secondary)]">Cancel</span>
            <Kbd variant="secondary">ESC</Kbd>
          </Button>

          {canAllow && (
            <div className="flex shrink-0 items-stretch">
              <Button
                size="sm"
                className={cn("shrink-0", hasAlways && "rounded-r-none")}
                onClick={() => decide("allow_once")}
              >
                <span className="font-medium">{primaryLabel(props.kind)}</span>
                <Kbd variant="primary">⏎</Kbd>
              </Button>
              {hasAlways && (
                <DropdownMenu>
                  <DropdownMenuTrigger asChild>
                    <Button size="sm" className="shrink-0 rounded-l-none border-l border-[color:var(--primary-foreground)]/20 px-1.5" aria-label="More approval options">
                      <ChevronDown className="!size-3" />
                    </Button>
                  </DropdownMenuTrigger>
                  <DropdownMenuContent align="end" className="text-[13px]">
                    <DropdownMenuItem onSelect={() => decide("allow_once")}>{primaryLabel(props.kind)}</DropdownMenuItem>
                    <DropdownMenuItem onSelect={() => decide("allow_always")}>{alwaysLabel(props.kind)}</DropdownMenuItem>
                    {decisions.includes("deny_always") && (
                      <DropdownMenuItem onSelect={() => decide("deny_always")}>No, and don't ask again this session</DropdownMenuItem>
                    )}
                  </DropdownMenuContent>
                </DropdownMenu>
              )}
            </div>
          )}
        </div>
      )}
    </div>
  );
}

// Elicitation form variant of the approval card. Mirrors the MCP-server
// elicitation surface in pending-request-item-panel.js: the request title +
// prompt, a stack of text/choice/boolean fields, and a Cancel / "Continue"
// action row. Submitting collects the field values and reports an "allowed"
// decision through dispatch.respondToApproval.
function ElicitationForm({
  title,
  prompt,
  fields,
  showCaution,
  decided,
  onSubmit,
  onCancel,
}: {
  title: string;
  prompt?: string;
  fields: QuestionField[];
  showCaution: boolean;
  decided?: Props["decided"];
  onSubmit: (values: Record<string, unknown>) => void;
  onCancel: () => void;
}) {
  const [values, setValues] = React.useState<Record<string, unknown>>(() =>
    Object.fromEntries(fields.map((f) => [f.id, f.kind === "boolean" ? false : ""])),
  );

  const missingRequired = fields.some(
    (f) => f.required && f.kind !== "boolean" && String(values[f.id] ?? "").trim().length === 0,
  );

  return (
    <div className="my-3 overflow-hidden rounded-lg border border-[color:var(--border)] bg-background">
      <div className="flex flex-col gap-2 px-3 pb-2 pt-2.5">
        <div className="flex items-start gap-2">
          {showCaution && (
            <AlertTriangle className="mt-0.5 size-3.5 shrink-0 text-[color:var(--color-orange-500)]" />
          )}
          <div className="min-w-0 flex-1 text-[13px] font-medium leading-5 text-foreground">{title}</div>
        </div>
        {prompt && (
          <div className="text-[13px] leading-5 text-[color:var(--color-text-secondary)]">{prompt}</div>
        )}

        <div className="mt-1 space-y-2.5">
          {fields.map((f) => (
            <div key={f.id} className="space-y-1">
              <Label className="text-[13px]">
                {f.label}
                {f.required && <span className="text-[color:var(--color-red-500)]"> *</span>}
              </Label>
              {f.kind === "text" && (
                <Input
                  value={String(values[f.id] ?? "")}
                  onChange={(e) => setValues((v) => ({ ...v, [f.id]: e.target.value }))}
                  className="h-8"
                  disabled={Boolean(decided)}
                />
              )}
              {f.kind === "choice" && (
                <div className="flex flex-wrap gap-1.5">
                  {f.options?.map((opt) => (
                    <button
                      key={opt}
                      type="button"
                      disabled={Boolean(decided)}
                      onClick={() => setValues((v) => ({ ...v, [f.id]: opt }))}
                      className={
                        values[f.id] === opt
                          ? "rounded border border-foreground/30 bg-[color:var(--color-surface-active)] px-2 py-1 text-[13px]"
                          : "rounded border border-[color:var(--border)] px-2 py-1 text-[12.5px] hover:bg-[color:var(--color-surface-hover)]"
                      }
                    >
                      {opt}
                    </button>
                  ))}
                </div>
              )}
              {f.kind === "boolean" && (
                <div className="flex items-center gap-2">
                  <Switch
                    checked={Boolean(values[f.id])}
                    disabled={Boolean(decided)}
                    onCheckedChange={(v) => setValues((cur) => ({ ...cur, [f.id]: v }))}
                  />
                  <span className="text-[13px] text-[color:var(--color-text-secondary)]">
                    {Boolean(values[f.id]) ? "Yes" : "No"}
                  </span>
                </div>
              )}
            </div>
          ))}
        </div>
      </div>

      {decided ? (
        <div className="flex items-center gap-1.5 border-t border-[color:var(--border)]/50 px-3 py-2 text-[12px]">
          <Shield className="size-3.5 text-[color:var(--color-text-tertiary)]" />
          <span
            className={
              decided === "allowed"
                ? "text-[color:var(--color-green-500)]"
                : "text-[color:var(--color-red-500)]"
            }
          >
            {decided}
          </span>
        </div>
      ) : (
        <div className="flex flex-col gap-2 border-t border-[color:var(--border)]/50 px-3 py-2 sm:flex-row sm:items-center sm:justify-end">
          <Button variant="ghost" size="sm" className="group shrink-0" onClick={onCancel}>
            <span className="text-[color:var(--color-text-secondary)]">Cancel</span>
            <Kbd variant="secondary">ESC</Kbd>
          </Button>
          <Button
            size="sm"
            className="shrink-0"
            disabled={missingRequired}
            onClick={() => onSubmit(values)}
          >
            <span className="font-medium">Continue</span>
            <Kbd variant="primary">⏎</Kbd>
          </Button>
        </div>
      )}
    </div>
  );
}
