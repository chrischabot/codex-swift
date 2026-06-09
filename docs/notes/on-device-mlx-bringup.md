# On-device MLX bring-up (first real runtime)

The on-device lane (`Sources/MemoryInfer/MLXLocalProvider.swift`) **compiled** for a
long time but had never actually **run** inference. Bringing it up for the
Memory-Wiki import surfaced four blockers. Two are fixed in-repo; two are
environment/dependency steps that must be re-applied after a clean checkout or
`swift package reset/update`.

Run the import with the local lane via:

```sh
CODEXKIT_MEMORY=1 CODEX_MEMORY_INFERENCE_BACKEND=local \
  .build/debug/codex-memory import-markdown --extract --json <roots…>
```

(`CODEX_MEMORY_INFERENCE_BACKEND=auto` falls back to remote OpenAI when MLX is
unavailable; force `local` to require on-device.)

## 1. In-repo fixes (committed)

- **Tokenizer (`CodexKitHubDownloader.swift`).** The mlx-swift-lm fork strips
  swift-transformers and exposes a BYO `TokenizerLoader` hook that previously
  threw *"BYO tokenizer required."* We added `apple/swift-transformers` (gated to
  the MLX build in `Package.swift`) and implemented `CodexKitTokenizerLoader` via
  `AutoTokenizer.from(modelFolder:)`, adapting it to the fork's minimal
  `MLXLMCommon.Tokenizer` protocol (`SwiftTransformersTokenizerAdapter`).
- **Extractor model id (`MLXLocalProvider.swift`).** The default
  `mlx-community/Qwen3-30B-A3B-4bit-MLX` 401s — that repo does not exist. The
  real id is `mlx-community/Qwen3-30B-A3B-4bit` (~17.2 GB). Now
  `defaultExtractorModelID`, overridable with `CODEX_MEMORY_LOCAL_EXTRACTOR_MODEL`.

## 2. Out-of-repo steps (re-apply after a clean checkout)

### a. Metal shader library (`default.metallib` / `mlx.metallib`)

`swift build` does **not** produce MLX's `default.metallib` — modern Xcode makes
the Metal Toolchain a separate component (`xcodebuild -downloadComponent
MetalToolchain`) that isn't installed, so the kernels never compile. MLX's loader
(`device.cpp`) tries a **colocated `mlx.metallib`** first, so we drop a
version-matched prebuilt one next to the binary. mlx-swift 0.31.4 vendors MLX C++
**0.31.1**; a Python `mlx` **0.31.2** wheel ships a patch-compatible
`mlx.metallib`:

```sh
SRC=$(find / -name mlx.metallib -path '*site-packages/mlx/lib/*' 2>/dev/null | head -1)
cp "$SRC" .build/debug/mlx.metallib
cp "$SRC" .build/debug/default.metallib   # belt-and-suspenders
```

Must be re-copied after every `swift build` that replaces `.build/debug/`.

### b. Nomic embedder rotary-position fix (dependency patch)

`mlx-swift-lm`'s `MLXEmbedders/Models/NomicBert.swift` creates learned position
embeddings whenever `max_position_embeddings > 0`, but `nomic-embed-text-v1.5` is
**fully rotary** (`rotary_emb_fraction: 1.0`) and ships no
`embeddings.position_embeddings.weight` → `keyNotFound` on load. Gate the block on
non-rotary models:

```swift
// .build/checkouts/mlx-swift-lm/Libraries/MLXEmbedders/Models/NomicBert.swift
if config.maxPositionEmbeddings > 0 && config.rotaryEmbFraction < 1.0 {
    _positionEmbeddings.wrappedValue = Embedding(
        embeddingCount: config.maxPositionEmbeddings, dimensions: config.embedDim)
}
```

This is a checkout patch (wiped by `swift package reset/update`). Upstream it to
the fork, or re-apply after resolving. TODO: pin a fork with the fix so it's
durable.
