import { describe, it, expect } from "vitest";
import { pushRecent, type RecentPage } from "./useWikiRecents";

// Locks in the recently-opened MRU semantics: newest-first, deduped, capped,
// with the cached title refreshed on re-open.

describe("pushRecent", () => {
  it("prepends a fresh open as newest", () => {
    const out = pushRecent([], "a", "Alpha", 1000);
    expect(out).toEqual([{ id: "a", title: "Alpha", openedMs: 1000 }]);
  });

  it("dedupes to a single newest entry on re-open", () => {
    let list: RecentPage[] = pushRecent([], "a", "Alpha", 1000);
    list = pushRecent(list, "b", "Beta", 2000);
    list = pushRecent(list, "a", "Alpha", 3000); // re-open a
    expect(list.map((r) => r.id)).toEqual(["a", "b"]);
    expect(list[0]).toEqual({ id: "a", title: "Alpha", openedMs: 3000 });
  });

  it("refreshes the cached title on re-open", () => {
    let list = pushRecent([], "a", "Old Title", 1000);
    list = pushRecent(list, "a", "New Title", 2000);
    expect(list).toEqual([{ id: "a", title: "New Title", openedMs: 2000 }]);
  });

  it("normalizes blank titles to undefined", () => {
    const out = pushRecent([], "a", "   ", 1000);
    expect(out[0].title).toBeUndefined();
  });

  it("ignores an empty id", () => {
    expect(pushRecent([], "", "x", 1000)).toEqual([]);
  });

  it("caps the list at 30 entries, dropping the oldest", () => {
    let list: RecentPage[] = [];
    for (let i = 0; i < 35; i++) list = pushRecent(list, `id-${i}`, undefined, i);
    expect(list).toHaveLength(30);
    expect(list[0].id).toBe("id-34"); // newest
    expect(list[29].id).toBe("id-5"); // oldest kept (0-4 dropped)
  });
});
