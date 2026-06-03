# Using MCP Servers

*Plug external tools and resources into your agent by pointing it at any Model Context Protocol server — local subprocess or remote HTTPS endpoint — and they show up as callable tools.*

## Why it matters

Your agent is only as capable as the tools it can reach. Out of the box it can read files, run shell commands, and search the web — but the moment you need it to query *your* Postgres, open issues in *your* GitHub org, or hit an internal API that already speaks a documented protocol, you'd otherwise have to fork the agent and write a bespoke tool in Swift.

MCP solves exactly that. Imagine you want the agent to triage open issues in a repo: you don't want to teach it the GitHub REST API by hand, you just want it to *have* a `list_issues` tool. Point codex-swift at GitHub's MCP endpoint, restart, and the model now sees `mcp__github__list_issues` in its tool list — no code, no rebuild. The same mechanism plugs in databases, browser automation, search backends, or any of the growing ecosystem of community MCP servers.

## What it is

MCP (Model Context Protocol) is a small open standard for exposing **tools** and **resources** to an LLM over JSON-RPC. codex-swift is an MCP **client**: you declare servers in config, and at startup it connects to each one, discovers the tools it offers, and registers them so the model can call them like any built-in tool.

What you get as a user:

- **Tools** — server-provided functions the model can invoke (e.g. `search_code`, `run_query`). They appear namespaced as `mcp__<server>__<tool>`.
- **Resources** — server-provided documents/blobs the host can read by URI (`resources/read`).
- **Two transports** — *stdio* (codex-swift spawns the server as a subprocess) and *streamable HTTP* (codex-swift POSTs to a remote URL, optionally over an SSE stream).
- **Per-server controls** — allow/deny specific tools, set timeouts, mark a server `required`, supply auth via a bearer-token env var or an interactive OAuth login.

It is a client only: codex-swift does not host or publish MCP servers, it consumes them.

## How it works

At session startup, `codexd` loads your MCP configs and hands them to the `McpManager`, which drives the whole lifecycle. For every configured server it:

```
config.toml  ──►  McpManager.startAll
                      │
       ┌──────────────┴───────────────┐
   stdio server                  HTTP server
  (McpClient)                  (McpHttpClient)
   spawn process                curl -i POST
   NDJSON over pipes            JSON or SSE body
       │                              │
       └────────► initialize ─────────┘   (JSON-RPC handshake)
                      │
                  tools/list           (discover what the server offers)
                      │
            enabled_tools / disabled_tools filter
                      │
            register mcp__<server>__<tool>  on the ToolRouter
                      │
              status = "ready"
```

Key concepts to keep in your mental model:

- **Transport is auto-detected.** A server entry with a `url` is treated as HTTP (`isHTTP`); otherwise it's a stdio command. You never set a "type" field.
- **Tool naming.** Each discovered tool becomes `mcp__<server>__<tool>`, sanitized to `[A-Za-z0-9_]` and fitted to a 64-character cap (collisions are de-duplicated). That namespacing is why the model can tell two servers' `search` tools apart.
- **Serial execution.** MCP tool calls are **not** marked parallel-safe — the proxy's `parallelSafe` is `false`, so an MCP call runs on the exclusive side of the per-turn tool gate and can't race other tools. (This matches upstream Codex, where the production client always reports `false`.)
- **Failure isolation.** If one server fails to initialize, it's marked `failed` and the rest still come up. A server marked `required = true` lets downstream session startup abort instead.
- **Server-initiated prompts (elicitation).** Mid-call, a server can ask the user a question (`elicitation/create`). A policy layer (`McpElicitationPolicy`) decides whether to auto-decline, auto-accept a bare confirmation, or surface the prompt to your client UI — driven by your approval policy. When no handler is wired, both transports safely reply `decline` instead of hanging.
- **Secret hygiene for stdio.** A spawned server does **not** inherit your full environment. codex-swift clears it and forwards only a small allowlist (`HOME`, `PATH`, `SHELL`, `USER`, `LANG`, `TERM`, `TMPDIR`, `TZ`, …) plus the env vars you explicitly name — so a misconfigured server can't read your `OPENAI_API_KEY` or OAuth tokens. The child is also placed in its own process group so shutdown reliably reaps grandchildren.

## Using it

MCP servers are declared in `$CODEX_HOME/config.toml` under `[mcp_servers.<name>]` (snake_case keys). `codexd` reads them at startup via `McpManager.loadConfigs`. (A legacy `$CODEX_HOME/mcp.json` is still read for back-compat, with TOML winning.)

### A local (stdio) server

```toml
[mcp_servers.my_local]
command = "/usr/local/bin/my-mcp-server"   # bare names are resolved via /usr/bin/env (PATH)
args = ["--workspace", "/tmp/work"]
env = { LOG_LEVEL = "info" }               # literal env overrides for the child
cwd = "/tmp/work"
env_vars = ["API_KEY"]                      # forward THESE parent-env vars through the allowlist

startup_timeout_sec = 60.0                   # default 30s
tool_timeout_sec    = 180.0                  # default 120s

enabled_tools  = ["query", "write"]          # allowlist (optional)
disabled_tools = ["dangerous_thing"]         # denylist, applied after the allowlist

required = true                              # session start may abort if this fails to init
```

`env_vars` entries can be a bare string (a variable name read from your local environment) or an inline table `{ name = "TOKEN", source = "remote" }`. `source = "remote"` means the value comes from a remote executor's secret store; those entries are silently dropped when running locally.

### A remote (streaming-HTTP) server

```toml
[mcp_servers.github]
url = "https://api.githubcopilot.com/mcp"
bearer_token_env_var = "GITHUB_TOKEN"        # auth via an env var
http_headers     = { "X-Custom" = "value" }  # verbatim headers
env_http_headers = { "X-User-Tenant" = "TENANT_ID_VAR" }  # header VALUE is an env-var NAME
tool_timeout_sec = 60.0
enabled_tools = ["list_issues", "search_code"]

# For OAuth servers instead of a static token:
scopes = ["read:tools", "execute:write"]
oauth  = { client_id = "Codex" }
oauth_resource = "https://api.githubcopilot.com/mcp"
```

Auth precedence on HTTP requests: `bearer_token_env_var` wins if the named env var is non-empty; otherwise a stored, non-expired OAuth token; otherwise the request is anonymous. `env_http_headers` resolves the named env var at request time and silently omits the header if it's unset/empty.

### Logging in with OAuth (PKCE + loopback)

For servers that don't take a static token, codex-swift does an interactive OAuth login. Your client triggers the codexd JSON-RPC method `mcpServer/oauth/login` with the server `name`. codex-swift then:

1. Discovers `/.well-known/oauth-authorization-server` to find the `authorization_endpoint` and `token_endpoint`.
2. Generates a PKCE verifier + S256 challenge and builds an authorization URL with `client_id=Codex`, `redirect_uri=http://127.0.0.1:1455/mcp/oauth/callback`, your `scopes`, and a random `state`.
3. Returns that URL (`authorizationUrl`) for the client to open in a browser.
4. Runs a **loopback** listener on `127.0.0.1:1455` to catch the redirect with the authorization code, then exchanges it at the token endpoint.
5. Saves tokens to `$CODEX_HOME/.mcp-oauth/<server>.json` (file `0600`, dir `0700`) and emits a `mcpServer/oauthLogin/completed` notification.

Subsequent HTTP requests pick the token up automatically — no restart needed.

### What the model sees

With the `github` config above, after startup the model's tool list contains:

```
mcp__github__list_issues   (description from the server)
mcp__github__search_code   (description from the server)
```

A model tool call like `mcp__github__list_issues` with `{"repo":"foo/bar","state":"open"}` is dispatched to the proxy, which sends a `tools/call` to the server and returns the joined text content back into the turn. Note: today only **text** content from a tool result reaches the model — `image` and `resource` content items are dropped at the proxy boundary.

### Related JSON-RPC controls (codexd)

- `config/mcpServer/reload` — re-run `startAll` from scratch (the recovery path; there is no auto-restart on crash).
- `mcpServer/oauth/login` — start the OAuth flow described above.
- `mcpServer/resource/read` — read a server resource by URI.

## What it enables

Once a server is connected, its tools are first-class citizens of the turn loop — the model plans with them, the [tool router](../MCP.md) dispatches them, and approval/sandbox policy applies. That means MCP composes with the rest of the agent: the same approval policy that gates shell commands governs whether elicitation prompts are surfaced or auto-declined, and the `_meta.threadId` (and sandbox-state, for capable servers) is threaded into every call so servers can correlate work to a conversation.

Practically, this is how you extend the agent without forking it: drop in a database server, a browser-automation server, your internal API, or any community MCP server, scope it down with `enabled_tools`, lock it behind OAuth or a bearer token, and the agent gains the capability for the rest of the session.

## Status

Honest caveats grounded in the current code:

- **Non-text tool output is dropped.** Only `text` content items from a `tools/call` result reach the model; `image` and `resource` items (and `_meta`) are not yet surfaced.
- **No auto-restart.** A crashed server stays `failed` for the session; recovery is the explicit `config/mcpServer/reload`.
- **Server capabilities aren't propagated into config.** Every server is assumed to support `tools/call` and `resources/read`; tools are discovered explicitly via `tools/list`.
- **OAuth login is HTTP-only.** stdio servers authenticate via `env` overrides only.

## Go deeper

For the transport internals (NDJSON framing, the SSE streaming reader, per-request timeouts, process-group shutdown, session-expiry recovery, the notification enum, and the test fixtures), see [docs/MCP.md](../MCP.md).
