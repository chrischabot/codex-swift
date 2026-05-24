#!/usr/bin/env bash
# Shared helpers for the memory-phase gate scripts.

set -euo pipefail

# _common.sh's own absolute path, captured at source time so repo_root works
# regardless of the caller's current working directory.
__COMMON_SH_PATH="${BASH_SOURCE[0]:-$0}"
__MEMORY_TOOLS_DIR="$(cd "$(dirname "$__COMMON_SH_PATH")" && pwd)"
__REPO_ROOT="$(cd "$__MEMORY_TOOLS_DIR/../.." && pwd)"

repo_root() { printf '%s' "$__REPO_ROOT"; }

ensure_built() {
    cd "$(repo_root)"
    if [[ ! -x .build/debug/codex-memory ]]; then
        echo "[gate] building codex-memory..."
        swift build --product codex-memory >&2
    fi
}

evidence_dir() {
    local phase="$1"
    local root
    root="${CODEXKIT_EVIDENCE_DIR:-$(mktemp -d /tmp/codex-memory-evidence.XXXXXX)}/memory-phase${phase}"
    mkdir -p "$root"
    printf '%s' "$root"
}

write_evidence() {
    local phase="$1" file="$2"
    shift 2
    local dir
    dir="$(evidence_dir "$phase")"
    printf '%s' "$*" > "$dir/$file"
    printf '%s\n' "$dir/$file"
}

pass_or_fail() {
    local ok="$1" phase="$2" msg="$3"
    if [[ "$ok" == "true" ]]; then
        echo "[memory phase $phase] PASS — $msg"
        return 0
    fi
    echo "[memory phase $phase] FAIL — $msg" >&2
    return 1
}
