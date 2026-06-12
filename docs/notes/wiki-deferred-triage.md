# Wiki transmigration — deferred-item triage

Closing note for the granite→codex-swift wiki port. The earlier backlog tagged a
handful of items "DEFERRED (XL/low-value)". This records the disposition of each
after the M26–M32 + gap-closing sweep, so a future reader doesn't re-open
already-settled scope.

## Done (the backlog entry was stale)

- **Live-preview-in-editor** — DONE. `www/src/components/wiki/editor/livePreview.ts`
  is a full CodeMirror-6 `ViewPlugin` (≈430 lines) that hides markdown markers
  on inactive lines and styles headings / emphasis / code / quotes / wikilinks
  inline; wired in `WikiEditor.tsx` (gated by the live-preview setting, with a
  link-resolution probe). Nothing left to build.

## Not applicable to this architecture (no work — by design)

- **Filesystem watch.** Obsidian watches a vault directory and reloads files
  changed on disk. There is **no filesystem vault here**: a wiki "page" is a
  `DocumentRow` in the SQLite memory store, mutated only through the `wiki/*`
  RPCs. The real need — "reflect a change made elsewhere" — is already covered:
  cross-window edits propagate via the BroadcastChannel workspace sync (M23d)
  and a save bumps `dataVersion`, which refetches the page / rail / indexes. A
  file watcher would have nothing to watch.

- **Internationalization (i18n).** This is an **app-shell concern, not a wiki
  feature** — the whole `www/` UI (chat, threads, settings, …) shares one
  string surface. Retrofitting message catalogs is an app-wide initiative that
  shouldn't be scoped to, or forked inside, the wiki section. Deferred to an
  app-level i18n effort; no wiki-specific work is correct here.

## Deliberately not building (low value / wrong fit)

- **Plugin / theme / snippet platform.** Obsidian's plugin system loads
  arbitrary third-party JavaScript with full app + vault access. In a curated,
  single-operator memory wiki served by `codexd`, an untrusted-code loader is a
  real security liability with no third-party ecosystem to justify it. The
  *useful slices* that do **not** require an arbitrary-code platform are already
  present:
  - **Theming** — the UI is driven by CSS custom properties and a `.dark`
    class; restyling is a stylesheet edit, not a plugin.
  - **Extensibility** — the command registry (`commands/commandRegistry.ts`) is
    the first-party extension point: register a `WikiCommand`, get it in the
    palette, the dispatcher, and the (now rebindable) shortcuts UI for free.
  Recommendation stands: do **not** ship an untrusted plugin host; the command
  registry + CSS-variable theming cover the genuine need.

## Net

Every applicable backlog and deferred item from the granite transmigration is
now either implemented or has a recorded, deliberate disposition. The remaining
"not built" entries are scope decisions, not gaps.
