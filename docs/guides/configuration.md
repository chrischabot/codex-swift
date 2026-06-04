# Configuration

*One layered config model — files, profiles, and env overrides — drives every model, approval, and sandbox decision codex-swift makes.*

## Why it matters

You want codex-swift to use a specific model in this repo, but your global default everywhere else. You want to A/B a single setting (`approval_policy = "never"`) for one run without editing — and reverting — a file. Your security team wants a machine-wide policy that a cloned repository's checked-in config can never weaken.

A single flat config file can't do all three. codex-swift solves it with a **layered** configuration system: small, focused overrides stack on top of broad defaults, the most specific layer wins, and every effective value remembers which layer set it. You change one key in one place and the rest stays put.

## What it is

Configuration is a deep-merged tree of settings assembled from several sources, plus **origin tracking** so you can always answer "where did this value come from?". It controls the things that matter day to day:

- **Which model** runs (`model`) and **which provider** serves it (`model_provider`, `model_providers`).
- **How autonomous** the agent is — the **approval policy** (`approval_policy`) and **sandbox mode** (`sandbox_mode`).
- **Opt-in features** (`[features]`), MCP servers (`[mcp_servers]`), hooks (`[hooks]`), history, and project-doc behavior.

The canonical file is `~/.codex/config.toml` (i.e. `$CODEX_HOME/config.toml`), written in **TOML** with **snake_case** keys (the upstream Rust codex wire format). Legacy camelCase (`approvalPolicy`, `sandboxMode`) is auto-folded onto the snake_case form, so older files keep working. A legacy `config.json` is migrated into TOML once on first load and otherwise ignored.

## How it works

Configuration is built by `ConfigLoader.load(env:overrides:)` (`Sources/Config/Config.swift`). It merges layers from **lowest to highest precedence** — later layers override earlier ones key by key:

```
  defaults
    └─ system ........... /etc/codex/config.toml      (admin, trusted)
        └─ managed ...... macOS MDM config_toml_base64 (enterprise)
            └─ user ..... $CODEX_HOME/config.toml      (+ inline [profiles.<name>])
                └─ profile-v2  $CODEX_HOME/<name>.config.toml (when selected)
                    └─ project-local  .codex/config.toml (repo-root → cwd)
                        └─ env ..... CODEX_CFG_* environment vars
                            └─ override  runtime / per-request RPC  (always wins)
```

A few mechanics worth understanding:

- **Origin tracking.** Each top-level key records which layer last set it. Inspecting config returns both the merged values and an `origins` map, so an unexpected setting is traceable to its source.
- **Effective defaults are applied at resolution time, not baked into the file surface.** The built-in `defaults()` set things like `allow_login_shell = true`, `history.persistence = "save-all"`, and empty `features`/`mcp_servers`/`model_providers` tables — but it deliberately does **not** default `model`, `approval_policy`, or `sandbox_mode`. Those stay absent until you set them, and the runtime falls back to **`model = "gpt-5.5"`**, **`approval_policy = "on-request"`**, and **`sandbox_mode = "workspace-write"`** when nothing in any layer provides them (applied in `Sources/Supervisor/RequestRouter.swift`). This keeps inspected config faithful to what you actually wrote.
- **Project-local is sandboxed by a denylist.** A repository's `.codex/config.toml` is treated as untrusted content: it cannot set `model_provider`, `model_providers`, `notify`, `profile`, `profiles`, base URLs, or telemetry endpoints. Those keys are stripped and surfaced as a `configWarning`. The same keys **are** honored from your user, system, and managed layers. (See [SANDBOX.md](../SANDBOX.md).)
- **Project discovery walks up to a marker.** The project-local layer is read from every `.codex/config.toml` between the repo root and your cwd. The walk stops at the first ancestor containing a `project_root_markers` entry (default `[".git"]`); set it to `["Cargo.toml"]`, `["package.json"]`, etc. to relocate the boundary, or `[]` to disable the walk.

## Using it

### `$CODEX_HOME`

Everything keys off `$CODEX_HOME`. It resolves to the `CODEX_HOME` environment variable if set, otherwise `~/.codex`. That directory holds `config.toml`, any profile-v2 files (`<name>.config.toml`), and auth/history state.

### A starter `config.toml`

```toml
model          = "gpt-5.5"
model_provider = "openai"
approval_policy = "on-request"      # never | untrusted | on-failure | on-request | granular
sandbox_mode    = "workspace-write" # read-only | workspace-write | danger-full-access

project_root_markers = [".git"]

[history]
persistence = "save-all"            # save-all | none

[features]
some_feature = true                 # opt-in flags live here

[model_providers.openai]
base_url = "https://api.openai.com/v1"
wire_api = "responses"              # only "responses" is supported; "chat" is rejected

[mcp_servers.github]
command = "npx"
args = ["-y", "@modelcontextprotocol/server-github"]
env = { GITHUB_TOKEN = "${GITHUB_TOKEN}" }
```

Note: `wire_api = "chat"` is rejected at startup — `codexd` exits with code **78** (`EX_CONFIG`) and prints the offending provider to stderr. Set `wire_api = "responses"`.

### Profiles

Two kinds of profile let you keep alternate setups without rewriting your base config:

- **Inline (v1):** a `[profiles.<name>]` table inside `config.toml`, overlaid on top of the user layer when selected.
- **Standalone (v2):** a separate `$CODEX_HOME/<name>.config.toml` file that becomes its own layer above the user config. Cleaner for dotfile repos.

Selection (highest priority first): a runtime override (`profile` / `profileV2`), then env (`CODEX_PROFILE` or the legacy `CODEX_CFG_PROFILE` for v1; `CODEX_PROFILE_V2` for v2), then the inline `profile` key. `codexd` also accepts `--profile-v2 NAME` on its command line. Example:

```bash
export CODEX_PROFILE_V2=research   # selects $CODEX_HOME/research.config.toml
```

### Env overrides — `CODEX_CFG_*`

Override any config key without touching a file. The key is `CODEX_CFG_<UPPER_KEY>`; nested keys use a double underscore (`__`) as the dot separator. This layer sits above project-local config but below runtime overrides.

```bash
export CODEX_CFG_MODEL=o3-mini                 # model = "o3-mini"
export CODEX_CFG_HISTORY__PERSISTENCE=none     # history.persistence = "none"
export CODEX_CFG_HIDE_AGENT_REASONING=true     # hide_agent_reasoning = true
```

Values are type-inferred: integers parse as int, `true`/`false` as bool, everything else as string.

### Feature flags — `[features]` and `CODEX_FEATURE_*`

A feature is enabled if its `CODEX_FEATURE_<NAME>` env var is truthy (`1`, `true`, `yes`, or `on`); otherwise the loader falls back to the boolean `features.<name>` in the merged config. In the env-var spelling, dashes and dots become underscores and the name is uppercased:

```bash
# enables the feature checked as isFeatureEnabled("multi-agent-v2")
export CODEX_FEATURE_MULTI_AGENT_V2=1
```

The env var always wins over the file, so you can flip a single feature for one run.

### Addon configuration

The addon portfolio (channels, Google Workspace, cron, push, media) is **deny-default**: each capability is off until you both flip its `[features]` flag *and* supply its config. An unconfigured daemon is byte-identical to one without the addon. Secrets are always read from an environment variable **named** in config — never the secret value in the TOML, so nothing sensitive lands on disk.

```toml
[features]
push   = true       # outbound/push delivery (ntfy + webhook)         → docs/features/push.md
media  = true       # media_generate tool + daemon poller             → docs/features/media.md
cron   = true       # cron/* RPC + scheduler (single source of truth)  → docs/features/cron.md
google = true       # google_api Workspace tool                        → docs/features/connectors.md

[cron]
grace_seconds = 3600                       # catch-up window for a missed fire

[media]
provider   = "stub"                        # async providers need CODEXKIT_IN_PROCESS_WORKERS=1
media_root = "$CODEX_HOME/media"
# api_key_env = "OPENAI_API_KEY"           # required for a non-stub provider

[connectors.google]
client_id         = "<id>.apps.googleusercontent.com"
client_secret_env = "GOOGLE_OAUTH_CLIENT_SECRET"   # env var NAME, not the secret
scopes            = ["https://www.googleapis.com/auth/gmail.readonly"]
token_store_path  = "$CODEX_HOME/connectors/google/tokens.json"

[channels.telegram]
enabled              = true
bot_token_env        = "TELEGRAM_BOT_TOKEN"        # env var NAME, not the token
owners               = ["123456789"]               # numeric ids; EMPTY ⇒ every sender is non-owner
poll_timeout_seconds = 30
```

`$CODEX_HOME` is expanded in the addon path keys (`media_root`, `token_store_path`). One-time Google auth is a subcommand, not a config key: `codexd google-connect` / `codexd google-disconnect`. Cron jobs persist to `$CODEX_HOME/cron_jobs.json` (migrated once from `automations.json` when cron is first enabled).

### A note on `CODEXKIT_*`

A separate family of `CODEXKIT_*` env vars (e.g. `CODEXKIT_MOCK`, `CODEXKIT_LISTEN`, `CODEXKIT_OTLP_ENDPOINT`) controls process startup and codex-swift-specific plumbing. These are **not** config keys — they don't appear in inspected config and don't participate in the layer stack.

### Inspecting the effective config

There is no standalone `codex config` subcommand in this port; configuration is read and written over the supervisor's RPC surface (served by `codexd`):

- **`config/read`** returns the merged `config`, the `origins` map (which layer set each key), and — when called with `includeLayers: true` — the full ordered layer stack, highest precedence first, each with a content `version` hash. Pass `cwd` to resolve the project-local layers as seen from a specific directory.
- **`config/value/write`** writes a single dotted `keyPath` with a `mergeStrategy` of `"replace"` or `"merge"`.
- **`config/batchWrite`** applies many edits atomically.

All writes serialize back to `$CODEX_HOME/config.toml` via `persistTOML`, which sorts keys deterministically — so the file stays diffable in git and round-trips are byte-stable. The legacy `config.json` is never written.

## What it enables

Configuration is the dial behind nearly every other capability:

- **Autonomy and safety.** `approval_policy` + `sandbox_mode` jointly decide what runs without asking — the policy surface detailed in [SANDBOX.md](../SANDBOX.md).
- **Model and provider routing.** `model` / `model_provider` / `model_providers` feed the model client; see [MODEL_CLIENT.md](../MODEL_CLIENT.md).
- **Extensibility.** `[mcp_servers]` wires in external tools ([MCP.md](MCP.md)), `[hooks]` attaches lifecycle callbacks ([HOOKS.md](../HOOKS.md)), and `[features]` gates opt-in behavior.

Because the layering is uniform, the same keys behave consistently whether they come from a file, an env var, a profile, or a live RPC write — and origin tracking means you can always explain why codex-swift did what it did.

## Go deeper

For the internals — exact merge order, alias normalization, the per-path rewriters, profile-v2 shadowing, and the write-RPC contract — see [docs/CONFIG.md](../CONFIG.md).
