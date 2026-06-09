import { describe, it, expect } from "vitest";
import { computeSummary } from "./baseSummaries";
import { makeRow, type BaseRow } from "./basesSchema";
import type { WikiPageSummary } from "@/runtime/connector";

const sum = (id: string, t: string): WikiPageSummary => ({ id, title: t, source: "manual" });

// Rows with a numeric `prio`, a `status`, and one missing prio.
const rows: BaseRow[] = [
  makeRow(sum("1", "A"), "---\nstatus: active\nprio: 10\n---\nx"),
  makeRow(sum("2", "B"), "---\nstatus: active\nprio: 2\n---\nx"),
  makeRow(sum("3", "C"), "---\nstatus: done\n---\nx"), // no prio
];

describe("computeSummary", () => {
  it("none → empty string", () => {
    expect(computeSummary(rows, "prio", "none")).toBe("");
  });
  it("count is total rows", () => {
    expect(computeSummary(rows, "prio", "count")).toBe("3");
  });
  it("filled / empty count non-empty vs empty cells", () => {
    expect(computeSummary(rows, "prio", "filled")).toBe("2"); // rows 1,2 have prio
    expect(computeSummary(rows, "prio", "empty")).toBe("1"); // row 3 missing
  });
  it("unique counts distinct non-empty values", () => {
    expect(computeSummary(rows, "status", "unique")).toBe("2"); // active, done
  });
  it("sum / avg / min / max over numeric cells (ignores non-numeric/missing)", () => {
    expect(computeSummary(rows, "prio", "sum")).toBe("12");
    expect(computeSummary(rows, "prio", "avg")).toBe("6"); // (10+2)/2
    expect(computeSummary(rows, "prio", "min")).toBe("2");
    expect(computeSummary(rows, "prio", "max")).toBe("10");
  });
  it("numeric ops over a non-numeric column → empty (no numeric cells)", () => {
    expect(computeSummary(rows, "status", "sum")).toBe("");
    expect(computeSummary(rows, "status", "avg")).toBe("");
  });
  it("avg trims to ≤4 decimal places", () => {
    const r: BaseRow[] = [
      makeRow(sum("1", "A"), "---\nn: 1\n---\nx"),
      makeRow(sum("2", "B"), "---\nn: 2\n---\nx"),
      makeRow(sum("3", "C"), "---\nn: 2\n---\nx"),
    ];
    expect(computeSummary(r, "n", "avg")).toBe("1.6667"); // 5/3
  });
  it("does not treat leading-zero strings as numbers (consistent with coerceScalar)", () => {
    const r: BaseRow[] = [makeRow(sum("1", "A"), '---\ncode: "007"\n---\nx')];
    expect(computeSummary(r, "code", "sum")).toBe(""); // "007" stays a string
  });
  it("does not numify a precision-losing big integer (round-trip guard)", () => {
    // 9007199254740993 > 2^53; Number() loses the last digit, so it must NOT be
    // summed (matches how coerceScalar keeps it a string).
    const r: BaseRow[] = [makeRow(sum("1", "A"), "---\nbig: 9007199254740993\n---\nx")];
    expect(computeSummary(r, "big", "sum")).toBe("");
  });
  it("sums plain negatives and decimals", () => {
    const r: BaseRow[] = [
      makeRow(sum("1", "A"), "---\nn: -5\n---\nx"),
      makeRow(sum("2", "B"), "---\nn: 2.5\n---\nx"),
    ];
    expect(computeSummary(r, "n", "sum")).toBe("-2.5");
  });
});
