import { describe, it, expect } from "vitest";
import {
  parseBaseConfig,
  serializeBaseConfig,
  readPageProperties,
  setFrontmatterProperty,
  applyFormulas,
  formulaColumnKeys,
  collectMapPoints,
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

  it("round-trips column summaries", () => {
    const cfg = { ...DEFAULT_BASE, summaries: { prio: "sum", status: "unique" } };
    expect(parseBaseConfig(serializeBaseConfig(cfg)).summaries).toEqual({ prio: "sum", status: "unique" });
  });

  it("omits an empty summaries map", () => {
    const cfg = { ...DEFAULT_BASE, summaries: {} };
    expect(parseBaseConfig(serializeBaseConfig(cfg)).summaries).toBeUndefined();
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

describe("setFrontmatterProperty", () => {
  const doc = "---\ntitle: My Page\nstatus: draft\n---\n# Body\n\nProse here.";

  it("replaces an existing scalar in place, preserving other keys and body", () => {
    const out = setFrontmatterProperty(doc, "status", "done");
    expect(out).toBe("---\ntitle: My Page\nstatus: done\n---\n# Body\n\nProse here.");
  });

  it("appends a new key when absent", () => {
    const out = setFrontmatterProperty(doc, "prio", "high");
    expect(readPageProperties(out)).toMatchObject({ status: "draft", prio: "high" });
    expect(out).toContain("# Body"); // body preserved
  });

  it("removes a key when the value is blank", () => {
    const out = setFrontmatterProperty(doc, "status", "");
    expect(readPageProperties(out).status).toBeUndefined();
    expect(readPageProperties(out).title).toBe("My Page");
  });

  it("creates a frontmatter block when none exists", () => {
    const out = setFrontmatterProperty("Just prose.", "status", "draft");
    expect(out).toBe("---\nstatus: draft\n---\nJust prose.");
  });

  it("quotes values with YAML-significant characters", () => {
    const out = setFrontmatterProperty(doc, "note", "a: b, c");
    expect(out).toContain('note: "a: b, c"');
    expect(readPageProperties(out).note).toBe("a: b, c");
  });

  it("preserves hand-authored frontmatter keys it doesn't touch", () => {
    const rich = "---\ntitle: T\ncustom_field: keep-me\naliases: [a, b]\n---\nbody";
    const out = setFrontmatterProperty(rich, "status", "new");
    const props = readPageProperties(out);
    expect(props.custom_field).toBe("keep-me");
    expect(props.aliases).toEqual(["a", "b"]);
    expect(props.status).toBe("new");
  });
});

describe("applyFormulas", () => {
  const content = "---\nprice: 10\nqty: 3\n---\nbody";
  const row = makeRow({ id: "1", title: "Widget" }, content);

  it("injects computed values into row props under the column key", () => {
    const cols = [
      { key: "title", label: "Title" },
      { key: "total", label: "Total", formula: "price * qty" },
    ];
    const [out] = applyFormulas([row], cols);
    expect(out.props.total).toBe(30);
    // The computed value flows through cellValue + formatCell + sort/group.
    expect(cellValue(out, "total")).toBe(30);
  });

  it("a formula can reference built-in fields", () => {
    const cols = [{ key: "label", label: "Label", formula: 'concat(title, " x", qty)' }];
    expect(applyFormulas([row], cols)[0].props.label).toBe("Widget x3");
  });

  it("returns rows unchanged when no column has a formula", () => {
    const cols = [{ key: "title", label: "Title" }];
    expect(applyFormulas([row], cols)[0]).toBe(row);
  });

  it("formulaColumnKeys lists only computed columns", () => {
    const cols = [
      { key: "a", label: "A" },
      { key: "b", label: "B", formula: "1+1" },
      { key: "c", label: "C", formula: "  " }, // blank → not computed
    ];
    expect([...formulaColumnKeys(cols)]).toEqual(["b"]);
  });

  it("round-trips a formula column through serialize/parse", () => {
    const cfg = parseBaseConfig(
      serializeBaseConfig({
        ...DEFAULT_BASE,
        columns: [{ key: "total", label: "Total", formula: "price * qty" }],
      }),
    );
    expect(cfg.columns[0].formula).toBe("price * qty");
  });
});

describe("collectMapPoints", () => {
  const cfg = { ...DEFAULT_BASE, view: "map" as const, mapLatitude: "lat", mapLongitude: "lng" };
  const row = (id: string, lat: unknown, lng: unknown) =>
    makeRow({ id, title: id }, `---\nlat: ${lat}\nlng: ${lng}\n---\n`);

  it("projects valid coordinates into 0–100% (lng→x, lat→y)", () => {
    const [p] = collectMapPoints([row("a", 0, 0)], cfg);
    expect(p.xPct).toBe(50); // lng 0 → middle
    expect(p.yPct).toBe(50); // lat 0 → middle
  });

  it("skips rows missing or out-of-range coordinates", () => {
    const pts = collectMapPoints(
      [row("a", 40.7, -74), row("b", "n/a", 10), row("c", 200, 0)],
      cfg,
    );
    expect(pts.map((p) => p.row.page.id)).toEqual(["a"]);
  });

  it("returns nothing when lat/long properties aren't configured", () => {
    expect(collectMapPoints([row("a", 0, 0)], { ...DEFAULT_BASE })).toEqual([]);
  });
});

describe("base-doc frontmatter preservation", () => {
  it("preserves hand-authored frontmatter on the base doc across save", () => {
    const doc = '---\nwiki_type: base\ntags: [maps]\nowner: chris\n---\n{"view":"map","mapLatitude":"lat","mapLongitude":"lng"}';
    const cfg = parseBaseConfig(doc);
    expect(cfg.view).toBe("map");
    expect(cfg.mapLatitude).toBe("lat");
    expect(cfg.extraFrontmatter).toContain("tags: [maps]");
    expect(cfg.extraFrontmatter).toContain("owner: chris");
    // Re-serialize → the extra keys (and wiki_type) survive; map keys persist.
    const out = serializeBaseConfig(cfg);
    expect(out).toContain("wiki_type: base");
    expect(out).toContain("tags: [maps]");
    expect(out).toContain("owner: chris");
    expect(parseBaseConfig(out).mapLatitude).toBe("lat");
  });
});
