import * as React from "react";
import { describe, it, expect, vi } from "vitest";
import { renderHook, waitFor } from "@testing-library/react";
import { RuntimeProvider } from "@/runtime/RuntimeProvider";
import { makeMockConnector } from "@/runtime/connector-mock";
import type { Connector } from "@/runtime/connector";
import { createCachedIndex } from "./useCachedIndex";

function wrapperFor(connector: Connector) {
  const factory = () => Promise.resolve(connector);
  return ({ children }: { children: React.ReactNode }) => (
    <RuntimeProvider factory={factory}>{children}</RuntimeProvider>
  );
}

describe("createCachedIndex", () => {
  it("fetches once, then serves the cache to a second mount (dedup)", async () => {
    const fetchSpy = vi.fn(async () => ({ n: 1 }));
    const connector = { ...makeMockConnector(), listWikiPages: async () => [] } as Connector;
    const useIdx = createCachedIndex<{ n: number }>({ fetch: () => () => fetchSpy() });

    const a = renderHook(() => useIdx(0), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(a.result.current.loading).toBe(false));
    expect(a.result.current.entry).toEqual({ n: 1 });
    expect(fetchSpy).toHaveBeenCalledTimes(1);

    // Second consumer reuses the cache — no second fetch.
    const b = renderHook(() => useIdx(0), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(b.result.current.entry).toEqual({ n: 1 }));
    expect(fetchSpy).toHaveBeenCalledTimes(1);
  });

  it("refetches when the version bumps", async () => {
    let call = 0;
    const fetchSpy = vi.fn(async () => ({ n: ++call }));
    const connector = { ...makeMockConnector() } as Connector;
    const useIdx = createCachedIndex<{ n: number }>({ fetch: () => () => fetchSpy() });

    const h = renderHook(({ v }: { v: number }) => useIdx(v), {
      wrapper: wrapperFor(connector),
      initialProps: { v: 0 },
    });
    await waitFor(() => expect(h.result.current.entry).toEqual({ n: 1 }));

    h.rerender({ v: 1 });
    await waitFor(() => expect(h.result.current.entry).toEqual({ n: 2 }));
    expect(fetchSpy).toHaveBeenCalledTimes(2);
  });

  it("treats a null fetcher (missing capability) as empty, not loading", async () => {
    const connector = { ...makeMockConnector() } as Connector;
    const useIdx = createCachedIndex<{ n: number }>({ fetch: () => null });
    const h = renderHook(() => useIdx(0), { wrapper: wrapperFor(connector) });
    await waitFor(() => expect(h.result.current.loading).toBe(false));
    expect(h.result.current.entry).toBeNull();
  });
});
