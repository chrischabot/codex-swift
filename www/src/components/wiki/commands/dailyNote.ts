// Daily-note helpers — pure + testable. A daily note is just a wiki page whose
// TITLE is the ISO date (YYYY-MM-DD); "open today's note" is a find-by-title or
// create. Kept separate from the command registry so the format is unit-tested
// without the router/connector.

/** ISO date title for a daily note, e.g. 2026-06-09. Local-time based (a daily
 *  note belongs to the user's calendar day, not UTC). */
export function dailyNoteTitle(date: Date): string {
  const y = date.getFullYear();
  const m = String(date.getMonth() + 1).padStart(2, "0");
  const d = String(date.getDate()).padStart(2, "0");
  return `${y}-${m}-${d}`;
}

const WEEKDAYS = ["Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday"];

/** Starter body for a freshly-created daily note: a date heading + the weekday
 *  and a couple of section stubs (the granite daily-note template, trimmed). */
export function dailyNoteBody(date: Date): string {
  const title = dailyNoteTitle(date);
  const weekday = WEEKDAYS[date.getDay()];
  return [`# ${title}`, "", `*${weekday}*`, "", "## Notes", "", "## Tasks", "", "- [ ] ", ""].join("\n");
}

/** Find a daily note by exact title match (case-insensitive) among page
 *  summaries. Returns the id, or null when today's note doesn't exist yet. */
export function findDailyNoteId(
  pages: ReadonlyArray<{ id: string; title: string }>,
  date: Date,
): string | null {
  const want = dailyNoteTitle(date).toLowerCase();
  const hit = pages.find((p) => (p.title ?? "").trim().toLowerCase() === want);
  return hit ? hit.id : null;
}
