# Web Gateway & UI

*Open the agent in a browser: `codexd` serves the chat UI and bridges each tab to the daemon over a single same-origin, TLS-secured WebSocket.*

## Why it matters

The agent's daemon, `codexd`, normally talks to local clients over stdio or a Unix socket — great for a terminal, useless when you want to watch a long-running task from the couch, hand a thread to a teammate's laptop, or paste a screenshot into the conversation. You'd otherwise be stuck SSH-tunneling a JSON-RPC socket and writing your own client.

Imagine you've kicked off a multi-hour refactor. You want to glance at the streaming output from your phone on the same Wi-Fi, scroll the diff rail, drop in a reference image, and steer the turn — without installing anything. The Web Gateway makes that a single command: start `codexd` with one flag, open `https://127.0.0.1:8443`, and you get the full chat UI talking to the *same* live session pool your terminal sees.

Crucially, the agent control plane is arbitrary local code execution (it can exec, spawn, write files, apply patches). Exposing that to a browser naively is a remote-code-execution hole. The gateway exists so there's *one* hardened, auditable front door instead of an ad-hoc proxy everyone reinvents insecurely.

## What it is

The Web Gateway is a small web server built directly into `codexd`. It does four things for you:

- **Serves the chat UI** — the compiled React/shadcn single-page app (`www/dist`) over HTTPS.
- **Bridges the browser to the daemon** — a WebSocket at `/ws` carries the app-server JSON-RPC protocol straight into the running session pool. Each browser tab gets its own session view; tabs and your terminal client all see the same threads.
- **Handles media** — agent-produced and uploaded files are served back through short-lived, signed URLs that support video/audio seeking.
- **Accepts uploads** — drag an image into the chat and it's staged server-side and attached to your next turn.

It is a single binary. Vite/npm exist only to *build* the UI bundle; the running system has no Node, no separate web process, no external RPC hop. The default bind is loopback-only because of the RCE concern above — exposing it on a real interface is a deliberate, auth-gated opt-in.

## How it works

The gateway is a [Hummingbird](https://github.com/hummingbird-project/hummingbird) HTTP server fronted by one TLS 1.3 listener. Everything is **same-origin on one port** — the UI, its WebSocket, media, and uploads all live behind the same `https://host:port`. That's required by modern Chrome's Local Network Access rules, and because Hummingbird 2.x can't serve WebSocket upgrades on an HTTP/2 listener, the listener is HTTP/1.1 + WebSocket upgrade.

```
browser ──TLS 1.3──▶ codexd : WebGateway (Hummingbird, one port)
                     ├─ GET /                → www/dist/index.html (SPA shell)
                     ├─ GET /assets/*        → hashed JS/CSS/wasm (immutable 1y)
                     ├─ GET /healthz,/readyz → "ok"
                     ├─ GET /media/:token    → signed file, Range/206
                     ├─ POST /api/upload     → multipart, bearer-gated
                     └─ WS  /ws              → per-tab RequestRouter
                                                 └─ shared SessionSupervisor ──▶ workers
```

Key concepts:

- **Per-tab router over a shared supervisor.** Each WebSocket connection mints a *fresh* `RequestRouter` (via an injected `routerFactory`) but they all sit on the one `SessionSupervisor` the daemon already runs. So a browser tab and your terminal share the session pool, while each tab keeps its own `initialized`/capabilities/subscription state — no cross-client collision.

- **The duplex bridge.** A `WebSocketClientConnection` presents the socket to the router as an ordinary client connection. Inbound text frames are decoded to JSON-RPC and fed to the router; the router's outbound messages are buffered onto a stream and written back as frames. Four cooperating tasks run per session: read, dispatch, write, and an idle watchdog. Disconnect cleanly fires `connectionClosed`.

- **Layered security** (see `Security.swift`). On a non-loopback bind, auth is mandatory and fail-closed:
  - **Bearer token** — browsers can't set `Authorization` on a WebSocket, so the token rides the `bearer.<token>` WebSocket subprotocol; HTTP routes use `Authorization: Bearer <token>`. Compared in constant time.
  - **Origin allowlist** — rejects cross-origin handshakes; the parser refuses `user:pass@host` userinfo to block a loopback-spoof WS hijack.
  - **Host check** — defeats DNS rebinding (Origin can match an allowed domain that's been rebound to your IP; the Host header wouldn't).
  - **Deny-default method gate** (`MethodGate`) — only an *explicit allowlist* of ~60 JSON-RPC methods the UI actually needs is reachable. Privileged control-plane RPCs (direct exec, process spawn, fs writes, account login, remote-control enable, config writes) are blocked before dispatch. This is a name allowlist, **not** derived from `parallelSafe`/`isReadOnly` (which are not authorization boundaries).
  - **Response headers** — CSP scoped to what the bundle needs (`wasm-unsafe-eval` for shiki/mermaid, `connect-src 'self'`), `frame-ancestors 'none'`, `X-Content-Type-Options`, `Referrer-Policy`, COOP/CORP, and HSTS over TLS.
  - **Resource caps** — 1 MiB max WebSocket frame, 300 s idle timeout (slowloris defense), 256 concurrent connections.

- **Signed media tokens** (`MediaToken.swift`). A `/media/:token` URL is a stateless capability: the file path *relative to the media root* plus an expiry is HMAC-SHA256-signed. By default the key is **per-launch random** (links die on restart); set `CODEXKIT_WEB_PERSIST_MEDIA_SIGNER=1` to persist it to a `0600` `media-signer.key` (written atomically via temp-file + `link()`, so the published key never appears partially written — concurrent first-callers all converge on one key) so signed URLs **survive a restart** (#4). The signer is also published to a process-global holder so the codexd media-delivery closure mints URLs under the *same* key the route verifies; for a wildcard/proxy bind, `CODEXKIT_WEB_PUBLIC_BASE_URL` supplies the reachable origin (without it, a wildcard bind disables minting and delivery falls back to the local path rather than emitting a dead `0.0.0.0` link). Verification is purely cryptographic — no session lookup — so a plain `<img>` or `<video>` tag just works. `..` is rejected on both sign and verify, and the route re-resolves the path under the media root. `Range`/206 is supported so audio/video can seek.

- **Uploads** (`Upload.swift`). `POST /api/upload` takes a `multipart/form-data` body (parsed at the byte level, never round-tripping binary through a String), enforces a per-request size cap and a per-thread quota, **sniffs the MIME from magic bytes** (never trusts the client header), stages the blob under a server-generated UUID filename (defeats path traversal), and returns a signed `/media` URL plus the staged path. Images become a `localImage` turn-input part; other files become a structured mention.

- **TLS, zero-setup** (`DevCert.swift`). If no cert/key exist, the gateway generates a self-signed leaf via `openssl` with a SAN covering `localhost`/loopback (Chrome requires a SAN and ignores CN). The private key is created `0600` and re-verified fail-closed. For a browser-trusted local cert with no warning, point `CODEXKIT_WEB_CERT`/`KEY` at an `mkcert` leaf.

## Using it

First build the UI bundle once (build-time only):

```sh
(cd www && npm run build)     # tsc -b && vite build → www/dist
```

Then run the daemon with the web gateway. The simplest loopback dev setup — mock model, no API key, web-only:

```sh
CODEXKIT_MOCK=1 CODEXKIT_WEB_ROOT="$PWD/www/dist" \
  .build/debug/codexd --listen off --listen-web 127.0.0.1:8443

open https://127.0.0.1:8443      # self-signed: trust once in the browser
```

The gateway runs *alongside* the app-server transport. Drop `--listen off` to share the supervisor with stdio/UDS clients simultaneously; `--listen off --listen-web …` runs web-only.

**Flags and environment variables** (parsed in `codexd/main.swift`):

| Flag / env | Default | Meaning |
|---|---|---|
| `--listen-web[=HOST:PORT]` / `CODEXKIT_LISTEN_WEB` | (off) | Enable the gateway; bind address. Default `127.0.0.1:8443` |
| `CODEXKIT_WEB_ROOT` | `$PWD/www/dist` | Static bundle directory |
| `CODEXKIT_WEB_CERT` / `CODEXKIT_WEB_KEY` | `$CODEX_HOME/web-gateway/{cert,key}.pem` | TLS leaf (auto-generated if missing) |
| `CODEXKIT_WEB_INSECURE=1` | unset | Serve plaintext HTTP/WS — **local dev/CI only** |
| `CODEXKIT_WEB_REQUIRE_AUTH=1` | off for loopback | Force bearer auth even on loopback |
| `CODEXKIT_WEB_TOKEN` | (generated) | Set the bearer token; auto-generated and printed to stderr when auth is required and unset |
| `CODEXKIT_WEB_ORIGINS` | (loopback only) | Comma-separated exact-match allowed `Origin` values |

Auth is **forced on automatically for any non-loopback bind** (fail-closed). When that happens with no `CODEXKIT_WEB_TOKEN`, `codexd` generates one and prints it to stderr:

```
codexd web gateway auth token: <random-token>
codexd web gateway https://0.0.0.0:8443 (auth=true)
```

The browser supplies that token to the UI's connector, which sends it as the `bearer.<token>` WebSocket subprotocol and as the `Authorization` header on uploads. The UI auto-derives its WebSocket URL from the page origin (`wss://<host>/ws`), so same-origin works with no config. Build with `VITE_CONNECTOR=mock` to use the in-memory simulator instead of the live daemon.

What you see: the full chat UI — thread list, streaming assistant output, the git diff rail, plan/turn steering, settings, plugins/MCP/skills panels, and image upload. Health probes are at `/healthz` and `/readyz`.

## What it enables

- **Remote and multi-device access** to a running agent over your LAN or through an edge proxy, without a bespoke client — every tab shares the live [session pool](./multi-process-architecture.md).
- **Rich media in the loop** — paste screenshots, view agent-produced images/video/PDFs inline via signed URLs that can't be guessed or replayed after expiry.
- **A safe place to expose the agent** — the deny-default method gate, signed media, origin/host checks, and CSP mean the browse surface is far smaller than the daemon's full control plane.
- **Composes with realtime voice** — the gateway's method gate already permits the `thread/realtime/*` RPCs that drive the [voice bridge](realtime-voice.md), and with the edge proxy story below for HTTP/2 and HTTP/3 termination.

## Status

- Static serving, the `/ws` bridge, TLS with auto-cert, the security layer, signed media, and uploads are **implemented and smoke-tested** (`WebGatewayTests` plus a live abuse battery documented in `SECURITY.md`).
- The single listener is **HTTP/1.1 + WebSocket** by design. HTTP/2 for static routes and HTTP/3 are handled by an **edge proxy** (Caddy/nginx); native in-process HTTP/2 multiplexing is deferred. See `HTTP2_HTTP3.md`.
- Per-IP rate limiting is treated as an edge-proxy concern for non-loopback binds.
- `make webui` is referenced as a convenience target but build via `cd www && npm run build` is the documented path.

## Go deeper

Internals and reference: `docs/webgateway/README.md`, with `docs/webgateway/PROTOCOL_MAP.md` (the JSON-RPC ⇄ UI connector wire map), `docs/webgateway/SECURITY.md`, and `docs/webgateway/HTTP2_HTTP3.md`.
