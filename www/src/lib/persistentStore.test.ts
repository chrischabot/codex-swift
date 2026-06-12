import { describe, it, expect, beforeEach } from "vitest";
import { createPersistentStore } from "./persistentStore";

// jsdom here has no origin, so window.localStorage is undefined; install a small
// in-memory Storage so the factory's persistence path is exercised.
class MemStorage implements Storage {
  private m = new Map<string, string>();
  get length() { return this.m.size; }
  clear() { this.m.clear(); }
  getItem(k: string) { return this.m.has(k) ? this.m.get(k)! : null; }
  key(i: number) { return [...this.m.keys()][i] ?? null; }
  removeItem(k: string) { this.m.delete(k); }
  setItem(k: string, v: string) { this.m.set(k, String(v)); }
}

describe("createPersistentStore", () => {
  beforeEach(() => {
    Object.defineProperty(window, "localStorage", { value: new MemStorage(), configurable: true });
    Object.defineProperty(window, "sessionStorage", { value: new MemStorage(), configurable: true });
  });

  it("round-trips get/set through localStorage", () => {
    const s = createPersistentStore<{ n: number }>({ key: "t:rt", defaultValue: { n: 0 } });
    expect(s.get()).toEqual({ n: 0 });
    s.set({ n: 5 });
    expect(s.get()).toEqual({ n: 5 });
    expect(JSON.parse(window.localStorage.getItem("t:rt")!)).toEqual({ n: 5 });
  });

  it("notifies subscribers on set", () => {
    const s = createPersistentStore<number>({ key: "t:sub", defaultValue: 0 });
    let hits = 0;
    const off = s.subscribe(() => hits++);
    s.set(1);
    s.set(2);
    expect(hits).toBe(2);
    off();
    s.set(3);
    expect(hits).toBe(2); // unsubscribed
  });

  it("applies coerce on read of malformed JSON", () => {
    window.localStorage.setItem("t:co", JSON.stringify({ junk: true }));
    const s = createPersistentStore<string[]>({
      key: "t:co",
      defaultValue: [],
      coerce: (raw) => (Array.isArray(raw) ? raw.filter((x): x is string => typeof x === "string") : []),
    });
    expect(s.get()).toEqual([]); // object coerced to default-shaped empty
  });

  it("uses sessionStorage when requested", () => {
    const s = createPersistentStore<number>({ key: "t:sess", defaultValue: 0, storage: "session" });
    s.set(9);
    expect(window.sessionStorage.getItem("t:sess")).toBe("9");
    expect(window.localStorage.getItem("t:sess")).toBeNull();
  });
});
