# Embedded Postgres + pgvector store for Mem0

> Status: **implemented (Phase 0 + Phase 1 of [`pglite.md`](../pglite.md))**, macOS-only,
> opt-in. The default store is unchanged (SQLite + sqlite-vec). This document is
> both the **user guide** (how to turn it on and drive it) and the **design note**
> (how it works, why, and its limits).

---

## 1. What this is

A second, opt-in storage backend for the in-project Mem0 engine that keeps
memories + their embedding vectors in a **real, native PostgreSQL** instance with
the **pgvector** extension, instead of SQLite + sqlite-vec.

The headline win: today's `Mem0SQLiteStore.search()` does **brute-force cosine in
Swift over an in-RAM cache** of every memory
([`Mem0SQLiteStore.swift:323`](../Sources/Mem0Store/Mem0SQLiteStore.swift)). The
Postgres backend replaces that with a single indexed query —
`ORDER BY vector <=> $1 LIMIT k` over an **HNSW** index — which scales to
100k–1M+ vectors, plus real SQL filtering, full WAL durability, autovacuum, and a
real keyword (full-text) path.

It is **Architecture B** from [`pglite.md`](../pglite.md): a *managed native
postmaster run as a child process*, bound only to a UNIX socket, driven from Swift
over [PostgresNIO](https://github.com/vapor/postgres-nio). It is "as native as is
responsible" — real arm64 Postgres binaries with full durability autonomy, rather
than an in-process single-user fork that lacks autovacuum/checkpointer/WAL-writer.

### When to use it
- You have a large memory corpus (tens of thousands of vectors or more) and the
  brute-force SQLite search is getting slow.
- You want real concurrency, real durability (WAL/autovacuum/checkpointer), or the
  Postgres ecosystem (pg_trgm, full-text, PostGIS, …).

### When NOT to use it
- Linux / CI / minimal deployments → keep the default. The Postgres lane is
  macOS-only and requires a local Postgres install (or a bundled one — Phase 2).
- Small corpora where brute-force is already instant.

---

## 2. Quick start

### Prerequisites (macOS)
A PostgreSQL **server** build with **pgvector** installed. The easiest:

```sh
brew install postgresql@18 pgvector
```

That gives you `/opt/homebrew/Cellar/postgresql@18/<ver>/bin/{postgres,initdb,pg_ctl}`
and `/opt/homebrew/share/postgresql@18/extension/vector.control`. The store
**auto-discovers** this — no PATH setup needed (note: Homebrew puts only the
`libpq` *client* tools on PATH, not the `postgres` server, so discovery resolves
the `postgresql@NN` keg directly).

### Turn it on
```sh
CODEX_MEM0_STORE_BACKEND=postgres .build/debug/codex-mem0 serve
```
On first run this will, fully automatically:
1. `initdb` a fresh cluster at `$CODEX_HOME/mem0/pg/pgdata` (auth: local-trust,
   host-reject),
2. start a postmaster bound **only** to a UNIX socket under
   `$CODEX_HOME/mem0/pg/run/` (no TCP port),
3. `CREATE EXTENSION vector`, create the schema + HNSW index, and a
   least-privilege `codex_app` role,
4. connect as `codex_app` and serve.

If Postgres or pgvector is missing, the daemon **logs a warning and falls back to
sqlite-vec** — it never hard-fails on a misconfigured backend.

### Verify
```sh
CODEX_MEM0_STORE_BACKEND=postgres .build/debug/codex-mem0 verify
# stderr: "codex-mem0: embedded Postgres store ready (PGDATA …)"
```

### Programmatic use (any target)
Both libraries are SwiftPM products, so any macOS target can depend on `EmbeddedPG`
+ `Mem0PgStore` and get an embedded store in one call:

```swift
import Mem0PgStore
// Spins up + provisions a cluster under $CODEX_HOME/mem0/pg and opens the store.
let store = try await Mem0PgVectorStore.openDefault(dims: 1536)
// `store` conforms to both Mem0VectorStore + Mem0HistoryStore — pass it as both
// to Mem0Engine, exactly like Mem0SQLiteStore.
```
Need control over paths/lifecycle? Use `PGPaths` + `PostgresLifecycle` +
`Mem0PgVectorStore.open(paths:dims:lifecycle:)` directly. The lower-level
`EmbeddedPG` target (lifecycle + APFS snapshots) is independently reusable for any
embedded-Postgres need, not just the mem0 store.

---

## 3. Configuration (environment knobs)

| Variable | Default | Meaning |
|---|---|---|
| `CODEX_MEM0_STORE_BACKEND` | `sqliteVec` | `postgres` to opt in; `sqlite`/`sqlitevec` for the default; `auto` (= sqlite for now). Unknown/unavailable → falls back to sqlite-vec. |
| `CODEX_MEM0_EMBEDDING_DIM` | `1536` | Vector dimensionality. Drives the `vector(N)` column type and the HNSW/halfvec choice (see §6). |
| `CODEX_MEM0_PG_BINDIR` | auto | Override the directory holding `postgres`/`initdb`/`pg_ctl` (used for a bundled relocatable build). |
| `CODEX_MEM0_PG_ROOT` | `$CODEX_HOME/mem0/pg` | Cluster root (holds `pgdata/` + `run/`). |
| `CODEX_MEM0_PG_DATA` | `<root>/pgdata` | `PGDATA` directory (must be on a **local APFS** volume — never a network/virtiofs mount). |
| `CODEX_MEM0_PG_SOCKET_DIR` | `<root>/run` | UNIX socket directory. Kept shallow for the 104-byte `sun_path` limit; auto-falls back to `$TMPDIR` if too deep. |

The backend selector is intentionally **separate** from the *inference* backend
selector (`CODEX_MEM0_EMBEDDING_BACKEND` / `CODEX_MEM0_LLM_BACKEND`, which choose
MLX-local vs OpenAI-remote vs mock). You can freely combine, e.g. local MLX
embeddings + a Postgres store.

---

## 4. Architecture & how it works

```
 codex-mem0 (Mem0Engine, unchanged: holds `any Mem0VectorStore`/`any Mem0HistoryStore`)
        │  picks a backend via Mem0StoreBackendResolver
        ▼
 ┌───────────────────────────────┐        ┌──────────────────────────────┐
 │ Mem0PgVectorStore  (actor)    │  UNIX  │ native postmaster (child)    │
 │  • Mem0VectorStore            │ socket │  • full WAL/autovacuum/      │
 │  • Mem0HistoryStore           │◀──────▶│    checkpointer              │
 │  • single PostgresNIO conn    │        │  • pgvector HNSW             │
 │  • FIFO serialization gate    │        │  • listen_addresses='' (no   │
 └───────────────────────────────┘        │    TCP, ever)                │
        │ spawns/supervises                └──────────────────────────────┘
        ▼
 PostgresLifecycle (actor) — initdb · pg_ctl start/stop · readiness · createdb
```

Three new SwiftPM targets (all `#if os(macOS)`-gated, mirroring the `CSQLiteVec`
precedent):

| Target | Role |
|---|---|
| `EmbeddedPG` | Reusable, dependency-light lifecycle for a local postmaster: `PGPaths` (discovery), `PostgresLifecycle` (initdb/start/stop/readiness), `PGSnapshot` (APFS clone). **Anything in the project can depend on this** to get an embedded Postgres. |
| `Mem0PgStore` | `Mem0PgVectorStore` (the store actor), `PGFilterTranslator` (filter→SQL), `Mem0PgError` (SQLSTATE mapping). Depends on `Mem0Core` + `EmbeddedPG` + PostgresNIO. |
| `Mem0PgStoreTests` | Tag-gated integration tests (`CODEX_MEM0_PG_TEST=1`). |

### The seam (zero engine change)
`Mem0Engine` is a `struct` holding `any Mem0VectorStore` / `any Mem0HistoryStore`
([`Mem0Engine.swift`](../Sources/Mem0Core/Mem0Engine.swift)). `Mem0PgVectorStore`
conforms to **both** protocols, so it's passed as both `vectorStore` and
`historyStore` — exactly like `Mem0SQLiteStore`. The engine is untouched. Backend
selection lives in `Mem0StoreBackendResolver`
([`StoreBackendResolution.swift`](../Sources/Mem0Core/StoreBackendResolution.swift))
and is wired in `codex-mem0`'s `resolveStore(...)`.

### Schema
```sql
CREATE EXTENSION vector;
CREATE TABLE memories (id text PRIMARY KEY, vector vector(1536), payload jsonb NOT NULL);
CREATE INDEX memories_vec_hnsw ON memories USING hnsw (vector vector_cosine_ops);
CREATE INDEX memories_fts ON memories USING gin (to_tsvector('simple', coalesce(payload->>'text_lemmatized','')));
-- + history(...) and messages(...) tables mirroring the SQLite schema
```

### Query mapping vs the SQLite store
| Operation | SQLite-vec lane | Postgres lane |
|---|---|---|
| `search` | brute-force Swift cosine over an in-RAM cache | `ORDER BY vector <=> $1 LIMIT k` (HNSW index). Score = `max(1 − cosine_distance, 0)`, equivalent to SQLite's `max(cosine, 0)`. |
| `keywordSearch` | BM25 in Swift over `text_lemmatized` | Postgres `ts_rank` / `plainto_tsquery` over `text_lemmatized` (GIN index). |
| filters | `Mem0Filters.matchesFilters` in Swift | translated to **parameterized JSONB SQL** (see §5) |
| `list` | sort by `created_at` desc in Swift | `ORDER BY payload->>'created_at' DESC NULLS LAST` |
| history / messages | SQLite tables | mirrored Postgres tables, same ordering + 10-message eviction |

---

## 5. Filter translation & security

Mem0 filters use a small grammar (`Mem0Filters`): the operators
`eq/ne/gt/gte/lt/lte/in/nin/contains/icontains`, the boolean groupings `$or`/`$not`,
a `"*"` wildcard (key present & non-null), plain scalar equality, and JSON-null
values are skipped. `PGFilterTranslator`
([`PGFilterTranslator.swift`](../Sources/Mem0PgStore/PGFilterTranslator.swift))
translates this to a SQL predicate over the `jsonb payload` column.

**Injection safety is structural.** Every dynamic value AND every dynamic key is a
bound parameter (`$n`): keys go through `payload -> $n` / `jsonb_exists(payload, $n)`,
values through `$n::jsonb`. The SQL skeleton is entirely static — there is no
string-concatenated user data anywhere. A filter key of `'; DROP TABLE memories;--`
is just a (harmless) bound text value.

**Faithfulness is verified, not assumed.** `FilterParityTests` runs the *entire*
grammar (26+ cases incl. `$or`/`$not`/wildcard/absent-key/type-mismatch) through
**both** stores and asserts identical result sets — a self-validating oracle. It
already caught one real bug: `$not` over an absent key (SQL three-valued logic
made `NOT NULL` drop rows Swift keeps); fixed by coercing the negated group's
`NULL`→`false`.

**Documented residual divergences** (benign for mem0's string-scoped filters):
- **Numeric equality:** JSONB treats `5` and `5.0` as equal; Swift's `JSONValue`
  equality treats `.int(5)` and `.double(5.0)` as distinct. So an `eq`/`in` filter
  whose value is a whole-number double can match an int-typed payload on the
  Postgres lane.
- **Numbers stored as strings, range ops:** `gt`/`gte`/`lt`/`lte` coerce numeric
  payloads and **decimal or scientific-notation strings** (`"100"`, `"1.5e10"`).
  Swift's `Double(_:)` additionally accepts `+5`, `.5`, `5.`, and `0x10`; those
  rare string forms are not coerced by the SQL guard.

### Security model
- **No TCP, ever.** The postmaster is spawned with `-c listen_addresses=''` and
  the cluster is `initdb`'d with `--auth-host=reject`, so only the local UNIX
  socket (mode `0700`) is reachable.
- **Trust auth on the socket** is safe *because* there is no TCP listener; the
  socket dir is `0700` (owner-only).
- **Least-privilege data plane.** The one-time bootstrap (extension, schema, role)
  runs as the superuser; all CRUD then runs as a **non-superuser `codex_app`** role
  with only `SELECT/INSERT/UPDATE/DELETE` grants — so `COPY … TO PROGRAM`,
  `lo_import`, `pg_read_file`, and `CREATE EXTENSION` are denied to the data plane.

---

## 6. Dimensions, durability, snapshots, concurrency

**Dimensions.** pgvector's HNSW index caps at 2000 dims (`vector`) / 4000
(`halfvec`). The store picks automatically:
- `dims ≤ 2000` → `vector(N)` + HNSW (`vector_cosine_ops`)
- `2000 < dims ≤ 4000` → `halfvec(N)` + HNSW (`halfvec_cosine_ops`)
- `dims > 4000` → `vector(N)`, **no index** (exact sequential scan)

**Degenerate vectors.** NaN/Inf vectors are **rejected up-front** with a clear
`Mem0Error.validation` (pgvector would also reject them at the cast, rolling back
the batch — the guard just gives a cleaner error and never opens a transaction).
This is stricter than the SQLite lane, which silently stores them. A finite
all-zero vector is accepted; its cosine score is a finite `0`.

**Durability.** A real postmaster gives full WAL + autovacuum + checkpointer +
`fsync=on` — strictly better than the in-process single-user model (which defaults
`fsync` off). Crash recovery is Postgres's own.

**Snapshots (macOS APFS clone).** `Mem0PgVectorStore.snapshot(to:)` issues a
`CHECKPOINT` then an APFS copy-on-write clone (`copyfile(COPYFILE_CLONE)`) of
`PGDATA` — near-instant, near-zero-space backups / branch-a-database / test
fixtures. The clone includes `pg_wal`, so it recovers on re-open. ⚠️ This is a
*best-effort online* snapshot; for the strongest guarantee, take a **cold**
snapshot (stop the postmaster, clone, restart). See the torn-clone caveat in
[`pglite.md`](../pglite.md) §11.

**Concurrency (v1).** A single connection owned by the actor, with a **FIFO
serialization gate** so every operation runs to completion before the next — this
preserves the engine's existing non-atomic read-modify-write semantics exactly and
avoids actor-reentrancy interleaving another op's queries into an open transaction.
A pooled-reads / serialized-write split is a documented v2 (pglite.md §5).

---

## 7. Testing

Integration tests live in `Tests/Mem0PgStoreTests` and are **gated behind
`CODEX_MEM0_PG_TEST=1`** (they spawn a real local postmaster), so a normal
`swift test` skips them — CI without a Postgres runtime is unaffected.

```sh
CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests
```

`PGTestHarness.withCluster(dims:)` creates a throwaway cluster under a temp dir and
**guarantees teardown** (stop postmaster + delete dir) even on failure, so tests
never leak postmasters or disk. `PGTestHarness.parityIDs(...)` is a parity oracle:
it applies the same operations to both a `Mem0SQLiteStore` and a
`Mem0PgVectorStore` and returns both id-sets so a test can assert they match.

The suite (all severe / adversarial):

| File | Covers |
|---|---|
| `Mem0PgStoreTests` | smoke insert/search; get/update(no-op on absent)/delete |
| `FilterParityTests` | the **whole filter grammar** as a parity oracle vs SQLite (26+ cases: every operator, `$or`/`$not`, wildcard, absent keys, null-skip, `list`) |
| `InjectionAbuseTests` | SQL-injection round-trips as opaque data; multi-MB payloads; **least-privilege denial** (`COPY…TO PROGRAM` / `pg_read_file` / `lo_import` / DDL all rejected for `codex_app`); **no-TCP** invariant |
| `VectorDimensionTests` | cosine-not-L2 ordering; `vector`+HNSW (EXPLAIN proves index use) vs `halfvec`; selective-filter full-top-k recall; degenerate vectors |
| `LifecycleDurabilityTests` | 64-way concurrent inserts (FIFO gate, no lost writes); idempotent restart + `kill -9` WAL recovery; APFS cold-snapshot clone is readable |
| `EdgeCaseTests` | keywordSearch degenerate/injection queries (→ `[]`, never throw); NUL-byte rejection + connection survival; dimension-mismatch batch rollback; `openDefault` e2e |

Severe testing found and fixed **three real divergences** before they shipped: a
`$not` absent-key bug (SQL three-valued logic), NaN scores from zero-norm vectors,
and the scientific-notation numeric-coercion gap.

---

## 8. Shipping a signed, notarized bundle (Phase 2)

For distribution (so the store doesn't depend on the user having Homebrew
Postgres), build a **relocatable, Developer-ID-signed, Apple-notarized** bundle:

```sh
scripts/build-embedded-pg-bundle.sh --notarize     # build + sign + notarize + staple
scripts/build-embedded-pg-bundle.sh --sign         # build + sign + functional test (no notary)
scripts/build-embedded-pg-bundle.sh --no-sign      # plain relocatable bundle
```

It re-packages the Homebrew keg into `.build/embedded-pg/embedded-pg/`,
**replicating the prefix-relative layout** so PostgreSQL's own path relocation
finds the bundled, re-signed `pkglibdir` + `sharedir` (this is what makes `initdb`
and `CREATE EXTENSION vector` load the *bundled* modules). Every Mach-O (≈115) is
re-signed under one Team ID with hardened runtime + timestamp, so **library
validation stays ON — no `disable-library-validation` entitlement**. The script
runs a relocated functional test (`initdb` → `CREATE EXTENSION vector` → HNSW) and,
with `--notarize`, produces a Gatekeeper-*accepted* stapled DMG.

Point the store at it:
```sh
CODEX_MEM0_STORE_BACKEND=postgres \
CODEX_MEM0_PG_BINDIR=.build/embedded-pg/embedded-pg/Cellar/postgresql@18/18.4/bin \
  codex-mem0 serve
```
(`PGPaths` already resolves the bundle's relocated `share` dir, so pgvector is
auto-detected.) Signing identity / notary profile are overridable via
`CODEXKIT_SIGN_IDENTITY` / `CODEXKIT_NOTARY_PROFILE`.

## 9. Limitations & roadmap

- **macOS-only**, requires a local or **bundled** (§8) Postgres + pgvector.
- **Single connection** (v1) — all ops serialized. v2: read pool + serialized write.
- **No auto-reconnect** if the postmaster restarts under a live store.
- **`postgresContainer`** backend (Architecture C microVM) is reserved/not wired.
- **In-process native "libpglite" (Architecture A)** — **gate closed**: the
  `postgres-pglite` fork has no native build (Emscripten-only; its "native" path is
  w2c2 WASM-transpilation; the glue `#error`s on non-wasm). The signed bundle (§8)
  is the responsible "as native as possible" endpoint. See `pglite.md` §9.

See [`pglite.md`](../pglite.md) for the full design, risk register, and phased plan.
