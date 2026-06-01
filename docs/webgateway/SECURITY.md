# WebGateway security model

The web gateway exposes the codex-swift agent control-plane (which can run
arbitrary commands, spawn processes, and read/write files under the sandbox) to
a browser. This document is the threat model, the controls, the abuse-test
results, and the risks consciously accepted for the **single-tenant v1**.

## Trust model

- **Default bind is loopback** (`127.0.0.1`), no auth — the existing daemon trust
  model (loopback + UDS-0600). The web shell loads same-origin.
- **Any non-loopback bind auto-requires a bearer token** (fail-closed). codexd
  generates one and prints it to stderr if `CODEXKIT_WEB_TOKEN` is unset.
- **Single-tenant**: one auth token = one user = the operator of the host. All
  threads in the store belong to that user. Multi-user hosting is explicitly out
  of scope (see Accepted risks).

## Controls (implemented)

| Control | Where | Notes |
|---|---|---|
| TLS 1.3 only | `WebGateway.run` | `minimumTLSVersion = .tlsv13`; nmap-confirmed grade-A, no weak suites |
| Bearer auth (WS upgrade) | `SecurityPolicy.bearerAccepted` | token via `bearer.<token>` subprotocol (browsers can't set WS Authorization); **constant-time** compare |
| Origin allowlist | `SecurityPolicy.originAllowed` | rejects userinfo (`evil@127.0.0.1`); empty list = loopback only; missing Origin rejected when auth required |
| Host validation (anti-DNS-rebind) | `SecurityPolicy.hostAllowed` | `request.head.authority` must match bind host / allowed-origin host / loopback |
| Deny-default method allowlist | `MethodGate` + `serve.admit` | requests gated to the UI's method set; notifications gated to `initialized`; blocks `command/exec`, `config/write`, `account/*`, etc. with `-32601` |
| WS message size cap | `serve` | 1 MiB reassembled (`WireCodec` limits) |
| Idle timeout | `serve` watchdog | closes a WS with no inbound frame for `idleTimeoutSeconds` (default 300) — slowloris defense |
| Connection cap | `ConnectionLimiter` | global concurrent-session cap (default 256) — pool-exhaustion defense |
| Security headers | `SecurityHeadersMiddleware` | CSP (scoped for shiki wasm + same-origin WS), `frame-ancestors 'none'`, HSTS (TLS), COOP, CORP, `X-Content-Type-Options`, Permissions-Policy |
| Static path-traversal | Hummingbird `FileMiddleware` | rejects `..` (literal + encoded) → 400 |
| TLS key perms | `DevCert` | key pre-created 0600; startup fails closed if looser |
| Guaranteed session cleanup | `serve` teardown | `connectionClosed` runs on every disconnect (idle, RST, EOF); no subscription leak |

## Abuse-test results (validated)

| Test | Result |
|---|---|
| TLS 1.2 forced | rejected (protocol-version alert) |
| nmap ssl-enum-ciphers | TLS 1.3 only, least strength **A** |
| WS upgrade, no token (auth on) | rejected (400) |
| WS upgrade, wrong token | rejected (400) |
| WS upgrade, foreign Origin | rejected (400) |
| **Origin userinfo bypass** `http://evil@127.0.0.1` | **rejected (400)** |
| **DNS-rebind** foreign `Host` | **rejected (400)** |
| Missing Origin + good token (auth on) | rejected (400) |
| Good token + loopback origin + host | **upgraded (101)** |
| `command/exec`, `config/write`, `account/logout` over WS | blocked (`-32601`) |
| Path traversal (literal + `%2e` encoded) | 400, no file leak |
| App under full CSP/headers | renders + streams, 0 console violations |

Tools used: `curl`, `openssl s_client`, `nmap --script ssl-enum-ciphers`, `node`
WebSocket client, Chrome DevTools (MCP). (h2load/nghttp/testssl.sh/ZAP not
installed in this environment; recommended for a pre-prod gate.)

## Risks accepted for single-tenant v1 (must-fix for multi-tenant)

- **Cross-connection thread access (IDOR).** `RequestRouter` turn/thread mutators
  accept any `threadId` without an ownership check, and `thread/list` enumerates
  all threads. For single-tenant this is *by design* (all connections are the
  same user's tabs). **Must-fix before multi-tenant**: gate every threadId-bearing
  handler on `subscriptions[threadId] != nil`. Not fixed here to preserve
  RequestRouter wire-parity with the stdio/UDS transports.
- **`thread/start` arbitrary `cwd`.** A remote (authenticated, single) user can
  point the agent anywhere on their own host — that is the product (remote control
  of your own agent). Add `restrictCwd` for multi-tenant.
- **Token via env/stderr.** Convenient for v1; for hardened deploys prefer a
  `0600` token file over `CODEXKIT_WEB_TOKEN` (env is readable via `/proc`) and
  avoid logging the token to stderr (container log capture).
- **Per-IP rate limiting** is delegated to an edge proxy (the in-process control
  is a global connection cap + idle timeout). Mandate `limit_conn`/`limit_req` at
  the edge in the internet-exposure runbook.
- COEP `require-corp` not set (no crossOriginIsolated/SharedArrayBuffer need);
  CORP + COOP + `frame-ancestors` cover the embedding/clickjacking surface.

## Internet-exposure runbook (before binding non-loopback)

1. Provide a real cert (ACME/mkcert), not the self-signed dev cert.
2. Set `CODEXKIT_WEB_ORIGINS` to the exact public origin(s).
3. Front with an edge proxy doing per-IP `limit_conn`/`limit_req` (and, later,
   HTTP/3 via Alt-Svc).
4. Deliver the bearer token out-of-band (token file), not via env/stderr.
5. Re-run the abuse battery + `testssl.sh`/`h2load`/ZAP on the public endpoint.
