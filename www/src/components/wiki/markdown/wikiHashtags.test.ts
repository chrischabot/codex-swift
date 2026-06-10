import { describe, it, expect } from "vitest";
import { remarkHashtags } from "./wikiRemarkPlugins";

// CLAIM (M24): inline `#tag` tokens (not headings, not inside code) become
// `wikiTag` link nodes carrying a `wikitag:<body>` URL + `data-wikitag`. A `#`
// only starts a tag at a separator boundary; an all-numeric or empty body is
// not a tag; literal nodes (code/inlineCode) are skipped.

type MNode = {
  type: string;
  value?: string;
  url?: string;
  children?: MNode[];
  data?: { hName?: string; hProperties?: Record<string, unknown> };
};

const txt = (value: string): MNode => ({ type: "text", value });
const para = (...children: MNode[]): MNode => ({ type: "paragraph", children });
const root = (...children: MNode[]): MNode => ({ type: "root", children });

function run(tree: MNode): MNode {
  // eslint-disable-next-line @typescript-eslint/no-explicit-any
  remarkHashtags()(tree as any);
  return tree;
}

function tagsOf(node: MNode): MNode[] {
  const out: MNode[] = [];
  const walk = (n: MNode) => {
    if (n.type === "wikiTag") out.push(n);
    for (const c of n.children ?? []) walk(c);
  };
  walk(node);
  return out;
}

describe("remarkHashtags", () => {
  it("rewrites a leading hashtag into a wikiTag link node", () => {
    const tree = run(root(para(txt("#project is due"))));
    const tags = tagsOf(tree);
    expect(tags).toHaveLength(1);
    expect(tags[0].url).toBe("wikitag:project");
    expect(tags[0].data?.hName).toBe("a");
    expect(tags[0].data?.hProperties?.["data-wikitag"]).toBe("project");
    expect((tags[0].children?.[0] as MNode).value).toBe("#project");
  });

  it("requires a separator boundary before the #", () => {
    // `a#b` (no boundary) must NOT become a tag.
    expect(tagsOf(run(root(para(txt("email a#b please")))))).toHaveLength(0);
    // After a space / open-paren / open-bracket it does.
    expect(tagsOf(run(root(para(txt("see (#tag) and [#two]")))))).toHaveLength(2);
  });

  it("supports hierarchy slashes, hyphens, underscores", () => {
    const tags = tagsOf(run(root(para(txt("#area/sub-topic_1 done")))));
    expect(tags).toHaveLength(1);
    expect(tags[0].url).toBe("wikitag:area/sub-topic_1");
  });

  it("does NOT treat all-numeric or empty bodies as tags", () => {
    expect(tagsOf(run(root(para(txt("issue #42 and # alone")))))).toHaveLength(0);
  });

  it("splits surrounding text into siblings preserving order", () => {
    const tree = run(root(para(txt("before #mid after"))));
    const p = tree.children![0];
    expect(p.children!.map((c) => c.type)).toEqual(["text", "wikiTag", "text"]);
    expect((p.children![0] as MNode).value).toBe("before ");
    expect((p.children![2] as MNode).value).toBe(" after");
  });

  it("skips literal nodes (inline code)", () => {
    const tree = run(root(para(txt("run "), { type: "inlineCode", value: "#nope" })));
    expect(tagsOf(tree)).toHaveLength(0);
  });

  it("handles multiple tags in one text node", () => {
    expect(tagsOf(run(root(para(txt("#a #b #c")))))).toHaveLength(3);
  });
});
