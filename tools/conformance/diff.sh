#!/usr/bin/env bash
# Compare the current Swift protocol surface with the pinned Codex oracle.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
DEFAULT_CODEX_TREE="$(cd "$REPO_ROOT/.." && pwd)/codex"
CODEX_TREE="${CODEX_TREE:-$DEFAULT_CODEX_TREE}"
SCHEMA_DIR="${CODEX_SCHEMA_DIR:-$CODEX_TREE/codex-rs/app-server-protocol/schema/json}"
CLIENT_REQUEST="$SCHEMA_DIR/ClientRequest.json"
GOLDEN_DIR="$SCRIPT_DIR/golden"
PIN_FILE="$SCRIPT_DIR/PINNED_REV"

cd "$REPO_ROOT"

if [[ ! -f "$PIN_FILE" ||
      ! -f "$GOLDEN_DIR/client-methods.txt" ||
      ! -f "$GOLDEN_DIR/client-method-fields.json" ||
      ! -f "$GOLDEN_DIR/typescript-manifest.json" ||
      ! -f "$GOLDEN_DIR/schema-manifest.json" ]]; then
  echo "FAIL: conformance goldens are missing; run tools/conformance/bootstrap.sh first." >&2
  exit 66
fi
if [[ ! -f "$CLIENT_REQUEST" ]]; then
  echo "FAIL: pinned Codex ClientRequest schema not found: $CLIENT_REQUEST" >&2
  exit 66
fi

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/codexkit-conformance.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" golden \
  --codex-tree "$CODEX_TREE" \
  --schema-dir "$SCHEMA_DIR" \
  --golden-dir "$TMP_DIR" \
  --pin "$(cat "$PIN_FILE")"

if ! diff -u "$GOLDEN_DIR/client-methods.txt" "$TMP_DIR/client-methods.txt"; then
  echo "FAIL: pinned Codex method surface drifted; fix Swift coverage or intentionally refresh goldens." >&2
  exit 68
fi
if ! diff -u "$GOLDEN_DIR/schema-manifest.json" "$TMP_DIR/schema-manifest.json"; then
  echo "FAIL: pinned Codex schema manifest drifted; move to the pinned oracle or intentionally refresh goldens." >&2
  exit 68
fi
if ! diff -u "$GOLDEN_DIR/client-method-fields.json" "$TMP_DIR/client-method-fields.json"; then
  echo "FAIL: pinned Codex method/field surface drifted; fix Swift coverage or intentionally refresh goldens." >&2
  exit 68
fi
if ! diff -u "$GOLDEN_DIR/typescript-manifest.json" "$TMP_DIR/typescript-manifest.json"; then
  echo "FAIL: pinned Codex generated TypeScript surface drifted; fix Swift coverage or intentionally refresh goldens." >&2
  exit 68
fi

echo "+ python3 tools/conformance/schema_tools.py typescript-manifest"
PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" typescript-manifest \
  --codex-tree "$CODEX_TREE" \
  --schema-dir "$SCHEMA_DIR" > "$TMP_DIR/typescript-report.json"
python3 - <<'PY' "$TMP_DIR/typescript-report.json"
import json
import sys
report = json.load(open(sys.argv[1]))
missing = report["jsonSchemaTypesMissingGeneratedTypeScript"]
suffix = "" if not missing else f"; JSON schemas without generated TS (excluding JSONRPC internals): {missing}"
print(f"generated TypeScript manifest parity OK ({report['fileCount']} files, {report['totalBytes']} bytes{suffix})")
PY

echo "+ python3 tools/conformance/schema_tools.py swift-field-report"
PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" swift-field-report \
  --repo-root "$REPO_ROOT" \
  --schema-dir "$SCHEMA_DIR" > "$TMP_DIR/swift-field-report.json"
python3 - <<'PY' "$TMP_DIR/swift-field-report.json"
import json
import sys
report = json.load(open(sys.argv[1]))
print(f"typed method field parity OK ({report['typedMethodCount']} typed request params)")
PY

echo "+ python3 tools/conformance/schema_tools.py generic-response-report"
PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" generic-response-report \
  --repo-root "$REPO_ROOT" \
  --codex-tree "$CODEX_TREE" > "$TMP_DIR/generic-response-report.json"
python3 - <<'PY' "$TMP_DIR/generic-response-report.json"
import json
import sys
report = json.load(open(sys.argv[1]))
print(
    "generic response schema parity OK "
    f"({report['checkedCount']} checked, {report['skippedCount']} skipped without generated schemas)"
)
PY

echo "+ python3 tools/conformance/schema_tools.py concrete-response-report"
PYTHONPATH="$SCRIPT_DIR" python3 "$SCRIPT_DIR/schema_tools.py" concrete-response-report \
  --repo-root "$REPO_ROOT" \
  --codex-tree "$CODEX_TREE" > "$TMP_DIR/concrete-response-report.json"
python3 - <<'PY' "$TMP_DIR/concrete-response-report.json"
import json
import sys
report = json.load(open(sys.argv[1]))
print(f"concrete response schema parity OK ({report['checkedCount']} typed responses checked)")
PY

echo "+ CODEX_SCHEMA_DIR=$SCHEMA_DIR swift test --filter SchemaParityTests"
CODEX_SCHEMA_DIR="$SCHEMA_DIR" swift test --filter SchemaParityTests

echo
echo "conformance diff OK"
