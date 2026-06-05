# codex-swift documentation

The working manual for codex-swift. Every page opens with *why it matters* and a
plain-language overview, then deepens into behavior and internals — so you can
read the first screen to get oriented, or keep going as far as you need.

New here? The friendliest on-ramp is the project **[README](../README.md)**: a
30-second picture, then "a closer look" at each big idea, then links into these
docs.

## Start here

- **[Getting Started](guides/getting-started.md)** — build the package, run your
  first streamed turn, and meet the daemon layout.
- **[Multi-Process Architecture](features/multi-process-architecture.md)** — the
  mental model: why it's a constellation of processes and what that buys you.
- **[Security, Sandboxing & Approvals](guides/security.md)** — how the agent runs
  real commands without becoming a foothold on your machine.

## Browse by what you want to do

- **Use it day to day** — [Configuration](guides/configuration.md),
  [Skills](guides/skills.md), [Slash Commands](guides/slash-commands.md),
  [MCP servers](guides/mcp.md), [Addons & extensions](guides/addons-and-plugins.md).
- **Understand the agent** — [Turn loop](features/agent-loop.md),
  [Models & providers](features/models-and-providers.md),
  [Tools](features/tools.md), [Memory](features/memory.md),
  [Prompts & context](features/prompts-and-context.md),
  [Persistence & resume](features/persistence-and-resume.md),
  [Auth](features/auth.md).
- **Reach it / let it reach you** — [Web Gateway](features/web-gateway.md),
  [Realtime voice](features/realtime-voice.md),
  [Channels](features/channels.md), [Computer use](features/computer-use.md),
  [Push](features/push.md), [Cron](features/cron.md), [Media](features/media.md),
  [Connectors](features/connectors.md), [Workflows](features/workflows.md).
- **Integrate with it** — [App-Server API Guide](app-server-api.md),
  [The protocol, narratively](features/protocol.md), [Hooks](features/hooks.md).
- **Operate it** — [Observability](features/observability.md),
  [Usage & cost](features/usage-and-cost.md),
  [Benchmarks](features/benchmarks.md),
  [Testing & validation](testing-validation.md).

For the full system overview in one place, see the **[System Guide](system-guide.md)**;
for the deep internals (architecture, protocol registry, sandbox profiles, config
schema) see the reference docs listed in the README's "Reference / internals" table.

## Source of truth

The highest-level status is **[../STATUS.md](../STATUS.md)**; the crate mapping is
**[../CRATE_DISPOSITIONS.md](../CRATE_DISPOSITIONS.md)**. When a doc disagrees with
the code or tests, treat the code and tests as the evidence — fix the behavior if
it's wrong, then update the doc.
