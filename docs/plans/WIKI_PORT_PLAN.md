# Granite → Memory-Wiki Web Port — Master Plan

Porting the Obsidian-clone **granite** (`~/Projects/granite`, React+Vite+TS, ~51k LOC)
into the **www** frontend as the management/edit/explore/view/enrich UI for the
**Memory Wiki** (SQLite document→chunk→entity/edge store).

## Ground rules
- **A wiki page = a `DocumentRow`.** Tags = `.tag` entities. Links/graph = entity/edge graph.
- **Backend** wiki RPC lives in `Sources/WikiQueryKit` + `RequestRouter` (deny-default,
  read-only; writes are a later, gated surface). Swift build is serialized (`.build` lock).
- **Frontend** porting: new components under `www/src/components/wiki/`. Convert granite's
  Obsidian tokens → www tokens (see the token map; `wiki.css`). Reuse www's react-markdown /
  shiki / mermaid / katz — do NOT add markdown-it. CodeMirror added only at M4.
- **Per milestone:** parallel port (disjoint new files) → adversarial review (fresh agents)
  → integrate (shared-file edits by the lead) → typecheck+build → Playwright visual inspect
  vs Obsidian refs → `/codex:review` → commit + push.
- **Dev gateway** for Playwright: `CODEXKIT_WEB_INSECURE=1 CODEXKIT_MEMORY=1 codexd --listen off
  --listen-web 127.0.0.1:8443` (plain http/ws; the TLS cert blocks the automation browser).

## Milestones
- **M0 — Foundation** ✅ shipped (`5b154f4`/`66221f9`/`198c969`). wiki/* RPC, connector,
  Wiki nav + repurposed sidebar, /wiki route, WikiPage shell, dim-fallback. Verified live.
- **M1 — Browse/Read.** Granite read surface: markdown extensions (wikilinks `[[ ]]`, embeds
  `![[ ]]`, callouts `> [!note]`, `==highlight==`, footnotes); reading view; clickable
  hierarchical Tags pane; Properties/frontmatter; Outline; Backlinks/Connections. Right-rail
  tabs. Tag click → filtered list.
- **M2 — Graph.** Port granite's force-directed canvas graph (Barnes-Hut sim) fed by
  `wiki/graph` (entity/edge graph, ego-betweenness sizing). Clickable nodes/tags, hover, pan/
  zoom, local-graph + controls panel. Full-screen graph view + per-page local graph.
- **M3 — Search + command palette.** Search panel (operators) over `wiki/search` (hybrid via
  MemoryRetriever — adds the inference assembly), command palette + quick switcher (reuse cmdk).
- **M4 — Editor.** CodeMirror 6 live-preview editor; create/edit/save → new `wiki/page/upsert`
  RPC (upsertDocument + re-chunk via MemoryProcess); inline title; autocomplete (wikilink/tag).
- **M5 — Enrich (AI).** Wire scoring/brain/insight pipeline + persona lens + wiki_* synthesis
  to the UI via RPC; "enrich this page" actions; insight cards; novelty/importance surfacing.
- **M6 (optional)** — bases (DB views), canvas.

## Status log
- 2026-06-08: M0 shipped + live-verified (16 real pages render). Insecure dev gateway up.
  Token-map + read-view blueprints at `/tmp/wiki_bp_*.md`. M1 starting.
