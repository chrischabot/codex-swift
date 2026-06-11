import { describe, it, expect } from "vitest";
import { parseHotkey, matchesHotkey, isEditableTarget } from "./hotkeyMatch";

const ev = (key: string, mods: Partial<KeyboardEvent> = {}) =>
  ({ key, metaKey: false, ctrlKey: false, shiftKey: false, altKey: false, ...mods }) as KeyboardEvent;

describe("parseHotkey", () => {
  it("parses a glued symbol run", () => {
    expect(parseHotkey("⌘⇧F")).toEqual({ mod: true, shift: true, alt: false, ctrl: false, key: "f" });
  });
  it("parses a single-mod chord", () => {
    expect(parseHotkey("⌘O")).toEqual({ mod: true, shift: false, alt: false, ctrl: false, key: "o" });
  });
  it("parses a slash key", () => {
    expect(parseHotkey("⌘/")?.key).toBe("/");
  });
  it("parses textual + form", () => {
    expect(parseHotkey("Cmd+Shift+F")).toEqual({ mod: true, shift: true, alt: false, ctrl: false, key: "f" });
  });
  it("returns null without a key", () => {
    expect(parseHotkey("⌘")).toBeNull();
    expect(parseHotkey("")).toBeNull();
  });
});

describe("matchesHotkey", () => {
  const f = parseHotkey("⌘⇧F")!;
  it("matches the exact chord", () => {
    expect(matchesHotkey(ev("F", { metaKey: true, shiftKey: true }), f)).toBe(true);
    expect(matchesHotkey(ev("f", { ctrlKey: true, shiftKey: true }), f)).toBe(true); // ctrl satisfies mod
  });
  it("rejects on a missing modifier", () => {
    expect(matchesHotkey(ev("f", { metaKey: true }), f)).toBe(false); // no shift
    expect(matchesHotkey(ev("f", { shiftKey: true }), f)).toBe(false); // no mod
  });
  it("rejects a different key", () => {
    expect(matchesHotkey(ev("g", { metaKey: true, shiftKey: true }), f)).toBe(false);
  });
  it("a bare-key chord won't fire while a modifier is held", () => {
    const slash = parseHotkey("/")!;
    expect(matchesHotkey(ev("/"), slash)).toBe(true);
    expect(matchesHotkey(ev("/", { metaKey: true }), slash)).toBe(false);
  });
});

describe("isEditableTarget", () => {
  it("detects inputs / textareas", () => {
    expect(isEditableTarget({ tagName: "INPUT" } as HTMLElement)).toBe(true);
    expect(isEditableTarget({ tagName: "TEXTAREA" } as HTMLElement)).toBe(true);
    expect(isEditableTarget({ tagName: "DIV", isContentEditable: true } as HTMLElement)).toBe(true);
  });
  it("is false for non-editable / null", () => {
    expect(isEditableTarget({ tagName: "DIV", isContentEditable: false } as HTMLElement)).toBe(false);
    expect(isEditableTarget(null)).toBe(false);
  });
});
