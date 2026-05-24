# CodexKit Documentation

This directory is the working manual for CodexKit. It is written for coding
agents first, with enough context for humans to review design, behavior, and
release risk without spelunking the whole source tree.

## Start here

- [System Guide](system-guide.md) explains the architecture, intent, runtime
  behavior, state model, performance choices, and extension points.
- [App-Server API Guide](app-server-api.md) documents the supported
  `codex app-server` protocol surface, request/response flow, notifications,
  implementation status, and known gaps against the official OpenAI docs.
- [Testing and Validation Guide](testing-validation.md) lists the test gates,
  severe/live validation strategy, and how to prove a change end to end.

## Source of truth

The highest-level status remains in [../STATUS.md](../STATUS.md). The crate
mapping remains in [../CRATE_DISPOSITIONS.md](../CRATE_DISPOSITIONS.md). The
evaluation and completion plans live in `../../evaluation/`.

When these documents disagree with code or tests, treat the code and tests as
the evidence, fix the behavior if it is wrong, then update the docs.
