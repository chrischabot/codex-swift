.PHONY: build release test e2e smoke live-smoke clean

build:
	swift build

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