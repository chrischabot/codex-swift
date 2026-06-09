import { describe, it, expect } from "vitest";
import {
  parseBaseConfig,
  serializeBaseConfig,
  readPageProperties,
  isBaseBody,
  makeRow,
  cellValue,
  formatCell,
  sortRows,
  filterRows,
  groupRows,
  discoverColumnKeys,
  DEFAULT_BASE,
  type BaseRow,
} from "./basesSchema";
import type { WikiPageSummary } from "@/runtime/connector";

const sum = (id: string, over: Partial<WikiPageSummary> = {}): WikiPageSummary => ({
  id,
  title: `Page ${id}`,
  source: "manual",
  updatedAt: Number(id) * 1000,
  ...over,
});

describe("readPageProperties / coerceScalar", () => {
  // CLAIM: frontmatter scalars are typed conservatively — leading-zero ids,
  // hex, and precision-losing big-ints stay STRINGS (numifying them loses data
  // in sort/filter/display). SEVERITY: severe (the fix this locks in).
  const props = (fm: string) => readPageProperties(`---\n${fm}\n---\nbody`);

  it("keeps leading-zero ids as strings", () => {
    expect(props("ticket: 007").ticket).toBe("007");
  });
  it("keeps hex/0x as strings", () => {
    expect(props("flags: 0x10").flags).toBe("0x10");
  });
  it("keeps precision-losing big integers as strings", () => {
    expect(props("big: 9007199254740993").big).toBe("9007199254740993");
  });
  it("does numify clean integers and decimals", () => {
    expect(props("n: 42").n).toBe(42);
    expect(props("f: 3.14").f).toBe(3.14);
    expect(props("neg: -5").neg).toBe(-5);
  });
  it("coerces booleans", () => {
    expect(props("a: true\nb: false").a).toBe(true);
    expect(props("a: true\nb: false").b).toBe(false);
  });
  it("parses inline flow lists", () => {
    expect(props("tags: [x, y, z]").tags).toEqual(["x", "y", "z"]);
  });
  it("ignores wiki_type and empty/comment lines", () => {
    const p = props("wiki_type: base\n# c\n\nkeep: 1");
    expect(p.wiki_type).toBeUndefined();
    expect(p.keep).toBe(1);
  });
});

describe("base config round-trip", () => {
  it("serialize → parse is identity for DEFAULT_BASE", () => {
    const body = serializeBaseConfig(DEFAULT_BASE);
    expect(isBaseBody(body)).toBe(true);
    expect(parseBaseConfig(body)).toEqual(DEFAULT_BASE);
  });

  it("round-trips a customized config (view, source, columns, filters, sort, group)", () => {
    const cfg = {
      ...DEFAULT_BASE,
      view: "cards" as const,
      source: { tag: "project" },
      columns: [{ key: "title", label: "Title" }, { key: "status", label: "Status" }],
      filters: [{ key: "status", op: "eq" as const, value: "active" }],
      sort: [{ key: "title", dir: "desc" as const }],
      group: "status",
    };
    const parsed = parseBaseConfig(serializeBaseConfig(cfg));
    expect(parsed.view).toBe("cards");
    expect(parsed.source).toEqual({ tag: "project" });
    expect(parsed.filters).toEqual(cfg.filters);
    expect(parsed.sort).toEqual(cfg.sort);
    expect(parsed.group).toBe("status");
  });
});

describe("isBaseBody hardening (anti-misrouting)", () => {
  it("is false for prose carrying a stray wiki_type: base marker", () => {
    expect(isBaseBody("---\nwiki_type: base\n---\n# Doc about bases\n\nprose")).toBe(false);
  });
  it("is true only with the marker AND a JSON-object body", () => {
    expect(isBaseBody("---\nwiki_type: base\n---\n{}")).toBe(true);
    expect(isBaseBody("---\nwiki_type: base\n---\n[1,2]")).toBe(false);
  });
  it("is false for plain prose / null", () => {
    expect(isBaseBody("# note")).toBe(false);
    expect(isBaseBody(null)).toBe(false);
  });
});

describe("rows: filter / sort / group / columns", () => {
  const rows: BaseRow[] = [
    makeRow(sum("3", { title: "Beta" }), "---\nstatus: active\nprio: 2\n---\nb"),
    makeRow(sum("1", { title: "Alpha" }), "---\nstatus: active\nprio: 10\n---\na"),
    makeRow(sum("2", { title: "Gamma" }), "---\nstatus: done\nprio: 1\n---\ng"),
  ];

  it("filters by eq on a frontmatter property", () => {
    const r = filterRows(rows, [{ key: "status", op: "eq", value: "active" }]);
    expect(r.map((x) => x.page.title).sort()).toEqual(["Alpha", "Beta"]);
  });
  it("filters by contains, exists, empty", () => {
    expect(filterRows(rows, [{ key: "title", op: "contains", value: "amma" }])).toHaveLength(1);
    expect(filterRows(rows, [{ key: "status", op: "exists", value: "" }])).toHaveLength(3);
    expect(filterRows(rows, [{ key: "missing", op: "empty", value: "" }])).toHaveLength(3);
  });
  it("filters numerically with gt/lt (not lexically)", () => {
    // prio values 2, 10, 1 — gt 5 must match only 10 (numeric, not string '2'>'5')
    const r = filterRows(rows, [{ key: "prio", op: "gt", value: "5" }]);
    expect(r.map((x) => x.page.title)).toEqual(["Alpha"]);
  });
  it("sorts ascending and descending by title", () => {
    expect(sortRows(rows, [{ key: "title", dir: "asc" }]).map((r) => r.page.title)).toEqual(["Alpha", "Beta", "Gamma"]);
    expect(sortRows(rows, [{ key: "title", dir: "desc" }]).map((r) => r.page.title)).toEqual(["Gamma", "Beta", "Alpha"]);
  });
  it("groups by a property into insertion-ordered buckets", () => {
    const g = groupRows(rows, "status");
    expect([...g.keys()]).toEqual(["active", "done"]);
    expect(g.get("active")).toHaveLength(2);
  });
  it("discovers custom column keys from row frontmatter", () => {
    expect(discoverColumnKeys(rows).sort()).toEqual(["prio", "status"]);
  });
  it("cellValue + formatCell render builtins and props", () => {
    const r = rows[0];
    expect(cellValue(r, "title")).toBe("Beta");
    expect(cellValue(r, "status")).toBe("active");
    expect(formatCell(["a", "b"], "tags")).toContain("a");
  });
});
