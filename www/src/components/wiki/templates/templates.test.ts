import { describe, it, expect } from "vitest";
import { applyTemplate, substitutePlaceholders, templateVars, BUILTIN_TEMPLATES } from "./templates";

const DATE = new Date(2026, 5, 9, 14, 5); // 2026-06-09 14:05, a Tuesday

describe("templateVars", () => {
  it("formats date/time/weekday with zero-padding", () => {
    expect(templateVars(DATE)).toEqual({ date: "2026-06-09", time: "14:05", weekday: "Tuesday" });
  });
});

describe("substitutePlaceholders", () => {
  it("replaces known placeholders (with surrounding whitespace tolerated)", () => {
    expect(substitutePlaceholders("{{date}} / {{ weekday }}", templateVars(DATE))).toBe("2026-06-09 / Tuesday");
  });
  it("leaves unknown placeholders verbatim (never silently eaten)", () => {
    expect(substitutePlaceholders("keep {{unknown}} here", templateVars(DATE))).toBe("keep {{unknown}} here");
  });
  it("does not corrupt $& / $1 replacement-string specials in body text", () => {
    // The replacer is a function, so String.replace must NOT interpret $-specials.
    expect(substitutePlaceholders("price $& {{date}}", templateVars(DATE))).toBe("price $& 2026-06-09");
    expect(substitutePlaceholders("ref $1 {{time}}", templateVars(DATE))).toBe("ref $1 14:05");
  });
  it("leaves prototype-chain keys verbatim (no pollution leak)", () => {
    const v = templateVars(DATE);
    expect(substitutePlaceholders("{{__proto__}} {{constructor}} {{toString}}", v)).toBe(
      "{{__proto__}} {{constructor}} {{toString}}",
    );
  });
  it("leaves a placeholder with digits/underscores verbatim (boundary)", () => {
    expect(substitutePlaceholders("{{date2}} {{date_x}}", templateVars(DATE))).toBe("{{date2}} {{date_x}}");
  });
});

describe("applyTemplate", () => {
  const meeting = BUILTIN_TEMPLATES.find((t) => t.id === "meeting")!;

  it("uses the provided title and reflects it in the body's {{title}}", () => {
    const r = applyTemplate(meeting, { date: DATE, title: "Sprint planning" });
    expect(r.title).toBe("Sprint planning");
    expect(r.body).toContain("# Sprint planning");
    expect(r.body).toContain("*2026-06-09 14:05*");
  });

  it("falls back to the template's defaultTitle (with placeholders) when no title given", () => {
    const r = applyTemplate(meeting, { date: DATE });
    expect(r.title).toBe("Meeting — 2026-06-09");
  });

  it("daily template resolves date + weekday", () => {
    const daily = BUILTIN_TEMPLATES.find((t) => t.id === "daily")!;
    const r = applyTemplate(daily, { date: DATE });
    expect(r.title).toBe("2026-06-09");
    expect(r.body.startsWith("# 2026-06-09\n")).toBe(true);
    expect(r.body).toContain("*Tuesday*");
  });

  it("empty template yields an empty body and 'Untitled' default", () => {
    const empty = BUILTIN_TEMPLATES.find((t) => t.id === "empty")!;
    expect(applyTemplate(empty, { date: DATE })).toEqual({ title: "Untitled", body: "" });
  });

  it("a blank provided title falls back to default, never empty", () => {
    expect(applyTemplate(meeting, { date: DATE, title: "   " }).title).toBe("Meeting — 2026-06-09");
  });
});
