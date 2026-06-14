# Embedded Postgres for codex-swift — Design & Implementation Plan

> **Scope.** Add an embedded Postgres + **pgvector** backend to the Mem0/Memory
> store, *as native as possible* on macOS 26 (Tahoe, arm64), with seamless Swift
> integration, leveraging Tahoe-specific capabilities. Study basis:
> `../pglite` (Postgres-in-WASM) and our own store layer.
>
> **Status (2026-06-14):**
> - **Phase 0 + 1 — IMPLEMENTED & committed.** Opt-in embedded-Postgres + pgvector
>   store, validated against real PG 18.4 + pgvector 0.8.2. Guide:
>   [`docs/MEM0_POSTGRES.md`](docs/MEM0_POSTGRES.md).
> - **Phase 2 — DONE.** `scripts/build-embedded-pg-bundle.sh` produces a
>   **relocatable, Developer-ID-signed, hardened-runtime, Apple-notarized +
>   stapled** PG+pgvector bundle (Gatekeeper: *accepted, Notarized Developer ID*;
>   library validation stays ON — all 115 Mach-O re-signed under one Team). The
>   `codex-mem0` store auto-uses it via `CODEX_MEM0_PG_BINDIR`.
> - **Phase 3 — GATE CLOSED (Spike 11).** The `postgres-pglite` fork has **no
>   native build**: `build.sh` is Emscripten-only (`CC=emcc`), its "native" path
>   is w2c2 WASM→C transpilation, and the glue literally `#error "sigsetjmp
>   unsupported"`s on non-Emscripten/wasi. A true native `libpglite` would mean
>   inventing the native build (the 10–20 wk+ risk this plan flagged) and would
>   *still* be single-user — strictly worse than the shipped Phase 2. See §9.
>
> Default behaviour is unchanged (sqlite-vec) throughout.

---

## 0. TL;DR

| | |
|---|---|
| **Recommended ship target** | **Architecture B — a managed, native arm64 PostgreSQL run as a supervised child process**, bound *only* to a UNIX-domain socket (`listen_addresses=''`), driven from Swift over **PostgresNIO**, behind a new `Mem0StoreBackend` selector. |
| **Default (unchanged)** | **sqlite-vec stays the default and the cross-platform fallback** (`Sources/Mem0Store/Mem0SQLiteStore.swift`). Postgres is opt-in. |
| **The literal "native pglite"** | **Architecture A — an in-process, statically-linked single-user Postgres (the PGlite mechanism, compiled to Mach-O instead of WASM)** is kept as a fully-specced **north-star / Phase 3 stretch**, *gated* on first proving a native build path exists. |
| **Why not A first** | The brief says "no Emscripten/WASM," which points at A — but A is not the *responsible* primary today (see §2). It is reframed as "native as is responsible": **real arm64 Postgres binaries, full WAL/autovacuum/HNSW/crash-isolation, even if out-of-process, beats a forked in-process single-user backend that lacks durability autonomy.** |
| **Headline macOS 26 trick** | **APFS `clonefile()` / `copyfile(COPYFILE_CLONE)` of `PGDATA`** → near-instant, near-zero-space, WAL-consistent database snapshots / branch-a-database / instant test fixtures. A native-only capability the WASM lane cannot offer — and it retro-fits the sqlite-vec lane too. The helper already exists at `Sources/BenchKit/Workspace.swift:50`. |
| **Effort** | Phase 0 (de-risk + seam): ~1 wk · Phase 1 (quick win, local PG): ~2–3 wk · Phase 2 (ship: relocatable + signed bundle): ~3–7 wk · Phase 3 (native A, optional): ~10–20 wk, gated. |

---

## 1. How PGlite actually embeds Postgres (what "native pglite" would mean)

PGlite is **PostgreSQL 17.4 compiled to WASM via Emscripten** from a patched fork
(`postgres-pglite`, branches `REL_17_4_WASM` / `REL_17_4_WASM-pglite`). The
TypeScript package `@electric-sql/pglite` is *just a client* that drives a
**single-user, in-process backend over the Postgres wire protocol through
in-memory buffers** — no postmaster, no `fork`, no socket.

**The C surface the JS drives** (`../pglite/packages/pglite/src/postgresMod.ts:31-66`),
~20 symbols, grouped by role:

| Role | Symbols |
|---|---|
| Lifecycle / startup | `_pgl_startPGlite`, `_pgl_setPGliteActive`, `_pgl_getMyProcPort`, `callMain` |
| Wire I/O callbacks | `_pgl_set_rw_cbs(read_cb, write_cb)` |
| Main-loop single step | `_PostgresMainLoopOnce` |
| Error recovery | `_PostgresMainLongJmp` |
| Flush / buffer | `_pgl_pq_flush`, `_pq_buffer_remaining_data`, `_PostgresSendReadyForQueryIfNecessary` |
| Startup packet | `_ProcessStartupPacket`, `_pgl_sendConnData` |
| `system()`/`popen` stubs | `_pgl_set_system_fn`, `_pgl_set_popen_fn`, `_pgl_set_pclose_fn`, `_pgl_set_pipe_fn`, `_pgl_freopen` |
| Shutdown | `_pgl_run_atexit_funcs`, `_pgl_proc_exit` |
| Tx-state query | `_IsTransactionBlock` |

**The execution loop** (`../pglite/packages/pglite/src/pglite.ts:876-945`): the
client stages a wire-protocol message into a buffer, then calls
`_PostgresMainLoopOnce()` repeatedly until `_pq_buffer_remaining_data() == 0`,
catching the error `siglongjmp` (code `100`) and calling `_PostgresMainLongJmp()`
to recover, then `_PostgresSendReadyForQueryIfNecessary()` + `_pgl_pq_flush()`.

**The in-memory "socket" is trivial** (`../pglite/packages/pglite/src/pglite.ts:676-742`):
`read_cb`/`write_cb` are nothing but `memcpy` between a JS buffer and the WASM
heap. Natively these become **two C function pointers memcpy-ing between a Swift
buffer and the backend's `pq` buffer** — zero serialization, no socket.

**The patch taxonomy** applied to upstream Postgres to make it embeddable:

| Patch | Purpose | Portable to native arm64? |
|---|---|---|
| (a) Re-entrant single-step `PostgresMain` | step one query without returning | ✅ portable |
| (b) Socket layer → `read_cb`/`write_cb` shim (`secure_read`/`secure_write`) | in-memory wire | ✅ portable |
| (c) Postmaster/`fork` elimination → `--single` mode | one backend | ✅ portable (stock PG feature) |
| (d) `setjmp`/`longjmp` error recovery instead of process exit | survive query errors | ✅ portable |
| (e) `proc_exit`/`atexit` interception | don't tear down the host | ✅ portable |
| (f) Global-state reset for re-entrancy (`_pgl_setPGliteActive`) | reuse the backend across queries | ✅ portable |
| `_pgl_freopen`, `HEAPU8`/`HEAP8` access, `FS.createPreloadedFile`, `noExitRuntime` | Emscripten plumbing | ❌ Emscripten-specific — replace with `dup2`/`freopen`, direct pointers, `mmap`, thread-local state |

**Hard limits of the single-user model** (these are why A is a stretch, not the
ship target):
- **One connection. No concurrent backends.** No parallel-query workers.
- **No background workers** — no `autovacuum`, `checkpointer`, `bgwriter`,
  `walwriter`, stats collector (`max_worker_processes=0`).
- **`fsync` is OFF by default** — PGlite passes `-F` verbatim
  (`../pglite/packages/pglite/src/pglite.ts:128`), and its on-disk `syncToFs`
  hook is a no-op. Durability becomes the app's job.
- `LISTEN`/`NOTIFY` are in-process only; `relaxedDurability` trades safety for speed.

**`initdb`** runs as a *separate* WASM module that `system()`-callbacks back into
the main module to create `PGDATA`, which is then tar-dumped and loaded
(`../pglite/packages/pglite/src/initdb.ts:47-210`). Natively this is just running
the real `initdb` binary once.

**The decisive finding:** the `postgres-pglite` submodule is **empty in the local
checkout** (`../pglite/.gitmodules`, SHA `-956441b…`; the leading `-` = un-initialised),
its only documented build is the Dockerised Emscripten pipeline
(`./build-with-docker.sh`, `../pglite/package.json:27`), and upstream tells you to
**download prebuilt WASM artifacts** rather than build. **There is no native
Mach-O target to fork.** So "native pglite" (Architecture A) is *invent a build
path upstream neither provides nor tests* — not *fork & maintain an existing one*.
That single fact reshapes the recommendation.

---

## 2. The central tension, reconciled

The brief literally says *"as native code as possible … leveraging macOS 26 … in
pglite.md"* — which points at **Architecture A** (in-process native Postgres). We
take that seriously and spec A in full (§9). But A is **not** the responsible
*primary*, for three verified reasons:

1. **No native build path exists** to fork (§1) — A's effort estimate (10–20 wk)
   is *on top of* an unbounded "invent the build" unknown.
2. **Single-user mode is a durability regression** versus today's SQLite
   (`synchronous=FULL`): no `autovacuum`/`checkpointer`/`walwriter`, `fsync` off
   by default. For a *persistent* memory store that must not silently bloat or
   lose data on crash, autonomous maintenance is non-negotiable — and only a real
   postmaster provides it.
3. **An in-process PG `PANIC` takes down codex-swift** — it runs in our address
   space; an `exit()`/`abort()` that escapes the `siglongjmp` path kills the host.

So **"as native as possible" is best read as "as native as is *responsible*":**
native Mach-O arm64 binaries running *full* Postgres, even if out-of-process. That
is **Architecture B**, which delivers the actual prize — **pgvector HNSW at scale,
real concurrency, full durability** — at a fraction of the risk, with **zero fork
maintenance**, and slots in behind our existing seams with **zero engine change**.

A stays the documented north-star (§9), prototyped only *after* B proves the store
API and *after* a gated spike proves a native build is feasible at all.

---

## 3. The four candidate architectures

| Criterion | **A — In-process native PGlite** | **B — Managed native postmaster (child)** ⭐ | **C — Unmodified PG in a Containerization microVM** | **D — PGlite .wasm on WasmKit** |
|---|---|---|---|---|
| **Nativeness** (Mach-O arm64, in-proc) | 9 — true in-process, but a vendored+patched fork that *doesn't exist natively yet* | **7 — real arm64 binaries; loses pts for the socket/process boundary** | 3 — native Swift plumbing, engine is ELF-in-a-guest | 3 — native host, DB runs interpreted bytecode (no JIT) |
| **Seamless Swift integration** | 6 — clean actor, but hand-write a wire codec + single-conn invariant | **8 — drop-in seam conformer, ZERO engine change, NIO already in graph** | 6 — clean client; cold-start + daemon dependency | 5 — clean API, no off-the-shelf Emscripten host |
| **Effort (weeks)** | 10–20 (+ invent native build) | **4–9** | 3–6 | 14–30 |
| **Maintenance / risk** | High — empty/immature fork; `exit()` crashes whole process | **Med — relocatable build + signing (one-time, automatable); no fork** | Med — young framework + CLI parsing; virtiofs PGDATA footgun | Very high — own a Swift Emscripten ABI shim |
| **Extensions (pgvector + ecosystem)** | Good-in-theory — static-link `vector.c`, but `CREATE EXTENSION`'s `dlopen` has nothing to open → needs an fmgr patch | **Best — stock PGXS `CREATE EXTENSION vector`; HNSW+IVFFlat; pg_trgm/tsvector/PostGIS free** | Best — stock Linux image, every extension via apt | Strong-in-principle, but needs WasmKit Emscripten `dlopen` (unverified) |
| **Durability + concurrency** | Weak — single-user, no bg workers, `fsync` off; crash-on-reopen unproven | **Strong — full WAL+autovacuum+checkpointer; read pool + serialized write; crash-isolated** | Strong — full postmaster (PGDATA on ext4 block vol) | Weak — single-user + single-conn + ~10× interpreter tax |
| **macOS 26 leverage** | APFS-clone PGDATA, static-link dodges signing | **APFS clonefile snapshots, os_signpost, SMAppService/launchd supervisor** | *Requires* Tahoe Containerization | Thin — abstracts the OS away |
| **Code-signing surface** | **Best — ONE static Mach-O, existing gate unchanged** | Worst — dozens of dylibs, bottom-up re-sign + notarize whole tree | N/A for the engine (Linux image) | Sidesteps (wasm ships as data) |
| **Footprint** | tens of MB static-linked | ~83 MB → ~30–50 MB trimmed + 520 KB pgvector | ~148 MB image + 1–2 GB VM RAM | ~8.9 MB wasm + 128 MB linear mem |
| **Verdict** | **North-star / Phase-3 stretch** | **⭐ PRIMARY (ship)** | **Postgres-backend FALLBACK** | **Rejected** |

**Why D is rejected outright:** least native *and* highest effort. WasmKit ships
WASI 0.1 only; PGlite is an `emcc MAIN_MODULE` build (not WASI), so you'd
hand-write a Swift Emscripten ABI shim (`emscripten_resize_heap`, `invoke_*`
setjmp/longjmp trampolines, `__syscall_*`, growable indirect table), and its
headline (pgvector HNSW) depends on WasmKit supporting Emscripten `dlopen` of a
wasm side-module — unverified, likely unsupported. And it **self-undercuts**:
codex-swift already embeds JavaScriptCore (with a real WASM JIT) in
`Sources/Workflows` + `Sources/Tools/CodeMode.swift`, which would beat D on its own
portability turf by simply running unmodified PGlite-JS.

---

## 4. Recommended architecture (B) in detail

> **Real arm64 PostgreSQL 17/18 + stock pgvector, run as a supervised child
> process, bound only to a UNIX socket, driven from Swift over PostgresNIO.**

**Validated end-to-end on this machine** (macOS 26.4.1, arm64): `initdb -A trust`
→ socket-only postmaster → `CREATE EXTENSION vector` (0.8.2) → `CREATE INDEX …
USING hnsw (vector vector_cosine_ops)` → correct `<->` ordering, against the
Homebrew PG 18.4 already installed at
`/opt/homebrew/Cellar/postgresql@18/18.4/bin/{postgres,pg_ctl,initdb}`.

### Process model
- **`PGDATA`** at `$CODEX_HOME/mem0/pgdata` (a **local APFS directory** — never a
  virtiofs/network mount; documented fsync-corruption footgun).
- **Socket** under `$CODEX_HOME/mem0/run/` — kept *shallow* to respect the 104-byte
  `sun_path` limit.
- **Spawn:** `postgres -D <pgdata> -k <rundir> -c listen_addresses='' -c
  unix_socket_permissions=0700`. **No TCP listener, ever** (see Security).
- **Supervision:** a `PostgresLifecycle` actor modelled on the supervision state
  machine the repo already owns — `ensureAvailable`/`startDetached`/`stop` via
  `Subprocess` at `Sources/BenchKit/ContainerRuntime.swift:42-90` (the
  general-purpose runner, **not** the Seatbelt tool-sandbox spawn path, which would
  deny PGDATA writes + socket + POSIX shm and break startup).
- **Shutdown:** `SIGTERM`/`atexit` → `CHECKPOINT` then `pg_ctl stop -m fast`;
  stale `postmaster.pid` cleanup + single-instance lock on start.

### Transport
- **PostgresNIO over the UNIX socket** —
  `PostgresConnection.Configuration(unixSocketPath:…)`, password `nil` to pair
  with `initdb -A trust`. SwiftNIO is **already resolved transitively** via
  Hummingbird (`Package.swift:67-86`), so adding `vapor/postgres-nio` is
  incremental, not a new NIO major.

### Security invariants (enforced, not assumed)
- **No TCP.** `listen_addresses=''` is a *config*, not an invariant — so make it a
  **tested** invariant: readiness probe asserts `SHOW listen_addresses == ''` **and**
  no OS-visible TCP listener before declaring ready; strip `postgresql.auto.conf`
  overrides on start.
- **Least-privilege data-plane role.** Trust-auth over a socket means any local
  process reaching the socket is implicitly superuser-capable → `COPY … TO
  PROGRAM`, `lo_import`, `pg_read_file('/etc/passwd')` become a sandbox-escape +
  egress channel. **Run the data plane as a non-superuser role** with only
  `INSERT/SELECT/UPDATE/DELETE` on the memory tables; reserve superuser for the
  one-time `CREATE EXTENSION`/provisioning step.
- **No SQL injection via filters.** All dynamic *values* go through PostgresNIO
  `$n` bind params; filter *keys* (identifier position, can't be parameterized)
  are validated against a fixed allowlist.

---

## 5. Integration with our codebase

Our store already exposes the exact seam we need. **`Mem0Engine` is a `struct`**
(`Sources/Mem0Core/Mem0Engine.swift:32`) holding `any Mem0VectorStore` + `any
Mem0HistoryStore` (`:39-40`), so a new backend is a **drop-in conformer with zero
engine change** — exactly how `Mem0SQLiteStore` works today.

**The store protocols** (`Sources/Mem0Core/Seams.swift:46,73`):

```swift
public protocol Mem0VectorStore: Sendable {
    func insert(_ records: [VectorRecord]) async throws
    func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit]
    func get(_ id: String) async throws -> SearchHit?
    func update(_ id: String, vector: [Float]?, payload: JSONObject?) async throws
    func delete(_ id: String) async throws
    func list(_ filters: JSONObject, limit: Int?) async throws -> [SearchHit]
    func deleteCol() async throws
    func reset() async throws
    func keywordSearch(_ query: String, topK: Int, filters: JSONObject) async throws -> [SearchHit]?  // default: nil
    func searchBatch(_ queries: [String], _ vectors: [[Float]], topK: Int, filters: JSONObject) async throws -> [[SearchHit]]
}
public protocol Mem0HistoryStore: Sendable { /* addHistory / getHistory / getLastMessages / reset */ }
```

> ⚠️ **`BackendResolution.swift` is the *inference*-backend selector**
> (`local`/`remote`/`mock` for MLX vs OpenAI), **not** a store selector. The
> Postgres store needs a **distinct** selector — see Phase 0.

### This is a genuine upgrade, not a swap
Today's `Mem0SQLiteStore.search()` is **brute-force Swift cosine over the full
in-RAM cache** (`Sources/Mem0Store/Mem0SQLiteStore.swift:322-332`):

```swift
public func search(_ query: String, _ vector: [Float], topK: Int, filters: JSONObject) async throws -> [SearchHit] {
    var idScores = candidates(filters).map { ($0.id, Double(max(cosine(vector, $0.vector), 0))) }
    idScores.sort { $0.1 > $1.1 }
    ...
}
```

pgvector HNSW replaces this with one `ORDER BY vector <=> $1 LIMIT k` that scales
to 100k–1M+ vectors. Embedding dim is **1536** today (`Sources/codex-mem0/main.swift:50`,
env `CODEX_MEM0_EMBEDDING_DIM`), which matches `vector(1536)` exactly.

### Schema (Phase 1)
```sql
CREATE EXTENSION IF NOT EXISTS vector;
CREATE TABLE memories (
    id      text primary key,
    vector  vector(1536),
    payload jsonb
);
CREATE INDEX ON memories USING hnsw (vector vector_cosine_ops);
-- keywordSearch → tsvector/tsquery (own milestone, retires the brute-force BM25
--                 at Mem0SQLiteStore.swift:364)
```
**Dimension guard:** HNSW caps at **2000 dims** for `vector` (4000 for `halfvec`)
— *live-verified*. If `dims > 2000`, use `halfvec(N)` + `halfvec_cosine_ops`, or
refuse with a clear error. Decide the policy *before* writing the schema (Spike 5).

### Concurrency contract (must be explicit)
The engine's read-modify-write sequences (dedup at `Mem0Engine.swift:172-210`,
update at `:287-293`) are **not atomic today** — the per-call actor only serializes
individual store calls. A connection-pooled backend would *expose* that. **v1:
keep WRITES serialized through a single connection; pool READS only** (search/get/
list). This preserves today's semantics exactly. v2 (separately tested): a `UNIQUE`
index + `INSERT … ON CONFLICT` for real atomic dedup.

### Migration
Vectors are stored today as little-endian `[Float]` blobs
(`Mem0SQLiteStore.swift`). **Never byte-map** them into pgvector — round-trip
through pgvector's documented text/binary input format and assert cosine ordering
against a brute-force control.

---

## 6. macOS 26 (Tahoe) leverage, ranked by payoff

| Trick | Payoff | How / caveat |
|---|---|---|
| **APFS copy-on-write `PGDATA` snapshot/fork** (`clonefile` / `COPYFILE_CLONE`) | **Highest** — near-instant, near-zero-space, WAL-consistent snapshots: backups, branch-a-database, instant test fixtures. Native-only; WASM can't. Retro-fits sqlite-vec too. Helper exists: `Sources/BenchKit/Workspace.swift:50`. | `snapshot()` = acquire store lock → `CHECKPOINT` → recursive `copyfile(COPYFILE_CLONE)` of PGDATA → release. **Caveat:** `COPYFILE_RECURSIVE` is per-file *non-atomic* → a live, concurrently-written PGDATA can produce a **torn clone**. Safe only while quiesced; prefer `pg_backup_start/stop` bracketing or an atomic APFS *volume* snapshot. Spike the torn case (Spike 10). |
| **Out-of-process supervision** via SMAppService / launchd (+ XPC handle) | **High** — crash-restart, clean shutdown, no orphaned trust-auth postmasters. **Crash-isolation is the core durability win of B over A.** | Model on `ContainerRuntime.swift:42-90`. Register `SIGTERM`/`atexit` → `CHECKPOINT` + `pg_ctl stop -m fast`. Spawn via a *dedicated non-Seatbelt path* (the tool-sandbox SBPL at `Sources/Sandbox/SeatbeltBasePolicy.swift` would deny PGDATA/socket/shm). |
| **`os_signpost` instrumentation** of store ops | **Medium** — low-overhead Instruments tracing of insert/search/index-build latency; directly answers the concurrency spikes. | Wrap `Mem0PgVectorStore.search/insert` + the HNSW build in `os_signpost` intervals; correlate with `Mem0Engine.swift:118-210`. |
| **Static-link to collapse the signing surface** (A only) | **Medium** — A's one genuine signing advantage: one Mach-O covered by the binary's own signature, no per-dylib notarization, library-validation stays on (exactly the CSQLiteVec `SQLITE_VEC_STATIC` / no-dlopen model, `Package.swift:159-169`). | Statically compile `vector.c` *into* libpglite. **Catch:** `CREATE EXTENSION`'s whole job is to `dlopen MODULE_PATHNAME` — a static build needs fmgr-registration shims (a real patch, not "stock PGXS"). Gate behind Spike 11. |
| **Apple Containerization.framework microVM** (C fallback only) | **Low** for nativeness (ELF-in-a-guest), but lowest *new* engineering to a real postmaster and **sidesteps macOS code-signing of PG entirely** (the engine is a Linux image). Repo already owns the mgmt layer (`ContainerRuntime.swift`). | PGDATA on an **ext4 block volume** (never virtiofs). Loopback `--publish 127.0.0.1:PORT:5432` + **scram-sha-256** (the vmnet IP is routable — trust-auth on TCP is unsafe). Empirically `nmap` the vmnet IP from a second host before trusting isolation. |

---

## 7. Phased implementation plan

### Phase 0 — De-risk + seam plumbing (~1 wk, no behaviour change)
**Goal:** settle the load-bearing unknowns cheaply; add the backend selector.
- Run **Spikes 1–5** (concurrency baseline, no-TCP proof, injection, least-privilege, dimension cap — §10).
- Add a **`Mem0StoreBackend`** enum (`.sqliteVec` default | `.postgres` | `.postgresContainer`) + parser *beside* `Sources/Mem0Core/BackendResolution.swift`, mirroring `Mem0BackendResolver.resolve` (`:26`). Parse `CODEX_MEM0_STORE_BACKEND` in `Sources/codex-mem0/main.swift`; default → `.sqliteVec`.
- Decision memo recording the A-vs-B tradeoff + verified facts.

**Exit:** store-time/total-time ratio measured (Spike 1) · no-TCP + injection defenses validated (Spikes 2–3) · default path builds, all `Mem0StoreTests` green, unset env → identical behaviour · dimension policy decided.

### Phase 1 — Quick win: Postgres store against local Homebrew PG (~2–3 wk)
**Goal:** prove the full pgvector store API + PostgresNIO transport + seam
conformance with the least work, using the PG already installed — **no
relocatability, no signing.**
- **New `EmbeddedPG` target:** `PostgresLifecycle` actor (`initdb -A trust` once · `posix_spawn` socket-only postmaster · readiness probe asserting no-TCP · graceful `CHECKPOINT`+stop · stale-pid cleanup), `PGPaths`, `PGSnapshot` (APFS clone).
- **New `Mem0PgStore` target:** `Mem0PgVectorStore` actor conforming to `Mem0VectorStore` + `Mem0HistoryStore`; HNSW schema (+ dimension guard); bind-param queries; pooled-reads / serialized-write split; non-superuser data-plane role.
- Add `postgres-nio` package; wire `.postgres` into `codex-mem0`; **tag-gated** `Mem0PgStoreTests` reusing the SQLite test cases via the shared protocols.

**Exit:** `CODEX_MEM0_STORE_BACKEND=postgres` → full add/search/get/update/delete/list passes against the spawned PG, equivalent to sqlite-vec · `EXPLAIN` shows an HNSW index scan (not seq scan) · injection + least-privilege tests green · **`Mem0Engine` unchanged** · default + Linux/CI untouched · Spike 6 (HNSW build memory + concurrent reads) run, `maintenance_work_mem` default chosen.

### Phase 2 — Ship: relocatable, signed, bundled PG ✅ DONE
**Built as [`scripts/build-embedded-pg-bundle.sh`](scripts/build-embedded-pg-bundle.sh)** —
produces a relocatable, Developer-ID-signed, hardened-runtime, **Apple-notarized +
stapled** PG 18.4 + pgvector 0.8.2 bundle (Gatekeeper: *accepted, Notarized
Developer ID*).
- **Approach taken:** rather than a from-source build, the script **re-packages
  the Homebrew keg** and **replicates its prefix-relative layout**
  (`Cellar/postgresql@NN/V/bin`, `lib/postgresql@NN`, `share/postgresql@NN`) so
  PostgreSQL's own path relocation (`find_my_exec`) finds the bundled, re-signed
  `pkglibdir` + `sharedir` — which is what makes both `initdb` (`$libdir/dict_snowball`)
  and `CREATE EXTENSION vector` (`$libdir/vector`) load the **bundled** modules.
- A BFS dylib collector (follows `@loader_path` siblings, names by install-name to
  survive Homebrew's version symlinks) bundles 15 shared dylibs; all **115 Mach-O**
  are re-signed under one Team → **library validation stays ON, no entitlement**.
  No LLVM/JIT in the Homebrew build, so no W^X landmine. `pgxs/` (build/test infra
  with stray unsigned exes) is dropped.
- The script's functional test relocates the bundle and runs `initdb` →
  `CREATE EXTENSION vector` → HNSW; the store auto-uses it via `CODEX_MEM0_PG_BINDIR`
  (`PGPaths` already resolves the bundle's relocated share dir).
- **Still TODO for production:** wire the signing into the repo's release gate
  (`g6_developer_id_sign_smoke.sh`); a CVE/patch-rebuild runbook; optional
  from-source `--without-icu` trim. The mechanism is proven end-to-end.

<details><summary>Original plan (superseded by the above)</summary>

**Goal:** turn the proven runtime into a redistributable bundle the app can carry.
- From-source build: `./configure --prefix=<stage> --disable-rpath --without-llvm --with-openssl --with-lz4 --with-zstd` (`--without-llvm` drops JIT → dodges the hardened-runtime W^X landmine + shrinks CVE surface). pgvector matched to the **exact PG major**. Trim `share/` locale+tz to ~30–50 MB.
- **`install_name_tool` `@loader_path` rewrite pass** (stock Homebrew PG hardcodes absolute `/opt/homebrew/opt/{gettext,zstd,lz4}/…` paths — verified via `otool -L`). Assert `otool -L` shows **no** `/opt/homebrew` path survives. **Order matters: rewrite *before* signing** (`install_name_tool` after signing breaks the seal).
- **Signing pipeline:** rewrite the loop in `tools/e2e/g6_developer_id_sign_smoke.sh` + `scripts/codexkit-lifecycle.sh` from **3 hardcoded binaries** to a **recursive Mach-O walk** of the staged PG subtree, signing **deepest-first** under the Developer ID Team cert (`--options runtime --timestamp`); **re-sign `vector.dylib` + every bundled dylib under the same Team** so library validation stays `<false/>` (the release gate *asserts* `disable-library-validation=<false/>`). Notarize + staple the whole tree.
- `PostgresLifecycle` switches to the bundled binary dir; `PGPaths` resolves bundled-vs-Homebrew.
- **CVE/patch runbook:** announce-list watcher · automated rebuild→sign→notarize · minor auto-update · major `pg_upgrade` path.

**Exit:** Spikes 7–9 green (re-signed `vector.dylib` `dlopen`s under library validation · `notarytool` accepts the nested PG tree · relocated copy launches with a valid `--strict` signature) · bundle passes Gatekeeper from a quarantined location on a clean machine · footprint within target · patch pipeline scripted (not manual).

</details>

> **Outcome:** Spikes 7–9 all GREEN. The re-signed `vector.dylib` `dlopen`s under
> library validation, `notarytool` accepted the nested 115-Mach-O tree, the
> relocated copy launches `--strict`-valid, and the stapled DMG is Gatekeeper-
> *accepted*. Footprint ~71 MB (untrimmed).

### Phase 3 — Native ideal (optional north-star): in-process libpglite — GATE CLOSED ❌
**Spike 11 ran and CANCELLED the phase, exactly as gated.** Cloning
`postgres-pglite` (branch `REL_17_4_WASM-pglite`) and reading the build shows:
- `build.sh` is **Emscripten-only** (`BUILD=emscripten`, `CC=$(which emcc)`,
  `-sMAIN_MODULE`). There is **no** `./configure && make` that emits a native
  `libpglite.a`.
- The only "native" path, `native.sh`, takes the WASM output and runs it through
  **w2c2** (a WASM→C transpiler) wrapped as a **Python** module — it still needs
  the full Emscripten/wasi build first and carries every WASM limitation.
- The glue (`interactive_one.c`, `pgl_os.h`, `pgl_sjlj.c`) is wasm-bound:
  `__attribute__((export_name(...)))` exports, `chmod`/`popen` overridden for wasi,
  and `interactive_one.c:574` literally `#error "sigsetjmp unsupported"` for the
  non-Emscripten/wasi case — i.e. the error-recovery longjmp the re-entrant main
  loop needs **does not exist natively**.

A true native `libpglite` therefore means *inventing* the native build (replace
the Emscripten OS/sjlj/export layer, write a native sjlj recovery path, own a
forked PG) — the 10–20 wk+ #1 schedule risk — and it would **still** be single-user
(no autovacuum/checkpointer/walwriter, fsync-off), i.e. strictly worse than the
shipped Phase 2 on durability, concurrency, and maintenance. **Recommendation:
do not pursue;** Phase 2 (real native binaries, full Postgres, notarized) is the
responsible "as native as possible" endpoint. The original spec is kept below for
the record.

<details><summary>Original Phase 3 spec (not pursued — see Spike 11 outcome above)</summary>

**Goal:** the literal "maximally native" in-process Postgres — *only after B ships*
and *only if* the native build path is proven.
- **Spike 11 (GATE):** clone `postgres-pglite`, read `build-with-docker.sh` + the patch series, confirm a native Mach-O target exists. **Absent → the phase is cancelled.**
- **Spike 10:** prove `fsync`-on durability + crash-recovery-on-reopen for the in-process single-user backend (must match/beat the sqlite-vec control).
- **New `CPGlite` C-shim target** mirroring `CSQLiteVec` (`Package.swift:158-170`): static-linked libpglite + pgvector (no `dlopen`, library validation stays on, the 3-binary gate unchanged); a header declaring the ~20-symbol surface (§1).
- Re-target the **same `Mem0PgVectorStore` actor** at the in-process transport (only lifecycle/wire change); add periodic `CHECKPOINT`/`VACUUM` timers + `atexit CHECKPOINT` to replace the missing background workers.

**Exit:** native build reproducible from a clean checkout (documented re-apply recipe, like the MLX `metallib` steps in `CLAUDE.md`) · crash-recovery + `fsync` durability match/beat the sqlite-vec control · same `Mem0PgStore` tests pass against the in-process backend · single static Mach-O signs cleanly under the existing gate with library validation **on**.

</details>

---

## 8. SwiftPM package layout

Three new targets, all `#if os(macOS)`-gated + strict-concurrency
(`Package.swift:16-18`), mirroring the `CSQLiteVec` precedent
(`Package.swift:156-170`). **The C shim is for Phase 3 only** — B compiles only
PostgresNIO + a thin lifecycle actor, **no C in the graph**, so the `.build` lock
and cold-build time stay untouched (important per the "parallel build/test agents
wedge the `.build` lock" caveat).

```text
(1) NEW PACKAGE DEP (Phase 1+):
    .package(url: "https://github.com/vapor/postgres-nio", from: "1.21.0")
    # SwiftNIO already resolved transitively via Hummingbird — incremental.

(2) NEW TARGET  Sources/EmbeddedPG/            (Swift lib, Phase 1+)
      PostgresLifecycle.swift  — actor: initdb-once · socket-only spawn · no-TCP
                                  readiness probe · graceful CHECKPOINT+stop ·
                                  stale-pid cleanup · single-instance lock
      PGPaths.swift            — bundled-vs-Homebrew binary dir; shallow socket dir
      PGSnapshot.swift         — snapshot() = lock → CHECKPOINT →
                                  copyfile(COPYFILE_CLONE|RECURSIVE) → unlock
                                  (engine-agnostic; also wraps the sqlite-vec .db)
      deps: ["InfraPrimitives", .product(name:"PostgresNIO", package:"postgres-nio")]

(3) NEW TARGET  Sources/Mem0PgStore/           (Swift lib, Phase 1+)
      Mem0PgVectorStore.swift  — actor: Mem0VectorStore + Mem0HistoryStore;
                                  HNSW schema (+dimension guard); $n bind params,
                                  key allowlist; pooled READS + serialized WRITE
      Mem0PgError.swift        — SQLSTATE → Mem0Error.database/.notFound
      deps: ["Mem0Core", "EmbeddedPG"]

(4) NEW TARGET  Sources/CPGlite/               (C shim, Phase 3 ONLY)
      mirrors CSQLiteVec exactly (Package.swift:158-170):
        sources: ["pglite_shim.c"], publicHeadersPath: "include",
        cSettings: [.headerSearchPath("include"), -O3 release],
        link the static libpglite archive (isolate as a prebuilt binaryTarget so
        the giant PG compile never holds the app's .build lock)
      include/pglite_shim.h    — declares the ~20-symbol surface (§1)
```

**Wiring:** add `Mem0PgStore` (and later `CPGlite`) to the mem0 executable /
extension target deps + a tag-gated `Mem0PgStoreTests`. **`Mem0Engine` itself
needs zero changes** — pass the same `Mem0PgVectorStore` instance as both
`vectorStore` and `historyStore`, exactly as `Mem0SQLiteStore` does today.

---

## 9. The native north-star (Architecture A), fully specced

If/when Phase 3 proceeds, A is the literal embedded Postgres: **compile the
`postgres-pglite` patch set (or upstream PG17 + the equivalent patches from §1) to
Mach-O arm64**, statically link it + `vector.c` into `libpglite.a`, expose the
~20-symbol surface through `CPGlite`, and drive it from the *same*
`Mem0PgVectorStore` actor over the in-memory wire (a Swift port of
`@electric-sql/pg-protocol`, or PostgresNIO's message coders pointed at the
buffer callbacks instead of a socket).

**A's one genuine win:** signing. A single statically-linked Mach-O is covered by
the binary's own signature — no `dlopen`, no per-dylib notarization, library
validation stays on, the existing 3-binary gate is unchanged.

**A's honest costs (why it stays a stretch):**
- The fork **doesn't exist natively** — Spike 11 must prove a build path before any
  estimate is credible.
- Single-user mode: no `autovacuum`/`checkpointer`/`walwriter`, `fsync` off by
  default → the app must own `CHECKPOINT`/`VACUUM` timers + a real `fsync` barrier
  in the native VFS.
- An in-process PG `PANIC` crashes codex-swift.
- `CREATE EXTENSION`'s `dlopen` has nothing to open in a static build → needs
  fmgr-registration shims (a real patch).

---

## 10. De-risking spikes (ordered)

| # | What | Cost | Gates |
|---|---|---|---|
| **1** | **Concurrency baseline** — `os_signpost` the store calls in the inferred-add path; run a real `import-markdown --extract --concurrency 4`; print store-time / total-wall-time. If **<~15%**, the single-backend concern is moot for this workload (the add path is `embed→search→llm.generate→embedBatch→insert`, `Mem0Engine.swift:118-210` — `llm.generate` dominates). | ½ day | — |
| **2** | **No-TCP proof** — bring up local PG with `-c listen_addresses='' -k <rundir>`; prove `lsof -iTCP -sTCP:LISTEN | grep 5432` is empty, `psql -h 127.0.0.1` refused, `psql -h <socketdir>` works. | ½ day | security |
| **3** | **Injection** — write the filtered-search query with bind params; fire `'; DROP TABLE`, `') OR 1=1--`, null bytes, 10 MB payload at filter values **and keys**. Confirm `$n` neutralizes values + key-allowlist rejects hostile keys. | ½ day | security |
| **4** | **Least-privilege** — create the non-superuser data-plane role; confirm `COPY … TO PROGRAM 'id'`, `CREATE EXTENSION dblink`, `pg_read_file('/etc/passwd')`, `lo_import` are all **denied**. | ½ day | security |
| **5** | **Dimension cap** — reproduce HNSW failing on `vector(2001)`; prove `halfvec(3072)` + `halfvec_cosine_ops` works. Decide the >2000 policy. | 30 min | schema |
| **6** | **Perf** — insert 100k random 1536-d vectors; `CREATE INDEX … hnsw` at `maintenance_work_mem` 64 MB vs 1 GB; time both. Then HNSW `ORDER BY <=> LIMIT k` under K concurrent reads vs the brute-force SQLite actor. | 1–2 hr | sets GUC default |
| **7** | **Library validation** (gates Phase 2) — re-sign Homebrew `vector.dylib` + `postgres` + dylibs under a Dev-ID Team cert `--options runtime`; a `disable-library-validation=<false/>` host spawns it + runs `CREATE EXTENSION vector` → confirm `dlopen` of the Team-re-signed dylib succeeds. | 1 hr | Phase 2 |
| **8** | **Notarization scope** (gates Phase 2) — drop a re-signed `postgres` tree into `g6_developer_id_sign_smoke.sh` and run sign→DMG→`notarytool submit`→staple. Confirm a tree with nested 3rd-party Mach-O is accepted. | 1 hr | Phase 2 |
| **9** | **Relocatability** — `install_name_tool`-rewrite `/opt/homebrew/opt/*` → `@loader_path/../lib`, re-sign, launch from a relocated copy → valid `--strict` signature (proves rewrite-before-sign ordering). | 30 min | Phase 2 |
| **10** | **Durability** (gates Phase 3) — `kill -9` mid-write, reopen PGDATA, assert rows survive + recovery (control: same test on SQLite). Also `copyfile(CLONE|RECURSIVE)` a live PGDATA mid-write → torn-clone check, then the quiesce-then-clone protocol. | ½ day | Phase 3 |
| **11** | **Native-build feasibility** (gates Phase 3 / A) — clone `postgres-pglite`, read `build-with-docker.sh` + patch series: how many hunks, which PG ref, **is there any native target?** Unblocks or kills A. | — | Phase 3 |

---

## 11. Risk register

| Sev | Risk | Mitigation |
|---|---|---|
| **High** | **No native build path for A** — submodule empty, only a Dockerised Emscripten pipeline. | Ship B (stock upstream PG, zero patches). Keep A as a Phase-3 spike **gated** on cloning the submodule + confirming a native target. |
| **High** | **Library-validation collision (B)** — the release gate asserts hardened runtime on + `disable-library-validation=<false/>`. | Re-sign `vector.dylib` + every bundled dylib bottom-up under the same Dev-ID Team cert so library validation stays `<false/>` (Spike 7). |
| **High** | **Notarization scope explosion (B)** — repo signs 3 Mach-O today; PG adds dozens. | Rewrite the signing loop to a recursive deepest-first Mach-O walk; assert no `/opt/homebrew` path survives (Spike 8). |
| **High** | **Durability regression in A** — `-F` (fsync off) + no-op `syncToFs`. | Prefer B (fsync-on + autovacuum + checkpointer + crash-isolation, free). If A: drop `-F`, real `fsync` barrier in the VFS, `CHECKPOINT` timers (Spike 10). |
| **High** | **Torn APFS clone of a live PGDATA** — `COPYFILE_RECURSIVE` is per-file non-atomic. | `snapshot()` holds the store lock for the whole clone (quiesce + `CHECKPOINT`); for postmaster prefer `pg_backup_start/stop` or an atomic APFS *volume* snapshot (Spike 10). |
| **High** | **PG `PANIC` crashes codex-swift (A)** — in-process, shared address space. | Structural cost of in-process embedding — a reason A is a stretch. B's process boundary eliminates it. |
| **High** | **SQL-injection via filters (B/C, new surface)** — filters are Swift-side today. | All values via `$n` bind params; filter keys via a fixed allowlist; adversarial test (Spike 3). |
| **High** | **No *enforced* no-TCP invariant (B)** — config, not invariant. | Spawn with `listen_addresses='' -k <rundir>`; readiness probe asserts no TCP + strips `auto.conf`; tested invariant (Spike 2). |
| **High** | **`COPY…PROGRAM`/`lo_import`/`pg_read_file` = sandbox-escape (B/C)** — trust-auth socket. | Non-superuser data-plane role; superuser only for one-time provisioning (Spike 4). |
| **Med** | **PG CVE / patch cadence for the shipped bundle** — bundling makes you the distributor. | Phase 1 (Homebrew PG) sidesteps it. Phase 2: announce-list watcher + automated rebuild→sign→notarize + minor-auto-update + major `pg_upgrade`. |
| **Med** | **HNSW 2000-dim cap** — "1536 just works" is true today but unguarded. | Dimension guard: >2000 → `halfvec` (cap 4000) or refuse (Spike 5). |
| **Med** | **HNSW build memory** — `maintenance_work_mem` (default 64 MB) → slow on-disk fallback at scale. | `SET maintenance_work_mem` (512 MB–2 GB) per-session before `CREATE INDEX`; expose `CODEX_MEM0_PG_MAINTENANCE_WORK_MEM` (Spike 6). |
| **Med** | **Duplicate-write under a pooled backend** — engine dedup/update aren't atomic today. | v1: serialize writes through one connection (pool reads only). v2: `UNIQUE` index + `INSERT…ON CONFLICT`. |
| **Med** | **`runBlocking` HTTP bridge thread starvation** (pre-existing, backend-agnostic). | Fix independently: bound in-flight concurrency or a real async accept loop — don't blame the PG lane. |
| **Med** | **Vector byte-layout corruption on migration** — LE `[Float]` blobs → pgvector. | Never byte-map; round-trip through pgvector's text/binary format; assert cosine ordering vs a brute-force control. |
| **Med** | **Containerization vmnet TCP exposure (C)** — routable vmnet IP. | Loopback `--publish 127.0.0.1:PORT:5432` only + scram-sha-256 + 256-bit password; `nmap` the vmnet IP from a second host first. |
| **Low** | **`.build` lock contention from a heavy C target.** | B compiles no C. If A: isolate the PG static archive as a prebuilt `binaryTarget`. |
| **Low** | **104-byte `sun_path` / App-Sandbox confusion** — repo doesn't use App Sandbox today. | Keep the socket at a short `$CODEX_HOME/mem0/run/` path; document the limit as a future App-Sandbox concern. Don't over-engineer. |

---

## 12. Open questions

- **What fraction of mem0 wall-clock is store-time vs embed/LLM-time?** The whole
  "single-backend serializes everything" concern is moot if store-time <~15%.
  Measure before justifying B on concurrency grounds (Spike 1).
- **Does A's in-process single-user backend replay WAL and come up consistent
  after a `kill -9` of a dirty PGDATA?** Unverifiable today (submodule empty) —
  the #1 load-bearing unknown for A-as-persistent-store.
- **Can codex-swift's existing Developer ID identity carry a relocatable +
  notarized PG tree**, or does it need new entitlements/process? Verified only from
  Apple docs, not by notarizing the tree.
- **Build PG from source** (`--disable-rpath`, clean/reproducible) **or
  post-process Homebrew binaries** with `install_name_tool`? Recommend: Homebrew
  for the prototype, from-source for shipping.
- **`--with-icu` or `--without-icu`** for the bundle? `--without-icu` shrinks
  footprint + drops a dylib-signing burden; confirm no downstream collation
  dependency.
- **Do we actually need multi-process concurrent access** (the real trigger for
  B-over-sqlite-vec), or is a single connection acceptable?
- **pgvector's exact SQLSTATE codes** from the bundled build → can they map to
  `Mem0Error.database/.notFound` without losing diagnostics?
- **Does the macOS 26.4 vmnet IP (C) stay host-only-reachable**, or LAN-reachable?
  Prove from a second machine before trusting C with any auth model.

---

## Appendix · Key references

**PGlite (`../pglite`)** — `packages/pglite/src/postgresMod.ts:31-66` (C surface) ·
`packages/pglite/src/pglite.ts:676-742` (in-memory wire callbacks), `:876-945`
(exec loop), `:128` (`-F` fsync-off) · `packages/pglite/src/initdb.ts:47-210`
(initdb-in-process) · `.gitmodules` (empty `postgres-pglite` submodule) ·
`package.json:27` (`./build-with-docker.sh`, Emscripten-only).

**codex-swift** — `Sources/Mem0Core/Seams.swift:46,73` (store protocols) ·
`Sources/Mem0Core/Mem0Engine.swift:32,39-40` (struct holding `any` stores) ·
`Sources/Mem0Core/BackendResolution.swift:26` (inference-backend resolver to
mirror) · `Sources/Mem0Store/Mem0SQLiteStore.swift:322-332` (brute-force search),
`:364` (BM25) · `Sources/codex-mem0/main.swift:50` (1536 dims) ·
`Sources/CSQLiteVec/*` + `Package.swift:156-170` (C-target precedent) ·
`Sources/BenchKit/ContainerRuntime.swift:42-90` (supervision shape; C fallback) ·
`Sources/BenchKit/Workspace.swift:50` (`COPYFILE_CLONE` helper) ·
`tools/e2e/g6_developer_id_sign_smoke.sh` + `scripts/codexkit-lifecycle.sh`
(signing gate to extend).

**Verified on this machine** (macOS 26.4.1, arm64): Homebrew PG 18.4 + pgvector
0.8.2 end-to-end (`initdb -A trust` → socket-only postmaster → `CREATE EXTENSION
vector` → HNSW index → correct `<->` ordering); `clonefile.h` + `COPYFILE_CLONE`
present in the SDK; `container` CLI 0.12.3 installed; HNSW 2000-dim cap reproduced.
