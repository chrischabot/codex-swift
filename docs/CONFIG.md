# Config

The canonical user config lives in `~/.codex/config.toml` (a.k.a.
`$CODEX_HOME/config.toml`). The loader is in
`Sources/Config/Config.swift` (`ConfigLoader`) and is intentionally
layered so a project-local override does not have to repeat all of the
defaults, an env var can A/B a single key without editing any file, and
the highest-precedence layer (explicit CLI overrides) always wins.

## Overview

The loader composes a deep-merged `Config` value type with **origin
tracking**: every top-level key remembers which layer last set it
(`Config.origins`). The wire shape is **snake_case** because that is
upstream Rust codex's TOML wire format; the loader normalises legacy
camelCase keys onto snake_case so existing camelCase configs continue to
work.

The full layered stack (lowest → highest precedence):

```
  defaults
    └── system  ............ /etc/codex/config.toml (denylist applied)
          └── user (toml) .. $CODEX_HOME/config.toml (+ inline [profiles.<name>])
                └── profile-v2  $CODEX_HOME/<name>.config.toml (when selected)
                      └── project-local  .codex/config.toml (repo-root → cwd)
                            └── env  ........ CODEX_CFG_* env vars
                                  └── override  CLI --config / runtime
```

Each layer is a `ConfigLayer(name:, values:)`. The loader returns a
`Config(layers:profileName:)` that records the final merged tree plus the
origin map.

## Layered loading

### defaults

Built-in defaults emitted by `ConfigLoader.defaults()`. Always present;
never empty:

```swift
private func defaults() -> [String: ConfigValue] {
    [
        "model": .string("gpt-5.1-codex"),
        "approval_policy": .string("on-request"),
        "sandbox_mode": .string("workspace-write"),
        "features": .object([:]),
        "allow_login_shell": .bool(true),
        "history": .object(["persistence": .string("save-all")]),
        "project_doc_max_bytes": .int(Config.defaultProjectDocMaxBytes),
        "project_doc_fallback_filenames": .array([]),
        "hide_agent_reasoning": .bool(false),
    ]
}
```

Every entry has a matching `default_*` helper in upstream's
`config_toml.rs` (e.g. `default_allow_login_shell`, `default_history`).

### system

`/etc/codex/config.toml` — administrator-controlled global config.
Loaded via `ConfigLoader.readTOMLFile(_:)` and run through:

1. `applyDenylist(_:)` — strip credential- and transport-sensitive keys.
   System admins should not be in the credential/transport business.
2. `normalizeTopLevelAliases(_:)` — camelCase → snake_case.
3. `normalizedWithAliases(_:path:)` — recursive per-path alias rewrites
   (e.g. `[memories].no_memories_if_mcp_or_web_search` →
   `disable_on_external_context`).

The path is overridable for tests via `ConfigLoader.systemConfigPath`,
defaulting to `defaultSystemConfigPath = "/etc/codex/config.toml"`.

### user (toml)

`$CODEX_HOME/config.toml`. Loaded by `loadTOMLRoot()`. One important
behaviour: a legacy `$CODEX_HOME/config.json` is **migrated** into the
TOML root on first load (one-shot, non-destructive — `config.json` is
left on disk so older builds keep working until they're retired). The
TOML side wins on conflict.

Inside the user layer, a named profile (legacy v1) is overlaid via
`[profiles.<name>]`. The profile selection is resolved in this priority
order:

1. CLI override (`overrides["profile"]`).
2. Env: `CODEX_PROFILE` (the natural alias) or `CODEX_CFG_PROFILE` (the
   codex-swift legacy form).
3. The top-level `profile` key in `config.toml`.

The selected `[profiles.<name>]` table is merged on top of the user
config via `mergeOverlay(_:_:path:)`, and the bare `profiles` key is
stripped from the merged tree.

### profile-v2

Profile-v2 is a separate file per profile: `$CODEX_HOME/<name>.config.toml`
(suffix `ConfigLoader.profileV2Suffix = ".config.toml"`). When selected,
its contents become an independent layer between the user TOML and the
project-local layer.

Profile-v2 selection:

1. CLI override (`overrides["profileV2"]`).
2. Env: `CODEX_PROFILE_V2`.

Profile-v2 is purely additive — selecting a v2 profile does not disable
the v1 inline profile mechanism. Both can be in play; their layer order
is fixed (v2 is higher precedence).

When the resolved profile-v2 file exists and is non-empty,
`resolvedProfile` is set to the v2 name (it shadows any v1 name picked
above).

### project-local

`.codex/config.toml` files in the directory tree from cwd up to the
first repo-root marker. Loaded by `loadProjectLocalLayers(...)`:

1. Walk from cwd up to the first ancestor directory that contains *any*
   of the configured `project_root_markers` (default: `[".git"]`).
2. For each ancestor (from repo-root *down* to cwd), read
   `<dir>/.codex/config.toml`. Lowest-precedence first; cwd wins.
3. Apply the same denylist as the system layer (project-local configs
   live in a repository so they should not get to redirect credentials
   or rewire model providers).

Special case: when the discovered `.codex` folder *is* `$CODEX_HOME`
itself (the user runs codex from inside their codex home), the loader
skips it to avoid double-loading the user config.

When `cwdOverride` is `nil` the project-local layer is skipped
entirely. This matches upstream's `load_config_layers_state(.., cwd:
None, ..)` for thread-agnostic loads (e.g. the app server `/config`
endpoint). The supervisor passes the process cwd; per-session cwds are
handled inside the worker.

### env (`CODEX_CFG_*`)

`envLayer(_:)` scans the process environment for keys prefixed
`CODEX_CFG_`. The key is lowercased, double-underscores are decoded as
dot separators (`CODEX_CFG_HISTORY__PERSISTENCE` → `history.persistence`),
and the first path component runs through the same `keyAliases` map.

The value type is inferred (int → bool → string fall-through):

```swift
let leaf: ConfigValue = Int64(v).map(ConfigValue.int)
    ?? (["true", "false"].contains(v.lowercased())
        ? .bool(v.lowercased() == "true") : .string(v))
```

Nested branches are constructed bottom-up via the local `nest(_:)`
closure so multiple env vars under the same prefix merge.

### override (runtime)

The highest-precedence layer. Passed directly to
`ConfigLoader.load(env:overrides:)` by callers:

- The CLI's `--config key=value` arguments.
- The supervisor's per-request `config/value/write` and
  `config/batchWrite` RPC handlers.

The synthetic `profileV2` override key is stripped from the runtime
override surface before becoming a layer — it controls the loader, not
a config key the harness should see leak through.

## All defaults

Every key emitted by `Config.defaults()`:

| Key                                 | Type      | Default                          | Meaning                                                              |
|-------------------------------------|-----------|----------------------------------|----------------------------------------------------------------------|
| `model`                             | string    | `"gpt-5.1-codex"`                | Model identifier; passed to `ModelProviderRegistry.resolve`          |
| `approval_policy`                   | string    | `"on-request"`                   | One of `"never"` / `"untrusted"` / `"on-failure"` / `"on-request"` / `"granular"` (see SANDBOX.md) |
| `sandbox_mode`                      | string    | `"workspace-write"`              | One of `"read-only"` / `"workspace-write"` / `"danger-full-access"`  |
| `features`                          | object    | `{}`                             | Feature-flag map; overridable per-flag via `CODEX_FEATURE_<NAME>`    |
| `allow_login_shell`                 | bool      | `true`                           | Allow PTY tools to launch interactive login shells                   |
| `history`                           | object    | `{"persistence": "save-all"}`    | `history.persistence` ∈ `"save-all"` / `"none"`; optional `max_bytes` |
| `project_doc_max_bytes`             | int       | `32768`                          | Cap for `AGENTS.md` / project doc inclusion in prompt                |
| `project_doc_fallback_filenames`    | array     | `[]`                             | Alternative filenames to look for if the primary doc is absent       |
| `hide_agent_reasoning`              | bool      | `false`                          | Suppress reasoning items in the client-visible stream                |
| (not in defaults) `project_root_markers` | array | implicit `[".git"]`             | See below                                                            |
| (not in defaults) `model_provider`  | string    | implicit (registry default)      | Provider id for the active model                                     |
| (not in defaults) `model_providers` | object    | implicit (built-in registry)     | Per-provider config (base URL, wire_api, headers, …)                 |

The `Config` value type exposes typed accessors for the common keys:
`config.model`, `config.approvalPolicy`, `config.sandboxMode`,
`config.allowLoginShell`, `config.hideAgentReasoning`,
`config.projectDocMaxBytes`, `config.projectDocFallbackFilenames`,
`config.projectRootMarkers`, `config.historyPersistence`,
`config.historyMaxBytes`.

## Snake_case canonical form

Upstream Rust codex emits TOML with `#[serde(rename_all = "snake_case")]`
on most config structs. The Swift loader matches that wire shape:
defaults are emitted in snake_case, the project-local denylist is keyed
in snake_case, and a one-shot rewriter folds legacy camelCase keys onto
the snake_case form.

### `keyAliases`

```swift
static let keyAliases: [String: String] = [
    "approvalpolicy": "approval_policy",
    "approval_policy": "approval_policy",
    "sandboxmode": "sandbox_mode",
    "sandbox_mode": "sandbox_mode",
    "model": "model",
    "features": "features",
]
```

`keyAliases` is the env-derived key alias map. The env-derived key is
lowercased (the env var `CODEX_CFG_APPROVALPOLICY` → key
`"approvalpolicy"`), then mapped through `keyAliases`. So
`CODEX_CFG_APPROVAL_POLICY` and `CODEX_CFG_APPROVALPOLICY` both land at
`approval_policy`.

### `normalizeTopLevelAliases`

For file-derived layers (system, user, project-local, profile-v2):

```swift
static func normalizeTopLevelAliases(_ root: inout [String: ConfigValue]) {
    let camelToSnake: [String: String] = [
        "approvalPolicy": "approval_policy",
        "sandboxMode": "sandbox_mode",
    ]
    for (camel, snake) in camelToSnake {
        if let v = root[camel], root[snake] == nil {
            root[snake] = v
            root[camel] = nil
        }
    }
}
```

Without this, a user (or older `config.toml`) that wrote camelCase would
not shadow the snake_case defaults — they would *coexist*, and the
typed accessor `config.approvalPolicy` would silently return the default
because its lookup key (`approval_policy`) was empty.

### `normalizedWithAliases` (per-path)

`ConfigLoader.normalizeKeyAliases(path:_:)` and
`normalizedWithAliases(_:path:)` apply per-table-path legacy rewrites.
The only path currently rewritten is `[memories]`:

```swift
if path == ["memories"] {
    if table["disable_on_external_context"] == nil,
       let legacy = table["no_memories_if_mcp_or_web_search"] {
        table["disable_on_external_context"] = legacy
    }
    table["no_memories_if_mcp_or_web_search"] = nil
}
```

The map is the same on both sides of every merge: when overlay is
applied on base, both base and overlay get normalised first, then merged.

## `project_root_markers`

`project_root_markers` is the list of marker files/directories that
**bound the project-local discovery walk**. The walker stops at the
first ancestor containing any of the listed names. Default:

```swift
public static let defaultProjectRootMarkers: [String] = [".git"]
```

The key is configurable: setting `project_root_markers = ["Cargo.toml"]`
in your `config.toml` makes the walker stop at the Cargo workspace root
instead of the git root. Other useful values: `["package.json"]`,
`["go.mod"]`, `[".project"]`, or a multi-element list to support any of
several layouts.

An *empty* `project_root_markers = []` disables the walk entirely
(matches upstream's `find_project_root` returning `None` for an empty
marker slice). The walker still includes the cwd itself but climbs no
further.

The markers are resolved by merging everything *below* the project-local
layer (defaults + system + user + profile-v2 + env + overrides) and
reading the `project_root_markers` key from that intermediate tree.
Project-local layers, by construction, are loaded after the markers are
resolved, so they cannot influence which markers bound their own
discovery (matches upstream).

## Profile-v2

A profile-v2 is a free-standing `$CODEX_HOME/<name>.config.toml` file
that becomes a dedicated layer when selected. Two ways to select:

```bash
# env
export CODEX_PROFILE_V2=research
codex thread/start ...

# CLI override
codex --config profileV2=research thread/start ...
```

When the v2 file exists, it stacks between the user-config layer and the
project-local layers:

```
... < user (toml + v1 inline overlay) < profile-v2 < project-local < env < overrides
```

Profile-v2's main advantage over v1's `[profiles.<name>]` overlay is
hygiene: a v2 profile is a complete config-shape file, can be checked
into a separate dotfile repo, and does not commingle with the main
`config.toml`. The synthetic `profileV2` override key is stripped before
becoming a runtime override.

When both v1 and v2 are selected, `resolvedProfile` ends up holding the
v2 name. The v1 inline overlay still applies (it's part of the user-toml
layer), but the reported active profile is the v2 one.

## `wire_api`

Each entry under `model_providers.<id>` has a `wire_api` field. The
only supported value is `"responses"`:

```toml
[model_providers.openai]
base_url = "https://api.openai.com/v1"
wire_api = "responses"
```

`wire_api = "chat"` is **rejected at startup**. Upstream removed Chat
Completions support some time ago, and codex-swift mirrors that
rejection. From `Sources/ModelClient/ModelProvider.swift`:

```swift
public enum ModelProviderConfigError: Error, LocalizedError {
    /// `wire_api = "chat"` is no longer supported (Responses-only).
    case chatWireApiUnsupported(providerId: String)
    /// `wire_api` was set to a value other than `responses` or `chat`.
    case unknownWireApi(providerId: String, value: String)

    public var errorDescription: String? {
        switch self {
        case .chatWireApiUnsupported(let id):
            return "[\(id)] `wire_api = \"chat\"` is no longer supported.\n"
                 + "How to fix: set `wire_api = \"responses\"` in your "
                 + "provider config."
        case .unknownWireApi(let id, let value):
            return "[\(id)] unknown `wire_api = \"\(value)\"`; "
                 + "expected \"responses\"."
        }
    }
}
```

### P9.2 fix: codexd exits 78 with stderr message

`codexd` validates the model-providers configuration at process startup
(`Sources/codexd/main.swift`):

```swift
do {
    let object = appConfig.configObjectJSON()
    _ = try ModelProviderRegistry.load(
        from: object.mapValues(configValueToLite(_:)))
} catch let error as ModelProviderConfigError {
    FileHandle.standardError.write(
        Data("codexd: invalid config: \(error.localizedDescription)\n".utf8))
    exit(78)  // EX_CONFIG
} catch {
    FileHandle.standardError.write(
        Data("codexd: invalid config: \(error)\n".utf8))
    exit(78)
}
```

`78` is `EX_CONFIG` from `<sysexits.h>` — the canonical "configuration
error" exit code. Previously only the throwing entry point caught the
error and codexd would surface it later as an opaque routing failure;
the fix is to fail loud at process start.

### `currentProviderRequiresOpenAIAuth` (P9.2 follow-up)

`Sources/Supervisor/RequestRouter.swift::currentProviderRequiresOpenAIAuth()`
also uses the throwing entry point with a **safe default**:

```swift
private func currentProviderRequiresOpenAIAuth() -> Bool {
    let config = ConfigLoader(codexHome: codexHome).load()
    let object = config.configObjectJSON()
    let providerId = object["model_provider"]?.stringValue
        ?? object["modelProvider"]?.stringValue
        ?? object["model_provider_id"]?.stringValue
    do {
        let registry = try ModelProviderRegistry.load(
            from: object.mapValues(Self.configValueLite(_:)))
        return registry.resolve(providerId).requiresOpenAIAuth
    } catch {
        FileHandle.standardError.write(Data(
            ("codex-supervisor: invalid model_providers config "
             + "(\(error)); defaulting requiresOpenAIAuth=true\n").utf8))
        return true
    }
}
```

If validation fails the supervisor logs to stderr and falls back to
`requiresOpenAIAuth = true`. That is the safer default: the client will
be told it needs auth rather than silently being granted "no auth
required" because of bad config.

## MCP servers config

External MCP servers are configured under the `mcp_servers` table:

```toml
[mcp_servers.fs]
command = "/usr/local/bin/mcp-fs"
args = ["--cwd", "${WORKSPACE}"]
env = { LOG_LEVEL = "info" }

[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }
```

The MCP client (`Sources/MCP/McpClient.swift`) launches each server in
its own process group via `setpgid(pid, pid)` (see SANDBOX.md) so a
single SIGTERM can take down the server plus any grandchildren it
spawned. For the full MCP wire surface and tool routing see `MCP.md`.

## Hooks config

Hooks (pre-tool, post-tool, post-session callbacks) are configured under
the `hooks` table. The harness executes them at the right lifecycle
event; they are *not* run by the model. See `HOOKS.md` for the full
configuration shape and the execution semantics.

## Env overrides

Two parallel env-var conventions:

### `CODEX_CFG_*` — direct config overrides

Any config key can be set via `CODEX_CFG_<UPPER_KEY>`. Nested keys use
double-underscore as separator:

```bash
# Set `model = "o3-mini"`
export CODEX_CFG_MODEL=o3-mini

# Set `history.persistence = "none"`
export CODEX_CFG_HISTORY__PERSISTENCE=none

# Set `hide_agent_reasoning = true`
export CODEX_CFG_HIDE_AGENT_REASONING=true
```

The env layer sits *above* project-local config but *below* the runtime
overrides, so a CLI `--config` can still override a `CODEX_CFG_*` value.

### `CODEX_FEATURE_*` — feature flags

Feature flags are gated independently via `CODEX_FEATURE_<NAME>`:

```bash
export CODEX_FEATURE_MULTI_AGENT_V2=1
```

The flag check is in `Config.isFeatureEnabled(_:env:)`. It tries the env
var first (truthy values: `1`, `true`, `yes`, `on`), then falls back to
the `features.<name>` key in the merged config tree. Dashes and dots in
the flag name are translated to underscores for the env-var spelling.

### Other `CODEXKIT_*` vars

A handful of `CODEXKIT_*` env vars control codex-swift-specific behaviour
outside the config layer:

| Env var                          | Purpose                                                            |
|----------------------------------|--------------------------------------------------------------------|
| `CODEXKIT_MOCK`                  | Use the mock model backend (`=1`)                                  |
| `CODEXKIT_MOCK_TEXT`             | Mock response text                                                 |
| `CODEXKIT_MOCK_SCENARIO`         | Pre-canned scenario (`tool-loop-compact`, …)                      |
| `CODEXKIT_MOCK_SLOW_MS`          | Insert latency in the mock backend                                 |
| `CODEXKIT_MEMORY`                | Spawn the `codex-memory` daemon at codexd startup (`=1`)           |
| `CODEXKIT_MLX`                   | Build flag for the MLX-Swift inference provider                    |
| `CODEXKIT_RESPONSES_WEBSOCKET`   | Use the WebSocket responses transport (`=1`)                       |
| `CODEXKIT_WS_PREWARM`            | Disable WebSocket prewarm (`=0`)                                   |
| `CODEXKIT_AUTH_BROKER`           | Auth broker socket path / mode                                     |
| `CODEXKIT_AUTH_STORE`            | Auth store backend (e.g. `file`)                                   |
| `CODEXKIT_IPC_FD`                | IPC file-descriptor handoff (supervisor → session)                 |
| `CODEXKIT_PERPLEXITY_MODEL`      | Perplexity model name for `web_search`                             |
| `CODEXKIT_WEBSEARCH_MODEL`       | OpenAI web-search model name                                       |
| `CODEXKIT_OPENAI_WEBSEARCH_TYPE` | OpenAI web-search tool type                                        |
| `CODEXKIT_OTLP_ENDPOINT`         | OpenTelemetry exporter endpoint                                    |
| `CODEXKIT_LISTEN`                | codexd listen socket path                                          |

These are *not* config keys (they don't show up in `config/read`) — they
control process startup or feature plumbing that exists outside the
configuration model.

## Config write RPCs

Clients can programmatically update `config.toml` over the app server:

### `config/value/write`

Single-key write. Params:

```json
{
  "keyPath": "approval_policy",
  "value": "never",
  "mergeStrategy": "replace"
}
```

`keyPath` is a dotted path (`history.persistence`). `value` is any JSON
value. `mergeStrategy` is `"replace"` (the new value replaces the old) or
`"merge"` (deep-merge — only valid for object values). The supervisor's
request router validates the shape:

```swift
guard method == "config/value/write" || method == "config/batchWrite"
else { ... }
if method == "config/value/write" {
    // require keyPath, value, mergeStrategy
    await conn.send(WireError.invalidRequest(
        id: id, "config/value/write requires keyPath, value, and mergeStrategy"))
}
```

### `config/batchWrite`

Batched form. Params:

```json
{
  "edits": [
    {"keyPath": "model", "value": "o3-mini", "mergeStrategy": "replace"},
    {"keyPath": "approval_policy", "value": "never", "mergeStrategy": "replace"},
    {"keyPath": "history", "value": {"persistence": "none"}, "mergeStrategy": "merge"}
  ]
}
```

All edits land in a single write via `ConfigLoader.persistTOML(_:)` so a
client can't observe a half-applied batch.

### Persistence path

Both RPCs ultimately serialise the new tree to deterministic TOML at
`$CODEX_HOME/config.toml`:

```swift
public func persistTOML(_ root: [String: ConfigValue]) throws {
    try? FileManager.default.createDirectory(
        atPath: codexHome, withIntermediateDirectories: true)
    let s = TOML.serialize(root)
    try Data(s.utf8).write(to: URL(fileURLWithPath: tomlPath), options: .atomic)
}
```

The serialiser is in `Sources/Config/TOML.swift`; it is deterministic
(sorted keys at every level) so two writes of the same logical tree
produce byte-identical files on disk. This makes the user's `config.toml`
diffable in git, and makes the `config/batchWrite` round-trip
idempotent for tests.

The legacy `config.json` is never written by the loader — every write
path goes through `persistTOML`. The legacy JSON file is read once on
load (one-shot migration into TOML) and otherwise ignored.
