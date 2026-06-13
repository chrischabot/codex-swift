# Guarded agent wiki-write tools

**Status: SHIPPED, deny-default.** `WikiCreatePageTool`
(`Sources/MemoryMCP/WikiWriteTools.swift`) is implemented + tested
(`Tests/MemoryMCPTests/WikiWriteToolsTests.swift`) and wired into
`MemoryToolset.tools()` behind the env opt-in `CODEXKIT_WIKI_AGENT_WRITE=1`. With
the flag unset (the default) the agent's capability surface is unchanged. This
doc specifies the tools, the safety locks, the wiring, and the open questions for
the follow-ons (`wiki_update_page` with the source-URI lock; later
delete/rename).

## The asymmetry being closed

The agent has 4 **read-only** wiki tools (`wiki_brief`/`wiki_compare`/
`wiki_angle`/`wiki_pmfit` in `Sources/MemoryMCP/WikiProductionTools.swift`,
wired in `Sources/MemoryMCP/MemoryToolset.swift`'s `tools()`). The backend has
full write RPCs (`upsert`/`delete`/`rename` in
`Sources/WikiQueryKit/WikiQueryWiring.swift`), exercised only by the human UI.
So research the agent does can find gaps it cannot capture. Guarded write tools
let it consolidate/synthesize as part of its loop.

## Tool design (propose 2; defer delete/rename)

### `wiki_create_page(title, body, tags?)`
Creates a manual page. Maps to the existing manual-write path
(`store.rewriteManualPage` + a content-addressed body file under
`<store-dir>/wiki-bodies`, source URI `wiki://manual/<uuid>` — exactly what
`WikiJSON.upsert(id: nil)` does).

- **Idempotency** (no thrash on retries): before creating, look for an existing
  `.manual` document with the same normalized title AND the same content-SHA
  (`store.documents()` filtered to `source == .manual`). If found, return its id
  instead of creating a duplicate.
- **Zero spend**: `rewriteManualPage` chunks lexically with zero-vector
  embeddings — no model/embedding calls. Same posture as the read tools
  (`retrieval.cloud_spend_usd = 0`).

### `wiki_update_page(id|title, body)`
Overwrites an EXISTING manual page's body.

- **Source-URI lock (the load-bearing safety rule)**: refuse with a structured
  error unless the target document's `sourceURI` starts with `wiki://manual/`.
  The agent may NOT overwrite imported pages (`wiki://import/…`) or anything
  authored outside the manual surface. This prevents an agent from clobbering
  human/imported knowledge.

### Deferred: `wiki_delete_page` / `wiki_rename_page`
Higher blast radius (rename triggers cross-vault link rewrite; delete is
destructive). Not in the first round.

## Prototype: `WikiCreatePageTool` (ready to drop in)

```swift
// Sources/MemoryMCP/WikiWriteTools.swift  (NEW — not yet wired into tools())
import Foundation
import Crypto
import MemoryStore
import Tools

/// Agent-authored page creation. Idempotent (dedupe by manual title + body SHA),
/// zero-spend (lexical chunks only). GATED: only surfaced when the maintainer
/// opts in (see MemoryToolset wiring). parallelSafe=false (it writes); note that
/// parallelSafe is NOT a security boundary — exposure is gated at wiring time.
public struct WikiCreatePageTool: Tool {
    public let name = "wiki_create_page"
    public let parallelSafe = false
    public let toolDescription =
        "Create a manual Memory Wiki page (agent-authored). Idempotent by title+content; local only, no cloud spend."
    public let jsonSchema = """
    {"type":"object","required":["title","body"],"properties":{
      "title":{"type":"string","minLength":1},
      "body":{"type":"string"}}}
    """
    private let store: MemoryStore
    public init(store: MemoryStore) { self.store = store }

    public func run(_ call: ToolCall, cwd: String) async throws -> ToolResult {
        struct Args: Codable { var title: String?; var body: String? }
        guard let a = MCPJSON.decode(call.argumentsJSON, as: Args.self),
              let title = a.title, !title.trimmingCharacters(in: .whitespaces).isEmpty,
              let body = a.body else {
            return ToolResult(callId: call.callId, output: "invalid wiki_create_page arguments",
                              success: false, truncated: false)
        }
        let data = Data(body.utf8)
        let sha = Data(SHA256.hash(data: data))
        let normTitle = title.trimmingCharacters(in: .whitespaces).lowercased()

        // Idempotency: a manual page with the same title + same content already exists.
        if let existing = try await store.documents().first(where: {
            $0.source == .manual && ($0.title ?? "").trimmingCharacters(in: .whitespaces).lowercased() == normTitle && $0.contentSHA == sha
        }) {
            return ToolResult(callId: call.callId,
                              output: #"{"id":\#(existing.id),"created":false,"cloud_spend_usd":0}"#,
                              success: true, truncated: false)
        }

        // Create. bodyRoot mirrors WikiQueryWiring: next to the store db.
        let bodyRoot = (store.path as NSString).deletingLastPathComponent + "/wiki-bodies"
        try FileManager.default.createDirectory(atPath: bodyRoot, withIntermediateDirectories: true)
        let shaHex = sha.map { String(format: "%02x", $0) }.joined()
        let bodyPath = bodyRoot + "/" + shaHex + ".md"
        try body.write(toFile: bodyPath, atomically: true, encoding: .utf8)
        let now = Int64(Date().timeIntervalSince1970)
        let id = try await store.rewriteManualPage(
            sourceURI: "wiki://manual/\(UUID().uuidString)", title: title,
            bodyPath: bodyPath, contentSHA: sha, rawBytes: Int64(data.count),
            now: now, chunkTexts: body.components(separatedBy: "\n\n"))
        return ToolResult(callId: call.callId,
                          output: #"{"id":\#(id),"created":true,"cloud_spend_usd":0}"#,
                          success: true, truncated: false)
    }
}
```

(`store.path` is `public`; `store.documents()`, `store.rewriteManualPage` are the
same APIs `WikiJSON.upsert` uses. Confirm `DocumentRow.contentSHA`/`source`
field names against `MemoryStore` before building.)

### Test (`Tests/.../WikiWriteToolsTests.swift`)
- create → returns `{created:true, id>0}`; the page is then findable via
  `WikiJSON.list`/`pageGet`.
- create the SAME title+body again → `{created:false}`, same id, no duplicate
  (`store.documentCount()` unchanged).
- create the same title with DIFFERENT body → a new page (different SHA).
- assert `cloud_spend_usd == 0` and no embedding/model calls (use the mock
  inference provider; it should never be invoked).

## Wiring (the maintainer sign-off step — one line, OFF by default)

In `MemoryToolset.tools()`, append behind an explicit opt-in so the agent's
default capability surface is UNCHANGED:

```swift
var t: [any Tool] = [ /* existing read tools */ ]
if ProcessInfo.processInfo.environment["CODEXKIT_WIKI_AGENT_WRITE"] == "1" {
    t.append(WikiCreatePageTool(store: store))
}
return t
```

Deny-default: absent the env flag, the tool is not exposed at all. This is the
correct posture until the gating questions below are decided. Do NOT make it
default-on.

## Gating design (decide before exposing)

- **Approval level**: write tools should be approval-gated (`onRequest`) by
  default so the operator confirms each write. Unattended/cron turns are already
  locked to read-only via `SessionConfig` (`.never`/`.readOnly`/no-network); the
  write tool must be EXCLUDED there — verify the lockdown crosses the
  spawned-worker boundary for tool exposure, not just sandbox/network.
- **Audit**: tool calls are already recorded in the rollout — confirm a
  `wiki_create_page` call + its result id are traceable.
- **Conflict/versioning**: `wiki_create_page` is create-only (idempotent), so no
  conflict. `wiki_update_page` (later) needs a last-write-wins-or-detect decision.

## Open questions

1. Default approval level for write tools (`onRequest` proposed) and the exact
   exclusion in unattended turns.
2. Should agent-authored pages get their own source-URI namespace
   (`wiki://agent/…`) distinct from `wiki://manual/…`, so the UI can badge them
   and `wiki_update_page`'s lock can be precise?
3. Do `wiki_update_page`/`delete`/`rename` follow, and in what order?
4. Should creation also mint/attach entities + claims (ties into
   [`wiki-claim-schema.md`](wiki-claim-schema.md)) or stay pure-page for v1?

## Recommendation

Land the prototype + test as DEAD CODE (unwired) once the field names are
confirmed; gate exposure behind `CODEXKIT_WIKI_AGENT_WRITE` only after the
maintainer settles Q1–Q2. Then `wiki_update_page` with the source-URI lock; then
(separately, with more care) delete/rename.
