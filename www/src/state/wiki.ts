import * as React from "react";
import { useRuntime } from "@/runtime/RuntimeProvider";
import type { WikiPage, WikiPageSummary, WikiGraph, WikiTag } from "@/runtime/connector";

// On-demand wiki reads. Deliberately NOT folded into ConnectorSnapshot — the
// snapshot re-broadcasts on every thread-stream notification, so wiki arrays
// there would re-render the whole shell on unrelated traffic. Each hook keys its
// effect on `status.kind === "connected"` so reads wait for the WS handshake
// (the connector queues pre-open RPCs, but wiki reads shouldn't race it).

/** Recent wiki pages for the sidebar list. Empty + non-loading under the mock
 *  connector (which omits the wiki methods), so the sidebar shows nothing.
 *  `enabled` gates the fetch so callers (e.g. the sidebar) don't query the wiki
 *  store on every session when the Wiki section isn't open. */
export function useWikiRecents(limit = 20, enabled = true): { pages: WikiPageSummary[]; loading: boolean } {
  const { connector, status } = useRuntime();
  const [pages, setPages] = React.useState<WikiPageSummary[]>([]);
  const [loading, setLoading] = React.useState(false);
  React.useEffect(() => {
    if (!enabled || !connector.listWikiPages || status.kind !== "connected") return;
    let alive = true;
    setLoading(true);
    connector
      .listWikiPages({ limit })
      .then((p) => { if (alive) setPages(p); })
      .catch(() => { if (alive) setPages([]); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [connector, status.kind, limit, enabled]);
  return { pages, loading };
}

/** Full page-detail hook. pageId undefined → index mode (no page loaded). The
 *  page payload already carries tags + entity connections, so no separate
 *  backlinks RPC is needed in M0. */
export function useWikiPage(pageId?: string): { page: WikiPage | null; loading: boolean } {
  const { connector, status } = useRuntime();
  const [page, setPage] = React.useState<WikiPage | null>(null);
  const [loading, setLoading] = React.useState(false);
  React.useEffect(() => {
    if (!pageId || !connector.getWikiPage || status.kind !== "connected") {
      setPage(null);
      return;
    }
    let alive = true;
    setLoading(true);
    connector
      .getWikiPage(pageId)
      .then((p) => { if (alive) setPage(p); })
      .catch(() => { if (alive) setPage(null); })
      .finally(() => { if (alive) setLoading(false); });
    return () => { alive = false; };
  }, [connector, status.kind, pageId]);
  return { page, loading };
}

/** Tag cloud (M1+ panels). */
export function useWikiTags(): WikiTag[] {
  const { connector, status } = useRuntime();
  const [tags, setTags] = React.useState<WikiTag[]>([]);
  React.useEffect(() => {
    if (!connector.getWikiTags || status.kind !== "connected") return;
    let alive = true;
    connector.getWikiTags().then((t) => alive && setTags(t)).catch(() => alive && setTags([]));
    return () => { alive = false; };
  }, [connector, status.kind]);
  return tags;
}

/** Entity/edge graph (M2 graph view). seedEntityId is an ENTITY id. */
export function useWikiGraph(opts?: { seedEntityId?: string; depth?: number }): WikiGraph {
  const { connector, status } = useRuntime();
  const [graph, setGraph] = React.useState<WikiGraph>({ nodes: [], edges: [] });
  const seedEntityId = opts?.seedEntityId;
  const depth = opts?.depth;
  React.useEffect(() => {
    if (!connector.getWikiGraph || status.kind !== "connected") return;
    let alive = true;
    connector
      .getWikiGraph({ seedEntityId, depth })
      .then((g) => alive && setGraph(g))
      .catch(() => alive && setGraph({ nodes: [], edges: [] }));
    return () => { alive = false; };
  }, [connector, status.kind, seedEntityId, depth]);
  return graph;
}
