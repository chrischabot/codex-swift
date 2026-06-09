import { describe, it, expect } from "vitest";
import { dailyNoteTitle, dailyNoteBody, findDailyNoteId } from "./dailyNote";

describe("dailyNoteTitle", () => {
  it("formats as zero-padded ISO date (local time)", () => {
    expect(dailyNoteTitle(new Date(2026, 5, 9))).toBe("2026-06-09"); // June = month 5
    expect(dailyNoteTitle(new Date(2026, 0, 1))).toBe("2026-01-01");
    expect(dailyNoteTitle(new Date(2025, 11, 31))).toBe("2025-12-31");
  });
});

describe("dailyNoteBody", () => {
  it("starts with the date heading and the weekday", () => {
    const body = dailyNoteBody(new Date(2026, 5, 9)); // a Tuesday
    expect(body.startsWith("# 2026-06-09\n")).toBe(true);
    expect(body).toContain("*Tuesday*");
    expect(body).toContain("## Notes");
    expect(body).toContain("## Tasks");
  });

  it("maps the weekday endpoints correctly (Sunday=0 … Saturday=6)", () => {
    expect(dailyNoteBody(new Date(2026, 5, 7))).toContain("*Sunday*"); // 2026-06-07 is a Sunday
    expect(dailyNoteBody(new Date(2026, 5, 13))).toContain("*Saturday*"); // 2026-06-13 is a Saturday
  });
});

describe("findDailyNoteId", () => {
  const date = new Date(2026, 5, 9);
  it("returns the id of an exact-title match", () => {
    const pages = [
      { id: "1", title: "Other" },
      { id: "42", title: "2026-06-09" },
    ];
    expect(findDailyNoteId(pages, date)).toBe("42");
  });
  it("matches case/whitespace-insensitively", () => {
    expect(findDailyNoteId([{ id: "7", title: " 2026-06-09 " }], date)).toBe("7");
  });
  it("returns null when today's note does not exist", () => {
    expect(findDailyNoteId([{ id: "1", title: "2026-06-08" }], date)).toBeNull();
    expect(findDailyNoteId([], date)).toBeNull();
  });
});
