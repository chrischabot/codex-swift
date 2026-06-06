# Deferred: Gemma 4 26B-A4B (MoE) on the MLX on-device lane

**Status: deferred (2026-06). Decision: keep the working default; revisit when cheap.**

The on-device lane (`Sources/MemoryInfer/MLXLocalProvider.swift`) already defaults its
extractor to a fully-supported MoE in the same niche:

```
mlx-community/Qwen3-30B-A3B-4bit-MLX   // 30B total / ~3B active, model_type qwen3_moe
```

`mlx-community/gemma-4-26b-a4b-it-4bit` would be a lateral move (a ~3.8B-active MoE), and
benchmarks suggest the Qwen3 MoE is comparable-or-better for triage/novelty-ranking. So it
is **not** worth a numerically-delicate, unvalidated hand-port today. This note captures
everything needed to finish the port quickly when the cost drops.

## Why it doesn't load today

`mlx-swift-lm` 3.31.3 (latest as of 2026-04) ships Gemma 4 **dense** support only
(`Gemma4Text.swift` has a dense `gate/up/down` MLP — no router/experts). The 26B-A4B is
MoE, so it dispatches to the dense `Gemma4Model`/`Gemma4TextModel` and fails to load (the
`router.*` / `experts.switch_glu.*` tensors have nowhere to go). Tracking:
- ml-explore/mlx-swift-lm#282, ml-explore/mlx-swift#389.

## Trigger to revisit (cheapest first)

1. **Upstream lands Gemma 4 MoE** → bump the `mlx-swift-lm` pin in `Package.swift`, set
   `extractorModelID = "mlx-community/gemma-4-26b-a4b-it-4bit"`, validate. Done.
2. **You specifically want it before then** → do the port below (register a MoE-aware
   `"gemma4"` model from our code — no fork needed).

## The port (no fork required)

`ModelTypeRegistry.registerModelType(_:creator:)` is **public**, so at lane startup:

```swift
LLMModelFactory.shared.typeRegistry.registerModelType("gemma4") { data in
    try Gemma4MoEModel(JSONDecoder().decode(Gemma4Configuration.self, from: data))
}
```

Implement `Gemma4MoEModel` by copying the package's `Gemma4Text.swift` (its attention /
norms / PLE / dual-RoPE are correct — reuse verbatim) and adding the MoE FFN. Branch on
`enable_moe_block` so the same model still serves the dense 12B/31B.

### Config fields to add (text_config)

`num_experts=128`, `num_experts_per_tok=8`, `moe_intermediate_size=704`,
`enable_moe_block=true`, plus existing dense `intermediate_size=2112`,
`hidden_size=2816`, `num_hidden_layers=30`, `head_dim=256`, `global_head_dim=512`
(full-attn layers), `sliding_window=1024`, dual RoPE (full: θ=1e6 proportional,
partial_rotary_factor=0.25; sliding: θ=1e4 default), alternating sliding/full (every 6th
full), `max_position_embeddings=262144`.

### MoE block (per the mlx-vlm reference — VERIFY arithmetic against verbatim source)

Each MoE decoder layer runs a **dense MLP and a sparse expert path in parallel, summed**:

```
h1 = post_feedforward_layernorm_1( mlp( pre_feedforward_layernorm(h) ) )      # dense
idx, w = router(h)                  # see Router below
h2 = post_feedforward_layernorm_2( experts( pre_feedforward_layernorm_2(h), idx, w ) )
h_ffn = h1 + h2
# then post_feedforward_layernorm(...) + the residual add, scaled by `layer_scalar`
```

- **Router**: RMS-norm the input with a learned scale (`router.scale * hidden_size**-0.5`),
  `proj = Linear(hidden, 128, bias=false)`, top-8 via argpartition, **softmax the top-k
  logits**, multiply by `router.per_expert_scale[idx]`, **no renorm**.
- **Experts**: `SwitchGLU(inputDims=hidden, hiddenDims=704, numExperts=128, activation=GeGLU)`
  (GeGLU = `gelu_approx(gate) * up`). Aggregate `(w.expandDims(-1) * y).sum(-2)`.

> ⚠️ The three spots most likely to need a fix on first device run (summary-sourced, not
> verbatim): the **residual add + `layer_scalar`** placement, whether the **router sees
> pre- or post-attention `h`**, and the **softmax-before-vs-after top-k** order. Diff against
> mlx-vlm `mlx_vlm/models/gemma4/language.py` before trusting output.

### Exact weight keys (from the repo's `model.safetensors.index.json`)

Per layer `language_model.model.layers.{i}.` (all linears quantized → `.weight/.scales/.biases`):

```
self_attn.{q,k,v,o}_proj ; self_attn.{q,k}_norm.weight   (no v_norm weight → RMSNormNoScale)
mlp.{gate,up,down}_proj                                   (dense path)
router.proj ; router.scale ; router.per_expert_scale
experts.switch_glu.{gate,up,down}_proj                    (STACKED [128, …] — siblings of mlp)
input_layernorm ; post_attention_layernorm
pre_feedforward_layernorm ; post_feedforward_layernorm
post_feedforward_layernorm_1 ; pre_feedforward_layernorm_2 ; post_feedforward_layernorm_2
layer_scalar
```

Note: experts are **already stacked** under `experts.switch_glu.*` (mlx-vlm stored them via
`SwitchGLU` at conversion), so — unlike `Qwen3MoE.sanitize` — **no per-expert→stacked join
is needed**; the `@ModuleInfo(key:)` names just need to match. MLP + router are 8-bit;
the rest 4-bit (`mlx-swift` reads per-layer quant from `config.json`, so it's automatic if
module structure matches).

### Validate on Apple Silicon

```bash
# (downloads ~15 GB once)
CODEXKIT_MLX=1 swift test --filter MemoryInferTests   # or a tiny script:
#   set extractorModelID = "mlx-community/gemma-4-26b-a4b-it-4bit", run one extract() call,
#   confirm it loads + returns coherent text. Compare a few logits vs. python mlx_vlm.
```

If it loads but the text is garbage, the bug is in the MoE arithmetic above (the three ⚠️
spots), not the weight keys.
