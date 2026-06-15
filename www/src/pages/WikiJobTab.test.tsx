import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, cleanup } from "@testing-library/react";
import { RuntimeProvider } from "@/runtime/RuntimeProvider";
import { makeMockConnector } from "@/runtime/connector-mock";
import type { Connector, WikiJobLine } from "@/runtime/connector";
import { WikiJobTab, renderLine } from "./WikiJobTab";

afterEach(cleanup);

function renderWith(connector: Connector, kind: "research" | "ingest") {
  return render(
    <RuntimeProvider factory={() => Promise.resolve(connector)}>
      <WikiJobTab kind={kind} />
    </RuntimeProvider>,
  );
}

describe("renderLine", () => {
  it("formats research events + result", () => {
    expect(renderLine("research", { type: "event", kind: "started", mode: "topic" })).toContain("research started");
    expect(renderLine("research", { type: "event", kind: "sources", round: 1, count: 3 })).toContain("3 source(s)");
    expect(renderLine("research", { type: "event", kind: "compiled", round: 1, written: 2, claims: 8 })).toContain("8 claims");
    expect(renderLine("research", { type: "result", status: "completed", rounds: 1, sources: 3, pages: 2, finalScore: 44 }))
      .toContain("✓ completed");
  });
  it("formats ingest candidate + result", () => {
    expect(renderLine("ingest", { type: "event", kind: "candidate", seq: 1, status: "written", uri: "https://x" }))
      .toContain("[1] written");
    expect(renderLine("ingest", { type: "result", status: "done", written: 3, skipped: 0, failed: 0 }))
      .toContain("3 written");
  });
});

describe("WikiJobTab (research)", () => {
  it("streams progress lines and the final result", async () => {
    const events: Array<[WikiJobLine, boolean]> = [
      [{ type: "event", kind: "started", mode: "topic" }, false],
      [{ type: "event", kind: "round_started", round: 1 }, false],
      [{ type: "event", kind: "sources", round: 1, count: 3 }, false],
      [{ type: "event", kind: "compiled", round: 1, written: 2, claims: 8 }, false],
      [{ type: "result", status: "completed", rounds: 1, sources: 3, pages: 2, finalScore: 44 }, true],
    ];
    const startWikiResearch = vi.fn(async (_p, onEvent: (l: WikiJobLine, d: boolean) => void) => {
      for (const [line, done] of events) onEvent(line, done);
      return { jobId: "j1", cancel: () => {} };
    });
    const connector = { ...makeMockConnector(), startWikiResearch } as unknown as Connector;
    renderWith(connector, "research");

    const input = await screen.findByLabelText("research input");
    fireEvent.change(input, { target: { value: "graph neural networks" } });
    fireEvent.submit(input.closest("form")!);

    await waitFor(() => expect(screen.getByText(/research started/)).toBeTruthy());
    expect(screen.getByText(/3 source\(s\) gathered/)).toBeTruthy();
    expect(screen.getByText(/8 claims/)).toBeTruthy();
    expect(screen.getByText(/✓ completed — 1 round\(s\), 3 sources, 2 pages, score 44/)).toBeTruthy();
    expect(startWikiResearch).toHaveBeenCalledWith(
      expect.objectContaining({ topic: "graph neural networks", depth: "standard" }),
      expect.any(Function),
    );
  });
});

describe("WikiJobTab (ingest)", () => {
  it("streams per-candidate progress", async () => {
    const startWikiIngest = vi.fn(async (_p, onEvent: (l: WikiJobLine, d: boolean) => void) => {
      onEvent({ type: "event", kind: "candidate", seq: 1, status: "written", uri: "https://github.com/o/r1" }, false);
      onEvent({ type: "result", status: "done", written: 1, skipped: 0, failed: 0 }, true);
      return { jobId: "j2", cancel: () => {} };
    });
    const connector = { ...makeMockConnector(), startWikiIngest } as unknown as Connector;
    renderWith(connector, "ingest");

    const input = await screen.findByLabelText("ingest input");
    fireEvent.change(input, { target: { value: "https://github.com/openai" } });
    fireEvent.submit(input.closest("form")!);

    await waitFor(() => expect(screen.getByText(/\[1\] written/)).toBeTruthy());
    expect(screen.getByText(/✓ done — 1 written/)).toBeTruthy();
  });
});
