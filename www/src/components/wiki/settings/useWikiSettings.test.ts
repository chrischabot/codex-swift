import { describe, it, expect, beforeAll } from "vitest";

// jsdom here has no origin → window.localStorage is undefined; install an
// in-memory Storage BEFORE importing the module (its persistentStore reads
// lazily but the backend resolves window.localStorage on each access).
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
  Object.defineProperty(window, "localStorage", { value: new MemStorage(), configurable: true });
});

const mod = await import("./useWikiSettings");
const { toggleLivePreviewSetting, DEFAULT_WIKI_SETTINGS } = mod;

describe("useWikiSettings store (migrated to persistentStore)", () => {
  it("toggleLivePreviewSetting flips, persists, and round-trips", () => {
    expect(DEFAULT_WIKI_SETTINGS.editorLivePreview).toBe(true);
    const off = toggleLivePreviewSetting();
    expect(off).toBe(false);
    // Persisted under the stable key with the rest of the blob intact.
    const stored = JSON.parse(window.localStorage.getItem("wiki:settings")!);
    expect(stored.editorLivePreview).toBe(false);
    expect(stored.editorFontSize).toBe(DEFAULT_WIKI_SETTINGS.editorFontSize); // other fields preserved
    const on = toggleLivePreviewSetting();
    expect(on).toBe(true);
    expect(JSON.parse(window.localStorage.getItem("wiki:settings")!).editorLivePreview).toBe(true);
  });
});
