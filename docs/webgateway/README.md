# WebGateway — codex-swift web server + WebSocket gateway

`WebGateway` is the user-facing web server built into `codexd`. It serves the
compiled shadcn UI (`www/dist`) over TLS and bridges browser WebSocket sessions
straight into per-connection `RequestRouter`s over the **shared**
`SessionSupervisor`, in-process — no external RPC hop. bun/vite exist only at
build time (`vite build` → `www/dist`); the running system is a single binary.

## Status

Milestone complete (everything-in-one):

- [x] `WebGateway` SwiftPM target (Hummingbird 2.25 + SwiftNIO; repo's first networking dep)
- [x] TLS 1.3 listener, auto-generated SAN dev cert (`DevCert`, key 0600 fail-closed)
- [x] Static serving of `www/dist` (FileMiddleware + immutable `/assets` cache + SPA fallback + hard-404)
- [x] WebSocket gateway `/ws` ⇄ per-tab `RequestRouter` over the shared supervisor (duplex bridge, idle-timeout, connection cap)
- [x] `codexd --listen-web` wiring (shared session pool with stdio/UDS clients)
- [x] `connector-codex.ts` — UI adapter speaking app-server JSON-RPC; maintains `snapshot.messages`, history-loading, uploads
- [x] **Security layer** — bearer auth (fail-closed on non-loopback), Origin allowlist (userinfo-spoof safe), Host check (anti-DNS-rebind), deny-default method allowlist, constant-time token compare, CSP/HSTS/COOP/CORP/frame-ancestors. See `SECURITY.md`.
- [x] **Media** — signed `/media/:token` (HMAC, short-TTL, rel-path-in-token) with `Range`/206. See `Media.swift`/`MediaToken.swift`.
- [x] **Uploads** — `POST /api/upload` multipart (byte-level parser, UUID names, content MIME-sniff, per-thread quota, sandbox staging) → `localImage` turn-input. See `Upload.swift`.
- [x] **HTTP/2 + HTTP/3** via edge proxy (Caddy/nginx); native in-process hybrid deferred. See `HTTP2_HTTP3.md`.
- [x] **Tests** — `WebGatewayTests` (27): SecurityPolicy, MethodGate, MediaToken, multipart/MIME. Plus live abuse battery (curl/openssl/nmap/node/Chrome) in `SECURITY.md`.
- [x] Adversarial reviews (workflow-driven) + severe testing per component

## Architecture

```
browser ──TLS──▶ codexd : WebGateway (Hummingbird)
                 ├─ GET /                 → www/dist/index.html (SPA shell)
                 ├─ GET /assets/*         → hashed JS/CSS/wasm/fonts (immutable)
                 ├─ GET /healthz,/readyz  → ok
                 ├─ GET /api/*  (planned) → JSON + uploads
                 ├─ GET /media/* (planned)→ signed, Range/206 media
                 └─ WS  /ws               → WebSocketClientConnection (ClientConnection)
                                             └─ per-tab RequestRouter
                                                └─ shared SessionSupervisor ──▶ worker processes
```

Each browser tab gets its **own** `RequestRouter` instance (fixing the
single-client `initialized`/`caps`/`subscriptions` collision) over the one
shared `SessionSupervisor`, so web tabs and local stdio/UDS clients see the same
session pool. The bridge runs the canonical
`for await m in conn.incoming() { await router.handle(m, conn) }` loop and fires
`connectionClosed` on every disconnect.

Why a single `.http1WebSocketUpgrade` TLS listener (HTTP/1.1) for v1: the UI must
be **same-origin** with its WebSocket (Chrome 148 Local Network Access), and
Hummingbird 2.x cannot serve WebSocket upgrades on an HTTP/2 listener (no RFC
8441). HTTP/2 for the static routes is layered on next via a custom ALPN-routing
channel; HTTP/3 is an edge-proxy concern (no production Swift QUIC server).

## Running

```sh
make webui                 # vite build → www/dist  (planned make target)
# or: (cd www && npm run build)

# Loopback dev (mock model, no API key needed), web gateway on :8443, app-server off:
CODEXKIT_MOCK=1 CODEXKIT_WEB_ROOT="$PWD/www/dist" \
  .build/debug/codexd --listen off --listen-web 127.0.0.1:8443

open https://127.0.0.1:8443      # self-signed: trust once, or use an mkcert leaf
```

### Configuration (flags / env)

| Flag / env | Default | Meaning |
|---|---|---|
| `--listen-web[=HOST:PORT]` / `CODEXKIT_LISTEN_WEB` | (off) | Enable the gateway; bind addr |
| `CODEXKIT_WEB_ROOT` | `$PWD/www/dist` | Static bundle dir |
| `CODEXKIT_WEB_CERT` / `CODEXKIT_WEB_KEY` | `$CODEX_HOME/web-gateway/{cert,key}.pem` | TLS leaf (auto-generated if missing) |

The gateway runs alongside the app-server transport (`--listen`), sharing the
supervisor. `--listen off --listen-web …` runs web-only.

> **Security:** the default bind is loopback. The agent plane is arbitrary local
> RCE (exec/spawn/fs-write/apply_patch); a non-loopback bind MUST NOT be enabled
> until the security layer (auth + deny-default method allowlist + signed media +
> rate limiting + CSP) is in place and severe-tested. See PROTOCOL_MAP.md for the
> wire contract.

## See also

- `PROTOCOL_MAP.md` — app-server JSON-RPC ⇄ shadcn `Connector` wire map
- `Sources/WebGateway/` — the implementation
- `www/src/runtime/connector-codex.ts` — the UI-side adapter
