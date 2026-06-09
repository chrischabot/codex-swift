// Wiki note templates — a small built-in set plus a pure placeholder substitution
// (kept separate from the UI so the substitution is unit-tested). A template is
// instantiated into a new page body via {@link applyTemplate}; the index's "New
// from template" picker and the editor's insert command both use it.
//
// Placeholders (Obsidian-flavored): {{date}} {{time}} {{weekday}} {{title}}.

export interface WikiTemplate {
  readonly id: string;
  readonly name: string;
  readonly description: string;
  /** The raw template body with {{placeholders}}. */
  readonly body: string;
  /** Default title for a page created from this template (placeholders allowed). */
  readonly defaultTitle: string;
}

export const BUILTIN_TEMPLATES: ReadonlyArray<WikiTemplate> = [
  {
    id: "empty",
    name: "Empty",
    description: "A blank page.",
    body: "",
    defaultTitle: "Untitled",
  },
  {
    id: "meeting",
    name: "Meeting note",
    description: "Attendees, agenda, notes, action items.",
    defaultTitle: "Meeting — {{date}}",
    body: ["# {{title}}", "", "*{{date}} {{time}}*", "", "## Attendees", "", "## Agenda", "", "## Notes", "", "## Action items", "", "- [ ] ", ""].join("\n"),
  },
  {
    id: "daily",
    name: "Daily note",
    description: "Date heading, notes, and a task list.",
    defaultTitle: "{{date}}",
    body: ["# {{date}}", "", "*{{weekday}}*", "", "## Notes", "", "## Tasks", "", "- [ ] ", ""].join("\n"),
  },
  {
    id: "project",
    name: "Project",
    description: "Goal, tasks, and notes for a project.",
    defaultTitle: "Project — {{title}}",
    body: ["# {{title}}", "", "## Goal", "", "## Tasks", "", "- [ ] ", "", "## Notes", ""].join("\n"),
  },
];

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Build the placeholder→value map for a date. */
export function templateVars(date: Date): Record<string, string> {
  return {
    date: `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`,
    time: `${pad2(date.getHours())}:${pad2(date.getMinutes())}`,
    weekday: WEEKDAYS[date.getDay()],
  };
}

/** Substitute {{placeholders}} in `text` from `vars`. An unknown placeholder is
 *  left verbatim (so stray `{{x}}` in user content is never silently eaten). */
export function substitutePlaceholders(text: string, vars: Record<string, string>): string {
  return text.replace(/\{\{\s*([a-zA-Z]+)\s*\}\}/g, (whole, key: string) =>
    Object.prototype.hasOwnProperty.call(vars, key) ? vars[key] : whole,
  );
}

/** Instantiate a template body + title. `{{title}}` in the body resolves to the
 *  RESOLVED title (so the body's `# {{title}}` reflects the final page title).
 *  Note for template authors: `{{title}}` is NOT valid in `defaultTitle` (the
 *  title is resolved BEFORE `{{title}}` exists) and would be left verbatim; a
 *  provided title is inserted into the body LITERALLY (not re-scanned), so it
 *  never recurses. */
export function applyTemplate(tpl: WikiTemplate, opts: { date: Date; title?: string }): { title: string; body: string } {
  const base = templateVars(opts.date);
  const title = (opts.title?.trim() || substitutePlaceholders(tpl.defaultTitle, base)).trim() || "Untitled";
  const vars = { ...base, title };
  return { title, body: substitutePlaceholders(tpl.body, vars) };
}
