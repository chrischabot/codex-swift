.PHONY: build release test e2e smoke live-smoke clean webui webui-install web-smoke

build:
	swift build

# Build the web UI bundle (www/dist) that the web gateway serves. Requires
# node (deps vendored in www/node_modules; run `make webui-install` to
# (re)install). bun is NOT used at build or runtime.
webui:
	cd www && npm run build

webui-install:
	cd www && npm ci --no-audit --no-fund

# Loopback dev gateway over plaintext (browser-testable; no cert trust needed).
web-smoke: build webui
	CODEXKIT_MOCK=1 CODEXKIT_IN_PROCESS_WORKERS=1 CODEXKIT_WEB_INSECURE=1 \
	  CODEXKIT_WEB_ROOT="$(PWD)/www/dist" \
	  .build/debug/codexd --listen off --listen-web 127.0.0.1:8443

release:
	swift build -c release

test:
	swift test

# Gate G1–G5 regression set (unit + integration + adversarial).
e2e: build
	swift test --filter IntegrationTests
	swift test --filter AdversarialTests

smoke:
	bash scripts/codexd-stdio-smoke.sh

live-smoke:
	bash scripts/codexd-stdio-live-smoke.sh

clean:
	rm -rf .build