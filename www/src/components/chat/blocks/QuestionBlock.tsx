import * as React from "react";
import { HelpCircle } from "lucide-react";
import { Button } from "@/components/ui/button";
import { Input } from "@/components/ui/input";
import { Label } from "@/components/ui/label";
import { Switch } from "@/components/ui/switch";
import { toast } from "@/components/ui/sonner";
import { dispatch } from "@/state/store";
import type { QuestionField } from "@/domain/models";

interface Props {
  questionId: string;
  title: string;
  prompt?: string;
  fields: QuestionField[];
}

// Inline form: the agent asks the user to fill in fields. Matches Codex.app's
// json.type === "question_request" inline form treatment.
export function QuestionBlock({ questionId, title, prompt, fields }: Props) {
  const [values, setValues] = React.useState<Record<string, unknown>>(() =>
    Object.fromEntries(fields.map((f) => [f.id, f.kind === "boolean" ? false : ""])),
  );
  const [submitted, setSubmitted] = React.useState(false);

  if (submitted) {
    return (
      <div className="my-3 rounded-lg border border-[color:var(--color-green-500)]/30 bg-[color:var(--color-green-500)]/5 px-3 py-2 text-[13px]">
        <span className="font-medium">{title}</span> — answered
        <dl className="mt-1 grid items-start gap-x-3 gap-y-0.5 leading-5 sm:grid-cols-[96px_minmax(0,1fr)]">
          {fields.map((f) => (
            <React.Fragment key={f.id}>
              <dt className="min-w-0 break-words text-[color:var(--color-text-secondary)]">{f.label}</dt>
              <dd className="min-w-0 break-words text-foreground">{formatAnswer(values[f.id], f.kind)}</dd>
            </React.Fragment>
          ))}
        </dl>
      </div>
    );
  }
  return (
    <div className="my-3 rounded-lg border border-[color:var(--border)] bg-background p-3">
      <div className="flex items-center gap-2">
        <HelpCircle className="size-4 text-[color:var(--color-text-secondary)]" />
        <div className="text-[13px] font-medium">{title}</div>
      </div>
      {prompt && <div className="mt-0.5 text-[13px] leading-5 text-[color:var(--color-text-secondary)]">{prompt}</div>}
      <div className="mt-3 space-y-2.5">
        {fields.map((f) => (
          <div key={f.id} className="space-y-1">
            <Label className="text-[13px]">{f.label}{f.required && <span className="text-[color:var(--color-red-500)]"> *</span>}</Label>
            {f.kind === "text" && (
              <Input
                value={String(values[f.id] ?? "")}
                onChange={(e) => setValues((v) => ({ ...v, [f.id]: e.target.value }))}
                className="h-8"
              />
            )}
            {f.kind === "choice" && (
              <div className="flex flex-wrap gap-1.5">
                {f.options?.map((opt) => (
                  <button
                    key={opt}
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
                  onCheckedChange={(v) => setValues((cur) => ({ ...cur, [f.id]: v }))}
                />
                <span className="text-[13px] text-[color:var(--color-text-secondary)]">{Boolean(values[f.id]) ? "Yes" : "No"}</span>
              </div>
            )}
          </div>
        ))}
      </div>
      <div className="mt-3 flex justify-end gap-1.5">
        <Button variant="outline" size="sm" onClick={() => { void dispatch.answerQuestion(questionId, {}); setSubmitted(true); }}>Skip</Button>
        <Button size="sm" onClick={() => { void dispatch.answerQuestion(questionId, values); setSubmitted(true); toast("Answer submitted"); }}>Submit</Button>
      </div>
    </div>
  );
}

function formatAnswer(value: unknown, kind: QuestionField["kind"]): string {
  if (kind === "boolean") return value ? "Yes" : "No";
  const str = String(value ?? "").trim();
  return str.length > 0 ? str : "—";
}
