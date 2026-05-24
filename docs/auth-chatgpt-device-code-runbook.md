# Manual Live ChatGPT Device-Code Completion Runbook

This is the operator runbook for closing the **manual live ChatGPT device-code**
gate referenced in `STATUS.md`. The Swift code path
(`Sources/Auth/OAuthPKCE.swift`, `CurlDeviceCodeClient`) is wired through the
app-server `account/login/start` route with `type: "chatgptDeviceCode"` and is
covered by deterministic success/failure/cancel tests in
`Tests/IntegrationTests/EndToEndTests.swift`. What remains is **operator-driven
evidence against the real ChatGPT issuer**.

Run this once per release on the certified release Mac, capture the three
transcripts described below, and place them under
`$CODEXKIT_EVIDENCE_DIR/auth/chatgpt-device-code/` so the strict release
verifier can index them.

## Prerequisites

| Requirement | How to satisfy |
|---|---|
| Build of `codexd` and the loopback CLI client | `swift build -c release` |
| Network egress to the ChatGPT issuer | Required during all three transcripts |
| Empty `$CODEX_HOME` for each transcript | `export CODEX_HOME=$(mktemp -d)` between runs |
| `OPENAI_API_KEY` **unset** | This runbook intentionally exercises the no-API-key path |
| Account credentials | A real OpenAI/ChatGPT account that owns the relevant plan |

## Environment matrix

| Variable | Purpose | Required for runbook |
|---|---|---|
| `CODEX_HOME` | Token store + rollout root | yes — set to a fresh dir per transcript |
| `CODEX_OAUTH_ISSUER` | Override default issuer | no, unless validating staging issuer |
| `CODEXKIT_AUTH_STORE=file` | Force file token store (skip Keychain) | optional, useful when capturing the persisted JSON for evidence |
| `CODEXKIT_EVIDENCE_DIR` | Where to write the captured transcripts | yes — release rehearsal indexes this |

## Transcript 1 — Success

1. `CODEX_HOME=$(mktemp -d) ./.build/release/codexd --stdio` (or your equivalent
   loopback driver).
2. Issue `account/login/start` with `{"type":"chatgptDeviceCode"}`.
3. Note the `verificationUrl` and `userCode` in the response. The expected
   shape:
   ```json
   {
     "loginId": "<uuid>",
     "type": "chatgptDeviceCode",
     "verificationUrl": "https://<issuer>/codex/device",
     "userCode": "<six-or-eight char code>"
   }
   ```
4. On a second device, open `verificationUrl`, sign in, and enter `userCode`.
5. Observe the streamed `account/login/completed` notification with
   `success: true` and a matching `loginId`, followed by `account/updated` with
   `authMode: "chatgpt"` and the expected `planType`.
6. Verify the persisted token: with `CODEXKIT_AUTH_STORE=file` set, confirm
   `$CODEX_HOME/auth.json` exists with mode `0600`. Otherwise verify Keychain
   item presence with `security find-generic-password -s CodexKit -a chatgpt`.

**Evidence to capture** (`$CODEXKIT_EVIDENCE_DIR/auth/chatgpt-device-code/success.json`):

```json
{
  "operator": "<release operator name>",
  "createdAt": "<ISO-8601 UTC>",
  "issuer": "https://<issuer>",
  "loginIdRedacted": true,
  "userCodeRedacted": true,
  "responseShape": { "type": "chatgptDeviceCode", "hasVerificationUrl": true, "hasUserCode": true },
  "completed": { "success": true, "errorIsNull": true },
  "accountUpdated": { "authMode": "chatgpt", "planTypePresent": true },
  "tokenPersisted": true,
  "tokenStoreMode": "<keychain|file:0600>"
}
```

Redact the `loginId` and `userCode` strings — neither carries
post-completion authority but both leak account identity.

## Transcript 2 — Failure

Repeat with intentionally invalid credentials, an invalid `userCode`, or by
letting the device-auth request expire:

1. Same `account/login/start` flow.
2. On the second device, decline the consent or type an incorrect code three
   times so the issuer returns a non-200 status.
3. Observe `account/login/completed` with `success: false` and a non-empty
   `error` string surfacing the issuer status (e.g. `device auth failed with
   status 400`).
4. Confirm `account/updated` was **not** emitted and the token store is empty.

**Evidence** (`failure.json`): same shape as `success.json` but
`completed.success = false`, `completed.errorContains = "device auth failed
with status <N>"`, `tokenPersisted = false`, `accountUpdated = null`.

## Transcript 3 — Cancel

1. Same `account/login/start` flow.
2. Without completing the device flow, issue
   `account/login/cancel` with `{ "loginId": "<from step 1>" }`.
3. Observe the cancel response `{"status": "canceled"}` and the
   `account/login/completed` notification with `success: false` and
   `error: "canceled"`.
4. Confirm the token store is empty.

**Evidence** (`cancel.json`): `completed.error = "canceled"`,
`tokenPersisted = false`, `accountUpdated = null`.

## Verification gate

Add a strict verifier rule (in a follow-up patch to
`tools/e2e/verify_release_evidence.py`) that requires all three JSON files
under `auth/chatgpt-device-code/` with the asserted shape, hashes them, and
folds them into the final manifest. Until that rule is wired, the runbook
output is operator-attested rather than verifier-enforced.

## Notes for the operator

- Do **not** paste real `userCode` values, `access_token` values, or
  `refresh_token` values into the evidence JSON or commit logs. The evidence
  schema above carries only redacted boolean shape assertions.
- If you must capture a raw HTTP transcript for protocol debugging, scrub
  `Authorization: Bearer …`, `refresh_token`, `id_token`, `code`, and
  `code_verifier` before placing the file under `CODEXKIT_EVIDENCE_DIR`.
- The token-poll interval is supplied by the issuer (`interval` field, default
  5 s). Successful completion typically takes 30–90 s of operator time after
  consent.
- The polling deadline is 15 minutes (see
  `CurlDeviceCodeClient.complete(config:challenge:)`); if the operator does
  not consent within that window the run reports a server-side timeout, not
  cancel.
