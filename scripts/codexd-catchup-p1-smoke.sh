#!/usr/bin/env bash
# Live binary E2E for the June-2026 upstream-sync P1 wire methods. Drives the
# REAL `codexd` binary over stdio (no mock, no in-process router) and asserts
# the wire responses for: permissionProfile/list, skills/extraRoots/set +
# skills/list, thread/delete (+ thread/deleted notification), account/usage/read
# (auth gate). These are local/store operations, so NO OPENAI_API_KEY is needed
# — this is a true end-to-end binary check that always runs.
# Pure-bash watchdog; macOS + Linux.
set -euo pipefail
cd "$(dirname "$0")/.."

swift build >/dev/null

WORK="$(mktemp -d)"
OUTF="$WORK/out.txt"
ERRF="$WORK/err.txt"
trap 'rm -rf "$WORK"' EXIT

# Plant a skill in an extra root we will register at runtime.
EXTRA="$WORK/extra-skills/widgetizer"
mkdir -p "$EXTRA"
cat > "$EXTRA/SKILL.md" <<'SKILL'
---
name: widgetizer
description: makes widgets
---
Body.
SKILL

run_codexd() {
  ( printf '%s\n' \
      '{"id":1,"method":"initialize","params":{"clientInfo":{"name":"p1smoke"}}}' \
      '{"method":"initialized"}' \
      '{"id":2,"method":"thread/start","params":{"cwd":"'"$WORK"'"}}'
    # Let thread/start settle, capture the id from the id:2 response (thread ids
    # are bare lowercased UUIDs — no prefix), then drive the rest.
    for _ in $(seq 1 40); do
      tid=$(python3 -c "
import json
for ln in open('$OUTF'):
    ln=ln.strip()
    try: m=json.loads(ln)
    except Exception: continue
    if m.get('id')==2 and isinstance(m.get('result'),dict):
        t=m['result'].get('thread') or {}
        if t.get('id'): print(t['id']); break
" 2>/dev/null || true)
      [ -n "${tid:-}" ] && break
      sleep 0.25
    done
    printf '%s\n' '{"id":3,"method":"permissionProfile/list","params":{}}'
    printf '{"id":4,"method":"skills/extraRoots/set","params":{"extraRoots":["%s"]}}\n' "$WORK/extra-skills"
    printf '{"id":5,"method":"skills/list","params":{"cwds":["%s"]}}\n' "$WORK"
    printf '%s\n' '{"id":6,"method":"account/usage/read"}'
    if [ -n "${tid:-}" ]; then
      # P4: goals are no longer experimental-gated — set/get must work on this
      # plain (no experimentalApi) connection, then delete.
      printf '{"id":8,"method":"thread/goal/set","params":{"threadId":"%s","objective":"ship the sync"}}\n' "$tid"
      printf '{"id":9,"method":"thread/goal/get","params":{"threadId":"%s"}}\n' "$tid"
      printf '{"id":7,"method":"thread/delete","params":{"threadId":"%s"}}\n' "$tid"
    fi
    sleep 3
  ) | CODEX_HOME="$WORK/home" swift run codexd >"$OUTF" 2>"$ERRF"
}

run_codexd &
RUN_PID=$!
( for _ in $(seq 1 90); do kill -0 "$RUN_PID" 2>/dev/null || exit 0; sleep 1; done
  kill -9 "$RUN_PID" 2>/dev/null || true ) &
WD_PID=$!
wait "$RUN_PID" 2>/dev/null || true
kill "$WD_PID" 2>/dev/null || true

echo "--- codexd stdout (tail) ---"; tail -c 3000 "$OUTF" || true; echo

fail() { echo "FAIL: $1"; echo "--- stderr ---"; tail -c 2000 "$ERRF" 2>/dev/null || true; exit 1; }

# Assertions via a small python pass over the JSONL stdout.
python3 - "$OUTF" <<'PY' || exit 1
import json, sys
lines = []
for ln in open(sys.argv[1]):
    ln = ln.strip()
    if not ln: continue
    try: lines.append(json.loads(ln))
    except Exception: pass

def resp(i):
    for m in lines:
        if m.get("id") == i and ("result" in m or "error" in m): return m
    return None
def notifs(method):
    return [m for m in lines if m.get("method") == method]

ok = True
def check(cond, msg):
    global ok
    print(("PASS" if cond else "FAIL") + ": " + msg)
    ok = ok and cond

# 3: permissionProfile/list → 3 builtins in order
r = resp(3) or {}
ids = [p.get("id") for p in (r.get("result", {}).get("data") or [])]
check(ids[:3] == [":read-only", ":workspace", ":danger-full-access"],
      f"permissionProfile/list builtins (got {ids[:3]})")

# 4: skills/extraRoots/set → empty result
r4 = resp(4) or {}
check("result" in r4 and not (r4.get("result") or {}), "skills/extraRoots/set empty result")

# 5: skills/list includes the planted widgetizer skill from the extra root
r5 = resp(5) or {}
names = [s.get("name") for s in (r5.get("result", {}).get("data") or [])]
check("widgetizer" in names, f"skills/list surfaces extra-root skill (got {names})")

# 6: account/usage/read → auth-gate error (no chatgpt auth in smoke)
r6 = resp(6) or {}
msg = (r6.get("error") or {}).get("message", "")
check("authentication required to read token usage" in msg,
      f"account/usage/read auth gate (got {msg!r})")

# 8/9: thread/goal/set + get reachable WITHOUT experimentalApi (P4, upstream #23732)
r8 = resp(8) or {}
check("error" not in r8, f"thread/goal/set not experimental-gated (got {r8.get('error')})")
check(bool((r8.get("result") or {}).get("goal")), "thread/goal/set returns a goal")
r9 = resp(9) or {}
check(((r9.get("result") or {}).get("goal") or {}).get("objective") == "ship the sync",
      "thread/goal/get round-trips the objective")

# 7: thread/delete → empty result + thread/deleted notification
r7 = resp(7) or {}
check("result" in r7 and not (r7.get("result") or {}), "thread/delete empty result")
check(len(notifs("thread/deleted")) >= 1, "thread/deleted notification emitted")

sys.exit(0 if ok else 1)
PY
[ $? -eq 0 ] || fail "P1 wire-method assertions failed"
echo "OK: codexd P1 catchup smoke passed"
