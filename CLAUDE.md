# codex-swift — agent notes

Orientation lives in [`README.md`](README.md); per-module status in
[`STATUS.md`](STATUS.md); deep design under [`docs/`](docs/). This file captures
high-signal, easy-to-trip-over operational facts. **Frontend (the Memory Wiki
UI):** see [`www/ARCHITECTURE.md`](www/ARCHITECTURE.md).

## Embedded Postgres + pgvector store (opt-in, macOS)

Mem0 has a second, opt-in store backend: a native PostgreSQL child process +
pgvector, behind `CODEX_MEM0_STORE_BACKEND=postgres` (default stays sqlite-vec).
Targets `EmbeddedPG` (reusable postmaster lifecycle: initdb/start/stop/snapshot —
anything can depend on it) and `Mem0PgStore` (the `Mem0VectorStore` +
`Mem0HistoryStore` conformer). Both are **macOS-only, gated at the manifest level**
with `#if os(macOS)` (Linux/CI never see postgres-nio). Needs a local server build
with pgvector: `brew install postgresql@18 pgvector` (discovery finds the
`postgresql@NN` keg — the server binary is NOT on PATH, only libpq clients are).
The postmaster is **socket-only** (`listen_addresses=''`); data plane runs as a
non-superuser `codex_app` role. Tests are tag-gated: `CODEX_MEM0_PG_TEST=1 swift
test --filter Mem0PgStoreTests`. Full guide: [`docs/MEM0_POSTGRES.md`](docs/MEM0_POSTGRES.md);
design + phased plan: [`pglite.md`](pglite.md).

## On-device MLX inference lane

The on-device small-model lane (`Sources/MemoryInfer/MLXLocalProvider.swift`,
Apple MLX via `mlx-swift-lm`) **runs** as of 2026-06-09 (it had only ever
compiled before). Full writeup + rationale:
[`docs/notes/on-device-mlx-bringup.md`](docs/notes/on-device-mlx-bringup.md).

Run the Memory-Wiki import on-device:

```sh
CODEXKIT_MEMORY=1 CODEX_MEMORY_INFERENCE_BACKEND=local \
  .build/debug/codex-memory import-markdown --extract --json <roots…>
```

Two setup steps are **not** in the build and must be re-applied after a clean
checkout or `swift package reset`:

1. **Metal library.** `swift build` does not emit `default.metallib` (the Metal
   Toolchain is a separate, uninstalled Xcode component). MLX loads a colocated
   `mlx.metallib` first, so drop a version-matched one next to the binary —
   mlx-swift 0.31.4 vendors MLX C++ 0.31.1; a Python `mlx` 0.31.2 wheel's
   `mlx.metallib` is patch-compatible:
   `cp <…/site-packages/mlx/lib/mlx.metallib> .build/debug/{mlx,default}.metallib`
   (re-copy after each build that replaces `.build/debug/`).
2. **Nomic embedder patch.** `mlx-swift-lm`'s `NomicBert.swift` demands
   `position_embeddings.weight` whenever `max_position_embeddings>0`, but
   nomic-embed-text-v1.5 is fully rotary and has none → `keyNotFound`. Gate the
   block on `&& config.rotaryEmbFraction < 1.0`. (Checkout patch; upstream TODO.)

Knobs:
- `CODEX_MEMORY_INFERENCE_BACKEND` = `local` | `remote` | `auto` | `mock`.
- `CODEX_MEMORY_LOCAL_EXTRACTOR_MODEL` overrides the extractor (default
  `mlx-community/Qwen3-30B-A3B-4bit`, ~17 GB — the `…-4bit-MLX` id 401s).
- **Split** (local nomic embed + remote OpenAI extract — keeps the store's
  `embedding_provider_id` stamp consistent while extraction runs ~15× faster):
  `CODEX_MEMORY_SPLIT_REMOTE_EXTRACT=1 CODEX_MEMORY_EXTRACT_INFLIGHT=N` plus
  `import-markdown --concurrency N`.

Gotchas: Qwen3 is a reasoning model — prompts go through the chat template with
`enable_thinking=false` or it spends the whole budget in `<think>…</think>`. The
store STRICTLY matches the full embedding-provider id string, so you cannot mix
providers in one store unless the embedder (hence id) is identical. Resilient
multi-corpus driver: `scripts/wiki-import-local.sh`.
