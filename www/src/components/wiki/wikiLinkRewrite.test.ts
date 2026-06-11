import { describe, it, expect } from "vitest";
import { rewriteWikilinks } from "./wikiLinkRewrite";

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
