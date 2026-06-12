import { describe, it, expect, vi } from "vitest";
import { rewriteWikilinks, rewriteBacklinksOnRename } from "./wikiLinkRewrite";
import type { Connector, WikiIndexEntry, WikiPage } from "@/runtime/connector";

// A minimal in-memory connector exposing only the methods rewriteBacklinksOnRename
// uses. `saveSpy` lets tests inspect/override persistence.
function fakeConnector(pages: Record<string, { title: string; content: string }>, opts?: {
  failSaveFor?: Set<string>;
  loadNull?: Set<string>;
}) {
  const saved: Record<string, string> = {};
  const saveSpy = vi.fn(async (input: { id?: string; title?: string; body: string }) => {
    if (input.id && opts?.failSaveFor?.has(input.id)) return null;
    if (input.id) saved[input.id] = input.body;
    return input.id ? { id: input.id } : null;
  });
  const connector = {
    getWikiPage: async (id: string): Promise<WikiPage | null> => {
      if (opts?.loadNull?.has(id)) return null;
      const p = pages[id];
      return p ? ({ id, title: p.title, content: p.content } as WikiPage) : null;
    },
    saveWikiPage: saveSpy,
  } as unknown as Connector;
  return { connector, saveSpy, saved };
}

const entry = (id: string, title: string, links: string[]): WikiIndexEntry => ({ id, title, links, props: {} });

describe("rewriteWikilinks", () => {
  it("rewrites a bare link", () => {
    expect(rewriteWikilinks("see [[Old Title]] here", "Old Title", "New Title")).toBe(
      "see [[New Title]] here",
    );
  });

  it("preserves an alias", () => {
    expect(rewriteWikilinks("[[Old Title|the old]]", "Old Title", "New")).toBe("[[New|the old]]");
  });

  it("preserves heading and block suffixes", () => {
    expect(rewriteWikilinks("[[Old#Intro]] [[Old^abc]]", "Old", "New")).toBe(
      "[[New#Intro]] [[New^abc]]",
    );
  });

  it("preserves an embed marker", () => {
    expect(rewriteWikilinks("![[Old]]", "Old", "New")).toBe("![[New]]");
  });

  it("is case-insensitive on the target", () => {
    expect(rewriteWikilinks("[[old title]]", "Old Title", "New")).toBe("[[New]]");
  });

  it("leaves non-matching links alone", () => {
    expect(rewriteWikilinks("[[Other]] [[Old]]", "Old", "New")).toBe("[[Other]] [[New]]");
  });

  it("does not rewrite inside fenced code blocks", () => {
    const body = "[[Old]]\n```\n[[Old]]\n```\n[[Old]]";
    expect(rewriteWikilinks(body, "Old", "New")).toBe("[[New]]\n```\n[[Old]]\n```\n[[New]]");
  });

  it("returns the body unchanged when nothing matches", () => {
    const body = "no links here at all";
    expect(rewriteWikilinks(body, "Old", "New")).toBe(body);
  });

  it("no-ops when old and new normalize equal", () => {
    expect(rewriteWikilinks("[[Old]]", "Old", " old ")).toBe("[[Old]]");
  });
});

describe("rewriteBacklinksOnRename", () => {
  const entries = [
    entry("1", "Alpha", ["Old"]),
    entry("2", "Beta", ["Old", "Other"]),
    entry("3", "Renamed", ["Old"]), // the renamed page itself — excluded
    entry("4", "Gamma", ["Unrelated"]),
  ];

  it("rewrites + saves every page linking to the old title", async () => {
    const { connector, saveSpy, saved } = fakeConnector({
      "1": { title: "Alpha", content: "see [[Old]] here" },
      "2": { title: "Beta", content: "[[Old]] and [[Other]]" },
      "3": { title: "Renamed", content: "[[Old]]" },
    });
    const res = await rewriteBacklinksOnRename(connector, entries, "Old", "New", "3");
    expect(res).toEqual({ rewritten: 2, failed: 0 });
    expect(saveSpy).toHaveBeenCalledTimes(2);
    expect(saved["1"]).toContain("[[New]]");
    expect(saved["2"]).toContain("[[New]]");
    expect(saved["2"]).toContain("[[Other]]"); // unrelated link untouched
    expect(saved["3"]).toBeUndefined(); // excluded
  });

  it("no-ops when old and new normalize equal", async () => {
    const { connector, saveSpy } = fakeConnector({ "1": { title: "Alpha", content: "[[Old]]" } });
    expect(await rewriteBacklinksOnRename(connector, entries, "Old", " old ", "3")).toEqual({ rewritten: 0, failed: 0 });
    expect(saveSpy).not.toHaveBeenCalled();
  });

  it("counts a load failure as failed, still rewrites the rest", async () => {
    const { connector } = fakeConnector(
      { "1": { title: "Alpha", content: "[[Old]]" }, "2": { title: "Beta", content: "[[Old]]" } },
      { loadNull: new Set(["1"]) },
    );
    const res = await rewriteBacklinksOnRename(connector, entries, "Old", "New", "3");
    expect(res).toEqual({ rewritten: 1, failed: 1 });
  });

  it("counts a save failure as failed", async () => {
    const { connector } = fakeConnector(
      { "1": { title: "Alpha", content: "[[Old]]" }, "2": { title: "Beta", content: "[[Old]]" } },
      { failSaveFor: new Set(["1"]) },
    );
    const res = await rewriteBacklinksOnRename(connector, entries, "Old", "New", "3");
    expect(res).toEqual({ rewritten: 1, failed: 1 });
  });

  it("skips a page whose link is only inside fenced code (no change, no save)", async () => {
    const { connector, saveSpy } = fakeConnector({
      "1": { title: "Alpha", content: "```\n[[Old]]\n```" },
    });
    const res = await rewriteBacklinksOnRename(connector, [entry("1", "Alpha", ["Old"])], "Old", "New", "3");
    expect(res).toEqual({ rewritten: 0, failed: 0 });
    expect(saveSpy).not.toHaveBeenCalled();
  });

  it("returns {0,0} when the connector lacks saveWikiPage", async () => {
    const connector = { getWikiPage: async () => null } as unknown as Connector;
    expect(await rewriteBacklinksOnRename(connector, entries, "Old", "New", "3")).toEqual({ rewritten: 0, failed: 0 });
  });
});
