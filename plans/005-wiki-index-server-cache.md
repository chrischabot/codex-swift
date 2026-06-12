# Plan 005: Make `wiki/index` incremental with an mtime-keyed body cache

> **Executor instructions**: Step by step; verify each step; honor STOP
> conditions; update `plans/README.md` when done.
>
> **Drift check (run first)**: `git diff --stat 882865b..HEAD -- Sources/WikiQueryKit/WikiQueryWiring.swift Sources/Supervisor/WikiQueryHandle.swift` — mismatch vs excerpts below = STOP.

## Status

- **Priority**: P2
- **Effort**: M
- **Risk**: MED
- **Depends on**: none (but the client behavior it serves is covered by plan 002)
- **Category**: perf
- **Planned at**: commit `882865b`, 2026-06-12

## Why this matters

`WikiJSON.index` (the `wiki/index` RPC shaper) reads **every page body file from disk on every call** and re-parses each for `[[wikilinks]]` + frontmatter. The React client module-caches the result, so it isn't called per navigation — but it IS called on first use of backlinks/properties and **again after every page edit** (the client bumps `dataVersion` on save/rename/delete, invalidating its cache). On a ~5,000-page vault that's ~5,000 `String(contentsOfFile:)` reads + 5,000 regex passes per edit — a multi-second, fully-redundant scan when typically one file changed. An mtime-keyed per-file cache makes the call incremental: stat all files (cheap), re-read+parse only the ones whose modification time changed.

## Current state

`Sources/WikiQueryKit/WikiQueryWiring.swift` — the shaper (verified, 882865b):

```swift
public static func index(_ store: MemoryStore) async throws -> JSONValue {
    let rows = try await store.documentChunkSummaries(limit: 100_000, orderByRecency: false)
    var items: [JSONValue] = []
    items.reserveCapacity(rows.count)
    for s in rows {
        let body = (try? String(contentsOfFile: s.document.bodyPath, encoding: .utf8)) ?? ""
        guard !body.isEmpty else { continue }
        let links = wikilinkTargets(in: body)         // private helper, regex over masked body
        let props = frontmatterProps(in: body)        // private helper, parses leading YAML
        if links.isEmpty && props.isEmpty { continue }
        var obj: [String: JSONValue] = [
            "id": .int(s.document.id),
            "title": .string(s.document.title ?? s.document.sourceURI),
        ]
        if !links.isEmpty { obj["links"] = .array(links.map { JSONValue.string($0) }) }
        if !props.isEmpty { obj["props"] = .object(props.mapValues { JSONValue.string($0) }) }
        items.append(.object(obj))
    }
    return .object(["data": .array(items)])
}
```

- `s.document.bodyPath` is the on-disk path; `s.document.id`/`title`/`sourceURI` are the identity fields.
- `wikilinkTargets(in:)` and `frontmatterProps(in:)` are existing `private static` helpers in the same enum — keep them; the cache stores their OUTPUT.
- The shaper is invoked via the `WikiQueryHandle.index` closure built in `WikiQueryWiring.make(...)`:
  `index: { try await WikiJSON.index(store) }` (verified). `make` runs once per store open; the handle is shared across per-tab routers (`Sendable`).
- Wiki RPC test target exists (per repo: `WikiJSONTests`, ~16 tests, drives the shapers against a temp DB). Find it: `grep -rl "WikiJSON" Tests/`.

## Commands you will need

| Purpose | Command | Expected |
|---|---|---|
| Build daemon | `swift build --product codexd` | exit 0 |
| Wiki shaper tests | `swift test --filter WikiJSON` | pass (existing + new) |
| (read-only) find tests | `grep -rl "WikiJSON" Tests/` | a test file path |

Note: a full `swift test` is slow (~971 tests). Use `--filter` for the loop; run the full suite once at the end only if time permits.

## Scope

**In scope**:
- `Sources/WikiQueryKit/WikiQueryWiring.swift` — add an actor cache type and an `index(_:cache:)` overload (or a `cache` parameter) that uses it; keep the existing 0-arg-ish signature working or update the single call site.
- `Sources/WikiQueryKit/` — a new small file for the cache actor is fine (e.g. `WikiIndexCache.swift`), matching the package's file-per-type style where present.
- `Sources/Supervisor/WikiQueryHandle.swift` — ONLY if the `index` closure type must change (it should not — keep `index: @Sendable () async throws -> JSONValue`).
- The wiki shaper test file (extend with a caching test).

**Out of scope** (do NOT touch):
- `wikilinkTargets`/`frontmatterProps` parsing logic — behavior must be identical; the cache only memoizes their results.
- Any mem0 file: `Sources/Mem0Core/*`, `Sources/codex-mem0/*`, `Tests/Mem0CoreTests/*`, `Sources/Mem0Core/BackendResolution.swift`, `docs/MEM0.md`. (Owned by a parallel effort — never edit.)
- The `MemoryStore` actor and `documentChunkSummaries`.
- The other shapers (list/pageGet/search/graph/backlinks/tags/upsert/delete/rename/brief).

## Git workflow

- Branch: `advisor/005-wiki-index-server-cache`
- Commit style: `perf(wiki): incremental mtime-keyed cache for wiki/index`
- No push/PR unless instructed.

## Steps

### Step 1: Add the cache actor

Create `Sources/WikiQueryKit/WikiIndexCache.swift`. An `actor` holding `[String: Entry]` keyed by `bodyPath`, where `Entry` is `(mtimeNanos: Int64, links: [String], props: [String: String])`. Expose:

```swift
actor WikiIndexCache {
    private struct Entry { let mtime: Date; let links: [String]; let props: [String: String] }
    private var byPath: [String: Entry] = [:]
    /// Returns cached parse for `path` if the file's mtime is unchanged; else nil.
    func cached(path: String, mtime: Date) -> (links: [String], props: [String: String])? { … }
    func store(path: String, mtime: Date, links: [String], props: [String: String]) { … }
    /// Drop entries whose path is no longer present (called with the live path set).
    func prune(livePaths: Set<String>) { … }
}
```

Use `Date` equality on the file's `modificationDate`. Get mtime via `FileManager.default.attributesOfItem(atPath:)[.modificationDate] as? Date`.

**Verify**: `swift build --product codexd` → exit 0.

### Step 2: Thread the cache through `index`

Change `index` to accept the cache and use it:

```swift
public static func index(_ store: MemoryStore, cache: WikiIndexCache) async throws -> JSONValue {
    let rows = try await store.documentChunkSummaries(limit: 100_000, orderByRecency: false)
    var items: [JSONValue] = []
    var livePaths = Set<String>()
    for s in rows {
        let path = s.document.bodyPath
        livePaths.insert(path)
        let mtime = (try? FileManager.default.attributesOfItem(atPath: path)[.modificationDate]) as? Date
        var links: [String]; var props: [String: String]
        if let mtime, let hit = await cache.cached(path: path, mtime: mtime) {
            links = hit.links; props = hit.props
        } else {
            let body = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
            if body.isEmpty { continue }
            links = wikilinkTargets(in: body)
            props = frontmatterProps(in: body)
            if let mtime { await cache.store(path: path, mtime: mtime, links: links, props: props) }
        }
        if links.isEmpty && props.isEmpty { continue }
        var obj: [String: JSONValue] = [
            "id": .int(s.document.id),
            "title": .string(s.document.title ?? s.document.sourceURI),
        ]
        if !links.isEmpty { obj["links"] = .array(links.map { JSONValue.string($0) }) }
        if !props.isEmpty { obj["props"] = .object(props.mapValues { JSONValue.string($0) }) }
        items.append(.object(obj))
    }
    await cache.prune(livePaths: livePaths)
    return .object(["data": .array(items)])
}
```

Note the subtlety: a body that is empty OR has no links/props is skipped for output, but you must keep behavior identical — only memoize the (links, props) parse. (Empty bodies were skipped before; preserve that.)

### Step 3: Build the cache in `make` and pass it to the closure

In `WikiQueryWiring.make(...)`, create one `let indexCache = WikiIndexCache()` and change the closure to `index: { try await WikiJSON.index(store, cache: indexCache) }`. The `WikiQueryHandle.index` closure type is unchanged (`@Sendable () async throws -> JSONValue`), so `WikiQueryHandle.swift` does NOT change.

**Verify**: `swift build --product codexd` → exit 0.

### Step 4: Add a caching test

Extend the wiki shaper test file. Drive `WikiJSON.index(store, cache:)` against a temp store with a couple of manual pages (use the same setup the existing WikiJSON tests use — read them first). Assert:
- First call returns the expected `data` shape (same as before — characterize current output).
- A second call with no file changes returns the same data AND does not re-read (you can prove "no re-read" by mutating the body file's CONTENT but NOT its mtime is hard; instead assert correctness on the happy path and add a case where the body file is edited (content + mtime change via writing) → the index reflects the new links).

If the existing test harness makes mtime control awkward, at minimum assert output-equivalence to the pre-cache behavior over a fixed corpus.

**Verify**: `swift test --filter WikiJSON` → all pass.

## Test plan

- Extend the existing `WikiJSON*` test file (found via `grep -rl "WikiJSON" Tests/`).
- Cases: output shape unchanged on first call; re-call returns identical data; editing a page body (rewrite the file) makes the next call reflect the change (cache invalidates by mtime); a deleted page's path is pruned.
- Model after the existing WikiJSON shaper tests (temp DB + manual upsert).

## Done criteria

ALL must hold:
- [ ] `swift build --product codexd` exits 0
- [ ] `swift test --filter WikiJSON` passes (existing + ≥2 new cache cases)
- [ ] `WikiQueryHandle.swift` is unchanged (the closure type stayed the same) — `git diff --stat` shows it untouched
- [ ] No mem0 file modified
- [ ] Output of `wiki/index` is byte-equivalent to pre-cache for an unchanged corpus (the new test asserts this)
- [ ] `plans/README.md` row updated

## STOP conditions

- Drift in the excerpted shaper.
- The mtime read is unreliable on the test platform (e.g. coarse filesystem timestamps cause flakiness) — STOP and report; consider a content-SHA key instead of mtime as a follow-up.
- Threading the cache forces a change to `WikiQueryHandle`'s closure type or any other shaper — STOP and report (it should not).
- You find the index is actually called per-navigation (not just per dataVersion) on the client — that would change the impact calculus; report it.

## Maintenance notes

- The cache is in-memory per `codexd` process; it warms on first `wiki/index` and survives across calls for the daemon's lifetime. A daemon restart re-warms it (acceptable).
- If a future change writes page bodies WITHOUT updating mtime (unusual), the cache could go stale — document the mtime assumption at the cache definition.
- A reviewer should confirm output-equivalence (the cache must not change the RPC payload) and that `prune` doesn't drop entries for pages that still exist.
- Follow-up (not this plan): a content-SHA key would be more robust than mtime but costs a read; only pursue if mtime proves flaky.
