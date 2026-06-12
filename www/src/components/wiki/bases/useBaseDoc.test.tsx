import * as React from "react";
import { describe, it, expect, vi } from "vitest";
import { renderHook, waitFor, act } from "@testing-library/react";
import { RuntimeProvider } from "@/runtime/RuntimeProvider";
import { makeMockConnector } from "@/runtime/connector-mock";
import type { Connector, WikiPage, WikiPageSummary } from "@/runtime/connector";
import { useBaseRows } from "./useBaseDoc";
import { DEFAULT_BASE, readPageProperties } from "./basesSchema";

// Build a Connector whose wiki methods serve a small in-memory corpus, layered
// over the mock connector (which supplies the non-wiki surface). `saveSpy` lets
// us assert/override persistence.
function makeWikiConnector(
  pages: Record<string, { title: string; content: string }>,
  opts?: { failSave?: boolean },
) {
  const saveSpy = vi.fn(async (input: { id?: string; title?: string; body: string }) => {
    if (opts?.failSave) return null;
    if (input.id) pages[input.id] = { title: input.title ?? pages[input.id].title, content: input.body };
    return input.id ? { id: input.id } : null;
  });
  const connector: Connector = {
    ...makeMockConnector(),
    listWikiPages: async (): Promise<WikiPageSummary[]> =>
      Object.entries(pages).map(([id, p]) => ({ id, title: p.title })),
    getWikiPage: async (id: string): Promise<WikiPage | null> => {
      const p = pages[id];
      return p ? ({ id, title: p.title, content: p.content } as WikiPage) : null;
    },
    saveWikiPage: saveSpy,
  };
  return { connector, saveSpy, pages };
}

function wrapperFor(connector: Connector) {
  // Stable factory reference — a fresh arrow per render would re-run
  // RuntimeProvider's [factory] effect, resetting rows mid-test.
  const factory = () => Promise.resolve(connector);
  return ({ children }: { children: React.ReactNode }) => (
    <RuntimeProvider factory={factory}>{children}</RuntimeProvider>
  );
}

describe("useBaseRows.editCell", () => {
  it("optimistically updates + persists a frontmatter property", async () => {
    const { connector, saveSpy, pages } = makeWikiConnector({
      p1: { title: "Page One", content: "---\nstatus: draft\n---\nbody" },
    });
    const { result } = renderHook(() => useBaseRows(DEFAULT_BASE), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(result.current.rows.length).toBe(1));

    let err: string | null = "x";
    await act(async () => {
      err = await result.current.editCell("p1", "status", "done");
    });
    expect(err).toBeNull();
    // Persisted: the saved body has status: done.
    expect(saveSpy).toHaveBeenCalledTimes(1);
    expect(readPageProperties(pages.p1.content).status).toBe("done");
    // Optimistic row reflects the new value.
    expect(result.current.rows[0].props.status).toBe("done");
  });

  it("reverts the optimistic row when the save fails", async () => {
    const { connector, result: _r } = (() => {
      const built = makeWikiConnector(
        { p1: { title: "Page One", content: "---\nstatus: draft\n---\nbody" } },
        { failSave: true },
      );
      return { ...built, result: null };
    })();
    const { result } = renderHook(() => useBaseRows(DEFAULT_BASE), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(result.current.rows.length).toBe(1));

    let err: string | null = null;
    await act(async () => {
      err = await result.current.editCell("p1", "status", "done");
    });
    expect(err).toBeTruthy(); // a non-null error string
    expect(result.current.rows[0].props.status).toBe("draft"); // reverted
  });

  it("is a no-op for an unknown page id", async () => {
    const { connector, saveSpy } = makeWikiConnector({
      p1: { title: "Page One", content: "---\nstatus: draft\n---\nbody" },
    });
    const { result } = renderHook(() => useBaseRows(DEFAULT_BASE), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(result.current.rows.length).toBe(1));

    await act(async () => {
      await result.current.editCell("nope", "status", "done");
    });
    expect(saveSpy).not.toHaveBeenCalled();
  });
});
