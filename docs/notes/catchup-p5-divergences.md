# Catchup P5 — documented divergences (extensions framework, remote control)

Two of the five Phase-5 scope items were decided (2026-06-15, with the maintainer)
as **intentional divergences** rather than ports. The other three (encrypted local
secrets, multi-agent v2, code mode) are being **ported** in dedicated sub-phases.

## 1. Extensions framework — DIVERGENCE (keep the port's in-process model)

**Upstream** grew a contributor/event-sink extension framework (turn-input
contributors #25959, extension event-sink capability #23293, async turn-item /
approval contributors #23692/#23690, thread-idle lifecycle hook #24744,
user-instructions via injected provider #27101). It is the connective tissue
under upstream's goals/skills/multi-agent.

**Port** uses `Sources/ExtensionAPI/ExtensionAPI.swift` (~390 lines) — a simpler,
in-process extension surface (context modules, tool packs, MCP servers, channels,
model providers — the "five seams" in `ADDONS.md`). The port's goals, skills, and
hooks are wired directly into `SessionEngine`/`HookEngine` rather than through an
extension-contributor bus.

**Rationale for divergence:** the contributor framework is an internal
re-architecture upstream adopted to decouple its subsystems; the port already
achieves the same *features* (goals accounting, skills injection, hooks incl. the
new SubagentStart/Stop) through direct wiring with no functional loss. Porting the
bus would be a large re-architecture with no observable wire/behavior gain and
would churn the goals/skills/multi-agent integration. This matches the port's
established posture for feature-internal upstream refactors. Re-evaluate only if a
future feature genuinely needs the contributor indirection.

## 2. Remote control / pairing — OUT OF SCOPE

**Upstream** added a remote-control/pairing feature area: pairing start/status
transport (#26449/#26450/#25675), client-management RPCs (#25785), server-token
migration (#24141), managed-disable enforcement + persisted desired state
(#27961/#27445), plus reconnect/backoff/auth-recovery fixes.

**Port** carries `remoteControl/enable`, `remoteControl/disable`,
`remoteControl/status/read` in `Method.all` (so dispatch doesn't `-32601`) behind
the experimental gate, but has **no functional pairing transport** — they are
gated stubs.

**Rationale for out-of-scope:** remote control is a cloud-pairing feature for the
hosted product; the single-operator port's trust model is the **transport-as-owner-
boundary** (`docs/features/push.md`) — there is no per-RPC owner token and no
cloud control plane to pair with. Implementing pairing would require a live
backend to enroll against and validate, which the port has no counterpart for. The
gated stubs remain (wire-surface presence) but the feature is an explicit scope
boundary. Revisit only if the port grows a remote control plane.

---

The three PORTED items (encrypted local secrets, multi-agent v2, code mode) are
tracked as their own sub-phases in `tools/catchup-backlog.md` and the task list,
each driven through implement → adversarial review → severe test → live validation.
