#!/usr/bin/env bash
# build-embedded-pg-bundle.sh — pglite.md Phase 2.
#
# Produce a RELOCATABLE, Developer-ID-signed, hardened-runtime, (optionally)
# notarized PostgreSQL + pgvector bundle that codex-swift's EmbeddedPG lane can
# carry and run from any path.
#
# Layout: we REPLICATE the source build's prefix-relative structure so
# PostgreSQL's own path relocation (find_my_exec → make_relative_path) resolves
# pkglibdir + sharedir into the bundle — which is what makes `initdb` (loads
# $libdir/dict_snowball) and `CREATE EXTENSION vector` ($libdir/vector) find the
# BUNDLED, re-signed modules instead of the original Homebrew ones. Example
# (Homebrew pg18: bindir=…/Cellar/postgresql@18/18.4/bin, pkglib=…/lib/…,
# share=…/share/…):
#
#   <bundle>/
#     Cellar/postgresql@18/18.4/bin/  postgres initdb pg_ctl pg_isready psql createdb
#     Cellar/postgresql@18/18.4/lib/  <shared dylibs: icu/ssl/lz4/zstd/intl/krb5…>
#     lib/postgresql@18/              <full pkglibdir: vector.dylib, dict_snowball.dylib, …>
#     share/postgresql@18/            <full sharedir: postgres.bki, snowball, tsearch_data, …>
#
# Because EVERY bundled Mach-O is re-signed under one Team ID, hardened-runtime
# LIBRARY VALIDATION stays ON (no disable-library-validation entitlement).
#
# Usage: scripts/build-embedded-pg-bundle.sh [--src <pg-bindir>] [--out <dir>]
#                                            [--sign|--no-sign] [--notarize] [--skip-test]
set -euo pipefail

# ---- config -----------------------------------------------------------------
SRC_BIN="${SRC_BIN:-$(ls -d /opt/homebrew/Cellar/postgresql@*/*/bin 2>/dev/null | sort -V | tail -1)}"
OUT_DIR="${OUT_DIR:-$PWD/.build/embedded-pg}"
TEAM_ID="${CODEXKIT_TEAM_ID:-28FC5D45XH}"
SIGN_IDENTITY="${CODEXKIT_SIGN_IDENTITY:-Developer ID Application: The Photo Map LLC (${TEAM_ID})}"
NOTARY_PROFILE="${CODEXKIT_NOTARY_PROFILE:-ProseDown-Notarization}"
DO_SIGN=auto ; DO_NOTARIZE=0 ; DO_TEST=1
BINARIES=(postgres initdb pg_ctl pg_isready psql createdb)

while [ $# -gt 0 ]; do case "$1" in
  --src) SRC_BIN="$2"; shift 2;;
  --out) OUT_DIR="$2"; shift 2;;
  --sign) DO_SIGN=1; shift;;
  --no-sign) DO_SIGN=0; shift;;
  --notarize) DO_NOTARIZE=1; DO_SIGN=1; shift;;
  --skip-test) DO_TEST=0; shift;;
  *) echo "unknown arg: $1" >&2; exit 2;;
esac; done

BUNDLE="$OUT_DIR/embedded-pg"
step() { printf '\n\033[1;34m== %s\033[0m\n' "$*"; }
fail() { printf '\033[1;31merror:\033[0m %s\n' "$*" >&2; exit 1; }
relpath() { python3 -c "import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]))" "$1" "$2"; }

[ -n "$SRC_BIN" ] && [ -x "$SRC_BIN/postgres" ] || fail "no postgres server binary under SRC_BIN=$SRC_BIN"
PGC="$SRC_BIN/pg_config"
SRC_BINDIR="$("$PGC" --bindir)"
SRC_PKGLIB="$("$PGC" --pkglibdir)"
SRC_SHARE="$("$PGC" --sharedir)"
[ -f "$SRC_PKGLIB/vector.dylib" ] || fail "pgvector not found at $SRC_PKGLIB/vector.dylib (brew install pgvector)"

# common prefix of bindir/pkglib/share (the install prefix postgres relocates against)
PREFIX="$(python3 -c "import os,sys; print(os.path.commonpath(sys.argv[1:]))" "$SRC_BINDIR" "$SRC_PKGLIB" "$SRC_SHARE")"
BIN_SUF="${SRC_BINDIR#$PREFIX/}"          # Cellar/postgresql@18/18.4/bin
PKG_SUF="${SRC_PKGLIB#$PREFIX/}"          # lib/postgresql@18
SHARE_SUF="${SRC_SHARE#$PREFIX/}"         # share/postgresql@18
SHLIB_SUF="$(dirname "$BIN_SUF")/lib"     # Cellar/postgresql@18/18.4/lib  (= bin/../lib)

BIN_DIR="$BUNDLE/$BIN_SUF"; SHLIB_DIR="$BUNDLE/$SHLIB_SUF"
PKG_DIR="$BUNDLE/$PKG_SUF"; SHARE_DIR="$BUNDLE/$SHARE_SUF"
PKG_TO_SHLIB="$(relpath "$SHLIB_DIR" "$PKG_DIR")"   # ../../Cellar/postgresql@18/18.4/lib

# ---- 1. stage (replicate prefix layout) -------------------------------------
step "Stage prefix-relative bundle from $SRC_BIN (prefix=$PREFIX)"
rm -rf "$BUNDLE"; mkdir -p "$BIN_DIR" "$SHLIB_DIR" "$PKG_DIR" "$SHARE_DIR"
for b in "${BINARIES[@]}"; do cp -p "$SRC_BIN/$b" "$BIN_DIR/$b"; chmod u+w "$BIN_DIR/$b"; done
# -L dereferences: Homebrew's pkglib/share are farms of relative symlinks into the
# Cellar — we need the REAL files in the bundle, not dangling links.
# full pkglibdir, minus build/test infra not needed at runtime (pgxs ships stray
# unsigned Mach-O test exes that fail notarization; bitcode is JIT-only).
cp -RL "$SRC_PKGLIB"/. "$PKG_DIR"/; rm -rf "$PKG_DIR/bitcode" "$PKG_DIR/pgxs"
cp -RL "$SRC_SHARE"/. "$SHARE_DIR"/                                   # full sharedir (initdb needs it)
find "$PKG_DIR" "$SHARE_DIR" -type f -exec chmod u+w {} +
echo "  bin: $BIN_SUF | pkglib: $PKG_SUF ($(ls "$PKG_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') modules) | share: $SHARE_SUF"

# ---- 2. collect non-system dylib deps (BFS over originals; follows @loader_path) ----
step "Collect shared dylib dependencies → $SHLIB_SUF"
declare -A SEEN=()
WORK=()
for b in "${BINARIES[@]}"; do WORK+=("$SRC_BIN/$b"); done
while IFS= read -r m; do WORK+=("$m"); done < <(find "$SRC_PKGLIB" -maxdepth 1 -type f \( -name '*.dylib' -o -name '*.so' \))
resolve_dep() { local dep="$1" srcdir="$2" p=""
  case "$dep" in
    /System/*|/usr/lib/*) return 0;;
    @loader_path/*|@executable_path/*) p="$srcdir/${dep#@*path/}";;
    @rpath/*) p="$srcdir/${dep#@rpath/}";;
    /*) p="$dep";;
    *) return 0;;
  esac
  # `readlink -f` is unavailable on older macOS — use python realpath (portable).
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$p" 2>/dev/null || true
}
while [ ${#WORK[@]} -gt 0 ]; do
  src="${WORK[0]}"; WORK=("${WORK[@]:1}")
  [ -f "$src" ] || continue
  srcdir="$(cd "$(dirname "$src")" && pwd)"
  while read -r dep; do
    real="$(resolve_dep "$dep" "$srcdir")"
    [ -n "$real" ] && [ -f "$real" ] || continue
    case "$real" in /usr/lib/*|/System/*) continue;; esac
    name="$(basename "$dep")"                      # install-name basename (symlink-safe)
    [ -n "${SEEN[$name]:-}" ] && continue
    SEEN[$name]=1
    cp -p "$real" "$SHLIB_DIR/$name"; chmod u+w "$SHLIB_DIR/$name"
    WORK+=("$real")
  done < <(otool -L "$src" 2>/dev/null | tail -n +2 | awk '{print $1}')
done
echo "  bundled $(ls "$SHLIB_DIR"/*.dylib 2>/dev/null | wc -l | tr -d ' ') shared dylibs"

# ---- 3. rewrite install names to @loader_path -------------------------------
step "Rewrite install names → @loader_path"
rewrite() { # $1=file  $2=relpath-from-file-dir-to-SHLIB
  local f="$1" toshlib="$2" dep
  while read -r dep; do
    case "$dep" in /opt/homebrew/*|"$PREFIX"/*) ;; *) continue;; esac
    install_name_tool -change "$dep" "@loader_path/$toshlib/$(basename "$dep")" "$f" 2>/dev/null || true
  done < <(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}')
}
for b in "$BIN_DIR"/*; do rewrite "$b" "$(relpath "$SHLIB_DIR" "$BIN_DIR")"; done
for d in "$SHLIB_DIR"/*.dylib; do
  install_name_tool -id "@loader_path/$(basename "$d")" "$d" 2>/dev/null || true
  rewrite "$d" "."
done
while IFS= read -r d; do
  install_name_tool -id "@loader_path/$(basename "$d")" "$d" 2>/dev/null || true
  rewrite "$d" "$PKG_TO_SHLIB"
done < <(find "$PKG_DIR" -type f \( -name '*.dylib' -o -name '*.so' \))

# ---- 4. verify relocatability -----------------------------------------------
step "Verify relocatability (no $PREFIX refs)"
LEAK=0
while IFS= read -r f; do
  deps="$(otool -L "$f" 2>/dev/null | tail -n +2 | awk '{print $1}' || true)"
  if printf '%s\n' "$deps" | grep -q "^$PREFIX/"; then
    echo "  LEAK in $f:"; printf '%s\n' "$deps" | grep "^$PREFIX/" | sed 's/^/    /'; LEAK=1
  fi
done < <(find "$BUNDLE" -type f \( -name '*.dylib' -o -name '*.so' -o -path "$BIN_DIR/*" \))
[ "$LEAK" = 0 ] || fail "absolute prefix dylib paths survived the rewrite"
BUNDLE_SIZE="$(du -sh "$BUNDLE" | awk '{print $1}')"
echo "  OK — fully relocatable ($BUNDLE_SIZE)"

# ---- 5. sign (library validation stays ON) ----------------------------------
if [ "$DO_SIGN" = auto ]; then
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  case "$ids" in *"$SIGN_IDENTITY"*) DO_SIGN=1;; *) echo "  (no identity '$SIGN_IDENTITY' — unsigned)"; DO_SIGN=0;; esac
fi
if [ "$DO_SIGN" = 1 ]; then
  step "Code-sign every Mach-O (Developer ID + hardened runtime + timestamp)"
  ids="$(security find-identity -v -p codesigning 2>/dev/null || true)"
  case "$ids" in *"$SIGN_IDENTITY"*) ;; *) fail "identity not in keychain: $SIGN_IDENTITY";; esac
  # Sign + strict-verify EVERY Mach-O (detected by `file`, not extension) so no
  # stray executable slips through — Apple notarization rejects any unsigned/
  # un-hardened Mach-O. Classify once per file (sign then verify in the same pass).
  n=0
  while IFS= read -r f; do
    ft="$(file "$f" 2>/dev/null || true)"
    case "$ft" in *Mach-O*) ;; *) continue;; esac
    codesign --force --options runtime --timestamp --sign "$SIGN_IDENTITY" "$f" >/dev/null 2>&1 || fail "codesign failed: $f"
    codesign --verify --strict "$f" 2>/dev/null || fail "verify failed: $f"
    n=$((n+1))
  done < <(find "$BUNDLE" -type f)
  pdesc="$(codesign -d --verbose=2 "$BIN_DIR/postgres" 2>&1 || true)"
  case "$pdesc" in *"Authority=Developer ID Application"*) ;; *) fail "postgres not Developer-ID signed";; esac
  echo "  signed + verified $n Mach-O under Team $TEAM_ID (library validation ON)"
fi

# ---- 6. functional test from a RELOCATED path (relies on PG relocation) ------
if [ "$DO_TEST" = 1 ]; then
  step "Functional test from a relocated copy (initdb → CREATE EXTENSION vector → HNSW)"
  REL="$(mktemp -d)"; cp -R "$BUNDLE" "$REL/embedded-pg"; RB="$REL/embedded-pg/$BIN_SUF"
  PGDATA="$(mktemp -d)/pgdata"; RUN="$(mktemp -d)/run"; mkdir -p "$RUN"; chmod 700 "$RUN"
  cleanup() { "$RB/pg_ctl" stop -D "$PGDATA" -m immediate >/dev/null 2>&1 || true; rm -rf "$REL" "$(dirname "$PGDATA")" "$(dirname "$RUN")"; }
  trap cleanup EXIT
  "$RB/initdb" -D "$PGDATA" -U codex --auth-local=trust --auth-host=reject --no-instructions -E UTF8 >/dev/null 2>"$PGDATA.initdb.log" \
    || { echo "--- initdb.log ---"; tail -20 "$PGDATA.initdb.log"; fail "initdb failed in relocated bundle"; }
  "$RB/pg_ctl" start -D "$PGDATA" -w -t 30 -o "-c listen_addresses='' -k $RUN" -l "$PGDATA.pg.log" >/dev/null \
    || { echo "--- pg.log ---"; tail -25 "$PGDATA.pg.log"; fail "relocated postmaster failed to start"; }
  "$RB/createdb" -h "$RUN" -U codex t >/dev/null
  OUT="$("$RB/psql" -h "$RUN" -U codex -d t -tAX \
    -c "CREATE EXTENSION vector" -c "CREATE TABLE v(e vector(3))" \
    -c "CREATE INDEX ON v USING hnsw (e vector_cosine_ops)" \
    -c "INSERT INTO v VALUES ('[1,0,0]'),('[0,1,0]')" \
    -c "SELECT e <=> '[1,0,0]' AS d FROM v ORDER BY d LIMIT 1" 2>&1)" \
    || { echo "$OUT"; fail "CREATE EXTENSION / HNSW failed in relocated bundle"; }
  DIST="$(printf '%s\n' "$OUT" | tail -1)"   # psql echoes each -c's status tag; the result is the last line
  [ "$DIST" = "0" ] || { echo "$OUT"; fail "expected nearest distance 0, got '$DIST'"; }
  echo "  ✓ relocated signed postgres ran initdb + dlopened re-signed vector.dylib under library validation (HNSW dist=$DIST)"
  cleanup; trap - EXIT
fi

# ---- 7. notarize + staple (DMG) ---------------------------------------------
if [ "$DO_NOTARIZE" = 1 ]; then
  step "Package DMG + notarize + staple"
  command -v xcrun >/dev/null || fail "xcrun not found"
  xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1 \
    || fail "notarytool profile '$NOTARY_PROFILE' not set up (see ProseDown/release.sh header)"
  DMG="$OUT_DIR/embedded-pg.dmg"; rm -f "$DMG"
  hdiutil create -quiet -fs HFS+ -volname "codex-embedded-pg" -srcfolder "$BUNDLE" -ov -format UDZO "$DMG"
  codesign --force --timestamp --sign "$SIGN_IDENTITY" "$DMG"
  echo "  submitting to Apple notary service (a few minutes)…"
  xcrun notarytool submit "$DMG" --keychain-profile "$NOTARY_PROFILE" --wait || fail "notarization failed"
  xcrun stapler staple "$DMG" && xcrun stapler validate "$DMG" || fail "staple failed"
  echo "  ✓ notarized + stapled: $DMG"
fi

step "Done"
echo "Bundle:  $BUNDLE  ($BUNDLE_SIZE)"
echo "Use it:  CODEX_MEM0_PG_BINDIR=$BIN_DIR"
[ "$DO_NOTARIZE" = 1 ] && echo "DMG:     $OUT_DIR/embedded-pg.dmg (notarized + stapled)"
exit 0
