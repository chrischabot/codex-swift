# Memory Wiki — Phase Acceptance Gates

These scripts encode the six phase gates from
`docs/codex-swift-memory-wiki.md` §10. Each phase has a clear PASS/FAIL
condition and writes an evidence file under
`$CODEXKIT_EVIDENCE_DIR/memory-phase{N}/` so a release rehearsal can audit
the outcomes.

| Phase | Script | What it proves |
|------|---------|---------------|
| 0 | `m_phase0_verify.sh` | `codex-memory verify` reports PASS; sqlite-vec linked; price pins match. |
| 1 | `m_phase1_store.sh` | 10k synthetic chunks round-trip insert/query under 200 ms p99. |
| 2 | `m_phase2_ingest_soak.sh` | 24-hour soak ingesting at ≥ 200 docs/day with zero ring drops. Crash-consistent: `kill -9` fuzzer driven recovery succeeds. |
| 3 | `m_phase3_process_score.sh` | 8k-seed corpus processed in ≤ 4 hours on M3 Max 48 GB. Score-distribution AUC ≥ 0.85 against labelled set. |
| 4 | `m_phase4_retrieve_mcp.sh` | External MCP client drives every tool. `recent_interesting` at persona=CTO reaches NDCG@10 ≥ 0.6. |
| 5 | `m_phase5_braingate.sh` | Chaos test fires 1,000 high-score chunks; rate-limited to monthly USD cap. Spend ledger reconciles to within $0.01. |
| 6 | `m_phase6_hardening.sh` | 7-day soak, sleep/wake/restart fuzz, memory-pressure injection. Zero extractor evictions, zero ring drops, p99 MCP latency ≤ 250 ms. |

Run any phase individually:

```
tools/memory/m_phase1_store.sh
```

Or all of them as the release gate:

```
tools/memory/m_all_phases.sh
```

Each script honours these environment variables:

- `CODEXKIT_EVIDENCE_DIR` — directory where the gate writes JSON evidence
  the verifier can audit. Defaults to a temp dir.
- `CODEXKIT_MEMORY_QUICK` — when set, runs shortened versions of the
  long-running phases (1 minute soak instead of 24 h, etc.). Used in CI.
