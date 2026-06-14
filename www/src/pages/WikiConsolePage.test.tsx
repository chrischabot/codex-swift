import * as React from "react";
import { describe, it, expect, vi, afterEach } from "vitest";
import { render, screen, fireEvent, waitFor, cleanup } from "@testing-library/react";
import { MemoryRouter } from "react-router-dom";
import { RuntimeProvider } from "@/runtime/RuntimeProvider";
import { makeMockConnector } from "@/runtime/connector-mock";
import type { Connector, WikiPageSummary, WikiBrief, WikiStatus, WikiWatchSource } from "@/runtime/connector";
import { WikiConsolePage } from "./WikiConsolePage";

afterEach(cleanup);

function renderWith(connector: Connector) {
  const factory = () => Promise.resolve(connector);
  return render(
    <RuntimeProvider factory={factory}>
      <MemoryRouter initialEntries={["/wiki/console"]}>
        <WikiConsolePage />
      </MemoryRouter>
    </RuntimeProvider>,
  );
}

describe("WikiConsolePage", () => {
  it("runs a search and renders the hits", async () => {
    const hits: WikiPageSummary[] = [
      { id: "p1", title: "Retrieval-Augmented Generation", excerpt: "RAG combines retrieval…", source: "web" },
      { id: "p2", title: "Vector Databases", excerpt: "FAISS, HNSW…", source: "arxiv" },
    ];
    const searchWiki = vi.fn(async () => hits);
    const connector = { ...makeMockConnector(), searchWiki } as Connector;
    renderWith(connector);

    const input = await screen.findByLabelText("Search query");   // wait for the page to mount
    fireEvent.change(input, { target: { value: "rag" } });
    fireEvent.submit(input.closest("form")!);

    await waitFor(() => expect(screen.getByText("Retrieval-Augmented Generation")).toBeTruthy());
    expect(screen.getByText("Vector Databases")).toBeTruthy();
    expect(searchWiki).toHaveBeenCalledWith("rag", { limit: 25 });
  });

  it("generates a cited brief", async () => {
    const brief: WikiBrief = {
      topic: "RAG", summary: "Retrieval-augmented generation grounds LLMs in retrieved context.",
      confidence: "medium",
      key_points: [{ text: "RAG reduces hallucination", citation_ids: ["c1"] }],
      citations: [{ id: "c1", doc_uri: "https://example.com/rag", snippet: "…" }],
    };
    const getWikiBrief = vi.fn(async () => brief);
    const connector = { ...makeMockConnector(), getWikiBrief } as Connector;
    renderWith(connector);

    // switch to the Brief tab — Radix TabsTrigger activates on mousedown, not click
    const briefTab = await screen.findByRole("tab", { name: /brief/i });
    fireEvent.mouseDown(briefTab, { button: 0 });
    const topic = await screen.findByLabelText("Brief topic");
    fireEvent.change(topic, { target: { value: "RAG" } });
    fireEvent.submit(topic.closest("form")!);

    await waitFor(() => expect(screen.getByText(/grounds LLMs in retrieved context/)).toBeTruthy());
    expect(screen.getByText("RAG reduces hallucination")).toBeTruthy();
    expect(screen.getByText(/example\.com\/rag/)).toBeTruthy();
    expect(getWikiBrief).toHaveBeenCalledWith("RAG", { k: 8 });
  });

  it("loads the status dashboard when its tab opens", async () => {
    const status: WikiStatus = {
      documents: 4986, pages: 2, flaggedStale: 1,
      recentJobs: [
        { jobID: "j1", input: "https://github.com/openai", status: "done",
          candidates: 4, written: 4, skipped: 0, failed: 0 },
      ],
    };
    const getWikiStatus = vi.fn(async () => status);
    const connector = { ...makeMockConnector(), getWikiStatus } as Connector;
    renderWith(connector);

    fireEvent.mouseDown(await screen.findByRole("tab", { name: /status/i }), { button: 0 });
    await waitFor(() => expect(screen.getByText("4,986")).toBeTruthy());     // doc count
    expect(screen.getByText("Raw documents")).toBeTruthy();
    expect(screen.getByText("https://github.com/openai")).toBeTruthy();      // recent job
    expect(getWikiStatus).toHaveBeenCalledTimes(1);
  });

  it("lists watched sources when the Watch tab opens", async () => {
    const sources: WikiWatchSource[] = [
      { id: "https://github.com/openai", cadence: "hot", status: "active", errorCount: 0, due: true },
      { id: "https://blog/feed", cadence: "warm", status: "paused", errorCount: 0, due: false },
    ];
    const getWikiWatch = vi.fn(async () => sources);
    const connector = { ...makeMockConnector(), getWikiWatch } as Connector;
    renderWith(connector);

    fireEvent.mouseDown(await screen.findByRole("tab", { name: /watch/i }), { button: 0 });
    await waitFor(() => expect(screen.getByText("https://github.com/openai")).toBeTruthy());
    expect(screen.getByText("https://blog/feed")).toBeTruthy();
    expect(screen.getByText("due now")).toBeTruthy();
    expect(getWikiWatch).toHaveBeenCalledTimes(1);
  });
});
