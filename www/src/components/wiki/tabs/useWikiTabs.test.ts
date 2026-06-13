import { describe, it, expect, beforeAll } from "vitest";

// useWikiTabs uses sessionStorage (per-tab). Install an in-memory Storage and
// SEED an open tab before importing, so renameTabInStorage has something to act
// on (the store reads it lazily on first access).
class MemStorage implements Storage {
  private m = new Map<string, string>();
  get length() { return this.m.size; }
  clear() { this.m.clear(); }
  getItem(k: string) { return this.m.has(k) ? this.m.get(k)! : null; }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  removeItem(k: string) { this.m.delete(k); }
  setItem(k: string, v: string) { this.m.set(k, String(v)); }
}
beforeAll(() => {
  const session = new MemStorage();
  session.setItem("wiki:tabs", JSON.stringify([{ id: "a", title: "Alpha" }, { id: "b", title: "Beta" }]));
  Object.defineProperty(window, "sessionStorage", { value: session, configurable: true });
});

const { renameTabInStorage } = await import("./useWikiTabs");

describe("useWikiTabs store (migrated to persistentStore, sessionStorage)", () => {
  it("renameTabInStorage updates the cached title and persists to sessionStorage", () => {
    renameTabInStorage("a", "Alpha v2");
    const stored = JSON.parse(window.sessionStorage.getItem("wiki:tabs")!);
    expect(stored.find((t: { id: string }) => t.id === "a").title).toBe("Alpha v2");
    expect(stored.find((t: { id: string }) => t.id === "b").title).toBe("Beta"); // others untouched
  });

  it("renaming a non-open id is a no-op", () => {
    const before = window.sessionStorage.getItem("wiki:tabs");
    renameTabInStorage("ghost", "X");
    expect(window.sessionStorage.getItem("wiki:tabs")).toBe(before);
  });

  it("persists to sessionStorage, NOT localStorage (per-tab isolation)", () => {
    expect(window.localStorage?.getItem?.("wiki:tabs") ?? null).toBeNull();
  });
});
