import { describe, it, expect } from "vitest";
import {
  parseWikilink,
  fragmentAnchorId,
  resolveWikilinkNav,
  remarkBlockIds,
  remarkWikilinks,
  slugify,
  decodeWikiTarget,
} from "./wikiRemarkPlugins";

// CLAIM (M13): a clicked wikilink opens its target page directly (resolved
// title → id) and jumps to a #heading / #^block fragment; a dangling target
// falls back to search. Block ids render as `block-<id>` anchors.

describe("fragmentAnchorId", () => {
  it("slugs a heading fragment", () => {
    expect(fragmentAnchorId(parseWikilink("Page#My Heading"))).toBe(slugify("My Heading"));
    expect(fragmentAnchorId(parseWikilink("Page#My Heading"))).toBe("my-heading");
  });
  it("prefixes a block fragment", () => {
    expect(fragmentAnchorId(parseWikilink("Page#^abc-1"))).toBe("block-abc-1");
  });
  it("is empty with no fragment", () => {
    expect(fragmentAnchorId(parseWikilink("Page"))).toBe("");
    expect(fragmentAnchorId(parseWikilink("Page|Alias"))).toBe("");
  });
});

describe("resolveWikilinkNav", () => {
  const resolve = (t: string) => (t.toLowerCase() === "notes" ? "7" : undefined);

  it("opens a resolved page directly", () => {
    expect(resolveWikilinkNav("Notes", resolve)).toBe("/wiki/7");
  });
  it("opens a resolved page at a heading fragment", () => {
    expect(resolveWikilinkNav("Notes#Section Two", resolve)).toBe("/wiki/7#section-two");
  });
  it("opens a resolved page at a block fragment", () => {
    expect(resolveWikilinkNav("Notes#^blk9", resolve)).toBe("/wiki/7#block-blk9");
  });
  it("ignores the display alias when resolving", () => {
    expect(resolveWikilinkNav("Notes|Pretty Name", resolve)).toBe("/wiki/7");
  });
  it("falls back to search for a dangling target", () => {
    expect(resolveWikilinkNav("Unknown Page", resolve)).toBe("/wiki?q=Unknown%20Page");
  });
  it("falls back to search using the base title (not the fragment)", () => {
    expect(resolveWikilinkNav("Unknown#Heading", resolve)).toBe("/wiki?q=Unknown");
  });

  it("resolves a percent-encoded multi-word target once decoded (the rehype bug)", () => {
    // rehype hands us "Notes%20Page#Section%20Two"; decoding is required or the
    // title never matches the map. Here the page is titled "notes".
    const r = (t: string) => (t.toLowerCase() === "notes" ? "7" : undefined);
    expect(resolveWikilinkNav(decodeWikiTarget("Notes#Section%20Two"), r)).toBe("/wiki/7#section-two");
  });

  it("returns a hash-only nav for a bare self-link [[#heading]] / [[#^block]]", () => {
    expect(resolveWikilinkNav("#Section Two", resolve)).toBe("#section-two");
    expect(resolveWikilinkNav("#^blk", resolve)).toBe("#block-blk");
  });
});

describe("decodeWikiTarget", () => {
  it("decodes percent escapes", () => {
    expect(decodeWikiTarget("Two%20Words")).toBe("Two Words");
    expect(decodeWikiTarget("a%23b")).toBe("a#b");
  });
  it("returns the input unchanged on malformed escapes", () => {
    expect(decodeWikiTarget("100%")).toBe("100%");
    expect(decodeWikiTarget("bad%ZZ")).toBe("bad%ZZ");
  });
});

describe("remarkBlockIds", () => {
  // Minimal mdast helpers. `data` is optional and set by the transform.
  type MNode = { type: string; value?: string; children?: unknown[]; depth?: number; data?: { hProperties?: Record<string, unknown> } };
  const txt = (value: string): MNode => ({ type: "text", value });
  const para = (...children: MNode[]): MNode => ({ type: "paragraph", children });
  const heading = (depth: number, ...children: MNode[]): MNode => ({ type: "heading", depth, children });
  const root = (...children: MNode[]): MNode => ({ type: "root", children });
  const run = (tree: unknown) => {
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    remarkBlockIds()(tree as any);
    return tree;
  };

  it("strips a trailing ^id from a paragraph and tags it block-<id>", () => {
    const p = para(txt("Some content ^abc"));
    run(root(p));
    expect((p.data as { hProperties: { id: string } }).hProperties.id).toBe("block-abc");
    // The block-id token (and its leading space) is removed from the text.
    expect((p.children![0] as { value: string }).value).toBe("Some content");
  });

  it("tags a heading with a trailing block id", () => {
    const h = heading(2, txt("Title ^h1"));
    run(root(h));
    expect((h.data as { hProperties: { id: string } }).hProperties.id).toBe("block-h1");
  });

  it("removes a paragraph whose only content was the block id token", () => {
    const p = para(txt("text ^only"));
    run(root(p));
    expect((p.children![0] as { value: string }).value).toBe("text");
  });

  it("does NOT consume a standalone ^id (no leading whitespace)", () => {
    const p = para(txt("^standalone"));
    run(root(p));
    expect(p.data).toBeUndefined();
    expect((p.children![0] as { value: string }).value).toBe("^standalone");
  });

  it("leaves a paragraph without a block id untouched", () => {
    const p = para(txt("plain text"));
    run(root(p));
    expect(p.data).toBeUndefined();
  });

  it("does not overwrite an existing id", () => {
    const p = { type: "paragraph", children: [txt("x ^new")], data: { hProperties: { id: "block-old" } } };
    run(root(p));
    expect(p.data.hProperties.id).toBe("block-old");
  });

  it("hoists a list-item block id onto the <li> so tight lists keep the anchor", () => {
    const inner = para(txt("buy milk ^todo1"));
    const li: MNode = { type: "listItem", children: [inner] };
    const list: MNode = { type: "list", children: [li] };
    run(root(list));
    // id lives on the listItem (survives the dropped <p> in a tight list)…
    expect((li.data as { hProperties: { id: string } }).hProperties.id).toBe("block-todo1");
    // …and was removed from the inner paragraph so it isn't duplicated.
    expect((inner.data as { hProperties?: { id?: string } } | undefined)?.hProperties?.id).toBeUndefined();
    expect((inner.children![0] as { value: string }).value).toBe("buy milk");
  });
});

describe("remarkWikilinks block-id preservation on embed lift", () => {
  it("carries a block id onto the lifted embed when the paragraph is discarded", () => {
    // As the pipeline would be after remarkBlockIds: an embed-only paragraph
    // carrying a block-id anchor.
    const embed = { type: "wikiEmbed", data: { hName: "wiki-embed", hProperties: { target: "Note" } } };
    const p = { type: "paragraph", children: [embed], data: { hProperties: { id: "block-myblock" } } };
    const tree = { type: "root", children: [p] };
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    remarkWikilinks()(tree as any);
    const lifted = tree.children[0] as unknown as typeof embed;
    expect(lifted.type).toBe("wikiEmbed");
    expect((lifted.data.hProperties as { id?: string }).id).toBe("block-myblock");
  });
});
