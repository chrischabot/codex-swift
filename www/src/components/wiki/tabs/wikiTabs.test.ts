import { describe, it, expect } from "vitest";
import { addTab, removeTab, activeAfterClose, renameTab, type WikiTab } from "./wikiTabs";

const t = (id: string, title = id): WikiTab => ({ id, title });

describe("addTab", () => {
  it("appends a new tab, preserving order", () => {
    expect(addTab([t("1"), t("2")], t("3")).map((x) => x.id)).toEqual(["1", "2", "3"]);
  });
  it("does not duplicate an already-open id", () => {
    expect(addTab([t("1"), t("2")], t("1")).map((x) => x.id)).toEqual(["1", "2"]);
  });
  it("refreshes the cached title in place when the id is already open", () => {
    const out = addTab([t("1", "Old"), t("2")], t("1", "New"));
    expect(out.find((x) => x.id === "1")!.title).toBe("New");
    expect(out.map((x) => x.id)).toEqual(["1", "2"]);
  });
});

describe("removeTab", () => {
  it("removes by id", () => {
    expect(removeTab([t("1"), t("2"), t("3")], "2").map((x) => x.id)).toEqual(["1", "3"]);
  });
});

describe("activeAfterClose", () => {
  const tabs = [t("a"), t("b"), t("c")];
  it("closing the active tab activates the one to the RIGHT", () => {
    expect(activeAfterClose(tabs, "b", "b")).toBe("c");
  });
  it("closing the last (active) tab falls back to the LEFT", () => {
    expect(activeAfterClose(tabs, "c", "c")).toBe("b");
  });
  it("closing the only tab returns null (→ index)", () => {
    expect(activeAfterClose([t("a")], "a", "a")).toBeNull();
  });
  it("closing a NON-active (background) tab returns undefined (no nav change)", () => {
    expect(activeAfterClose(tabs, "a", "b")).toBeUndefined();
  });
  it("closing the active tab at index 0 activates the right neighbour", () => {
    expect(activeAfterClose(tabs, "a", "a")).toBe("b");
  });
  it("an active id not present in the tab list returns undefined (no spurious nav)", () => {
    expect(activeAfterClose(tabs, "x", "x")).toBeUndefined();
  });
});

describe("renameTab", () => {
  it("updates only the matching tab's title", () => {
    const out = renameTab([t("1", "A"), t("2", "B")], "2", "B2");
    expect(out).toEqual([t("1", "A"), { id: "2", title: "B2" }]);
  });
});
