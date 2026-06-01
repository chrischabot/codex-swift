# HTTP/2 and HTTP/3 for the WebGateway

**Outcome: HTTP/2 and HTTP/3 are delivered via an edge proxy** (one command), not
in the Swift process. The native gateway speaks HTTP/1.1 + WebSocket over TLS 1.3
on a single same-origin listener; an edge proxy terminates h2/h3 and reverse-
proxies to it. This matches the already-accepted HTTP/3 decision and is the
standard production pattern.

## Why not native HTTP/2 in-process (feasibility verdict)

The gateway must serve the UI **and** the WebSocket on the **same origin/port**
(Chrome 148 Local Network Access), but Hummingbird 2.x cannot do both natively:

- `HTTPServerBuilder.http2Upgrade(...)` gives `h2 + http/1.1` over one TLS
  listener, but its `http/1.1` branch is a plain `HTTP1Channel` — **no WebSocket
  upgrade** (HB has no RFC 8441 / Extended-CONNECT WS-over-h2).
- `HTTPServerBuilder.http1WebSocketUpgrade(...)` gives `h1 + WS`, but **no h2**.

A custom `ServerChildChannel` that ALPN-routes (`h2` → `HTTP2Channel`,
`http/1.1` → `HTTP1WebSocketUpgradeChannel`) is the only in-process option. We
investigated it against the pinned **hummingbird 2.25 / swift-nio 2.100**
(`docs/webgateway/` spec run): it requires composing channel internals and the
package-internal `TLSChannelInternalConfiguration`, so it does not compile
without effectively forking Hummingbird. It is a real but fragile 4–6h spike
maintaining bespoke ALPN/HTTP-2-pipeline code across HB upgrades. Given h1.1 +
TLS 1.3 is fully Chrome-compatible (validated) and the edge-proxy path delivers
**both h2 and h3** robustly, native in-process h2 is **deferred** (tracked as a
future spike; the analysis is preserved in the spec workflow output).

## Recommended: Caddy edge proxy (h2 + h3 + Alt-Svc, automatic)

Caddy terminates TLS, speaks HTTP/2 and HTTP/3 (QUIC) to the browser, advertises
`Alt-Svc` automatically, and reverse-proxies (incl. WebSocket upgrade) to the
loopback gateway. Run the gateway loopback + plaintext (or TLS) and put Caddy in
front:

```
# Caddyfile — h2 + h3 in front of the codex-swift web gateway
app.example.com {
    encode zstd gzip
    # Caddy auto-provisions a real cert (ACME) and serves h2 + h3.
    reverse_proxy 127.0.0.1:8443 {
        # The gateway terminates its own TLS by default; if running it with
        # CODEXKIT_WEB_INSECURE=1 (plaintext loopback) drop the next line.
        transport http {
            tls_insecure_skip_verify   # gateway uses a self-signed dev cert
        }
    }
}
```

```sh
# 1) gateway, loopback, plaintext (Caddy provides TLS/h2/h3 at the edge):
CODEXKIT_WEB_INSECURE=1 CODEXKIT_WEB_REQUIRE_AUTH=1 \
  CODEXKIT_WEB_ORIGINS="https://app.example.com" \
  CODEXKIT_WEB_ROOT="$PWD/www/dist" \
  codexd --listen off --listen-web 127.0.0.1:8443
# (copy the printed bearer token)

# 2) edge proxy:
caddy run --config Caddyfile
```

Verify h2/h3 once the proxy is up:

```sh
curl -I --http2 https://app.example.com/healthz          # HTTP/2 200
curl -I --http3 https://app.example.com/healthz          # HTTP/3 200 (curl built with HTTP/3)
nghttp -nv https://app.example.com/                       # h2 frames
```

> Same-origin still holds: the browser only ever talks to `app.example.com`
> (the edge), which proxies same-origin to the loopback gateway — it never
> crosses from a public page to `127.0.0.1`.

## nginx alternative

nginx ≥ 1.25 supports `http2 on;` and `http3 on;` (with QUIC). Reverse-proxy to
`127.0.0.1:8443`, set `proxy_set_header Upgrade/Connection` for the `/ws` route,
and add `add_header Alt-Svc 'h3=":443"; ma=86400';`.

## When to revisit native h2

Pursue the in-process hybrid channel only if an edge proxy is unacceptable for
the deployment. It would be its own branch + the HTTP2HybridTests, gated behind
`config.tls`, built on public NIOSSL pipeline APIs (not HB internals).
