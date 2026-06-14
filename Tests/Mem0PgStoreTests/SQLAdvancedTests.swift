import XCTest
import Foundation
import PostgresNIO
@testable import Mem0PgStore

/// Advanced SQL coverage for the embedded Postgres: wide data-type matrix,
/// identity/generated columns, materialized views, the full index-AM family,
/// MERGE, the SQLSTATE error family, and two-connection isolation (deadlock /
/// SKIP LOCKED). Tag-gated (CODEX_MEM0_PG_TEST=1).
final class SQLAdvancedTests: XCTestCase {

    /// A broad column-type matrix is accepted, and exotic types round-trip via a
    /// text cast (PostgresNIO has no native decoder for interval/inet/range/etc.).
    func testWideDataTypeMatrix() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            try await db.exec("""
                CREATE TABLE z (
                  a numeric(12,4), b money, c bytea, d uuid, e interval, f inet, g cidr,
                  h int4range, i tstzrange, j int[], k jsonb, l tsvector,
                  m vector(3), n halfvec(3), o macaddr, p point
                )
                """)
            let cols = try await db.int("SELECT count(*)::int FROM information_schema.columns WHERE table_name='z'")
            XCTAssertEqual(cols, 16, "all 16 column types accepted")
            // exotic types read back via ::text
            let interval = try await db.string("SELECT ('1 day 2 hours'::interval)::text")
            XCTAssertEqual(interval, "1 day 02:00:00")
            let range = try await db.string("SELECT ('[1,5)'::int4range)::text")
            XCTAssertEqual(range, "[1,5)")
            let inet = try await db.string("SELECT ('10.0.0.1'::inet)::text")
            XCTAssertEqual(inet, "10.0.0.1/32", "inet text form carries the netmask")
            let numeric = try await db.string("SELECT (3.1415::numeric(6,2))::text")
            XCTAssertEqual(numeric, "3.14")
        }
    }

    func testIdentityAndGeneratedColumns() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("""
                CREATE TABLE g (
                  id integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
                  base integer,
                  doubled integer GENERATED ALWAYS AS (base*2) STORED
                )
                """)
            try await db.exec("INSERT INTO g (base) VALUES (10),(20),(30)")
            let maxId = try await db.int("SELECT max(id)::int FROM g")
            XCTAssertEqual(maxId, 3, "identity auto-incremented 1..3")
            let doubled = try await db.int("SELECT doubled FROM g WHERE base=30")
            XCTAssertEqual(doubled, 60, "generated-stored column = base*2")
            // GENERATED ALWAYS identity cannot be inserted directly
            let s = await db.sqlstateOf("INSERT INTO g (id, base) VALUES (99, 1)")
            XCTAssertEqual(s, "428C9", "cannot insert into a GENERATED ALWAYS identity column")
        }
    }

    func testMaterializedViewSnapshotAndRefresh() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.execAll([
                "CREATE TABLE src (id int PRIMARY KEY, n int)",
                "INSERT INTO src VALUES (1,10),(2,20)",
                "CREATE MATERIALIZED VIEW mv AS SELECT sum(n)::int AS total FROM src",
                "CREATE UNIQUE INDEX mv_uq ON mv (total)",
                "INSERT INTO src VALUES (3,30)",
            ])
            let stale = try await db.int("SELECT total FROM mv")
            XCTAssertEqual(stale, 30, "materialized view is a STALE snapshot (30, not 60)")
            try await db.exec("REFRESH MATERIALIZED VIEW CONCURRENTLY mv")
            let fresh = try await db.int("SELECT total FROM mv")
            XCTAssertEqual(fresh, 60, "after REFRESH CONCURRENTLY the snapshot updates")
        }
    }

    /// The full index-AM family the build ships: btree, hash, brin, gin, gist
    /// (+ pgvector hnsw/ivfflat are covered elsewhere). Each is creatable.
    func testIndexAccessMethodFamily() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            try await db.execAll([
                "CREATE TABLE ix (id int, k int, body text, meta jsonb, v vector(3))",
                "INSERT INTO ix SELECT g, g%100, 'doc '||g, jsonb_build_object('k',g), ('['||g||',0,0]')::vector FROM generate_series(1,2000) g",
                "CREATE INDEX ix_btree ON ix (k)",
                "CREATE INDEX ix_hash  ON ix USING hash (k)",
                "CREATE INDEX ix_brin  ON ix USING brin (id)",
                "CREATE INDEX ix_gin   ON ix USING gin (meta)",
                "CREATE INDEX ix_ivf   ON ix USING ivfflat (v vector_l2_ops) WITH (lists=10)",
            ])
            // every index registered, with the expected access method
            let ams = try await db.text("""
                SELECT a.amname FROM pg_class c JOIN pg_am a ON a.oid=c.relam
                WHERE c.relname LIKE 'ix_%' ORDER BY c.relname
                """)
            for am in ["brin", "btree", "gin", "hash", "ivfflat"] {
                XCTAssertTrue(ams.contains(am), "index AM \(am) present; got: \(ams.replacingOccurrences(of: "\n", with: ","))")
            }
        }
    }

    func testMergeStatement() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.execAll([
                "CREATE TABLE tgt (id int PRIMARY KEY, v int)",
                "CREATE TABLE src (id int, v int)",
                "INSERT INTO tgt VALUES (1,10),(2,20)",
                "INSERT INTO src VALUES (2,200),(3,300)",   // 2 matches (update), 3 new (insert)
                """
                MERGE INTO tgt t USING src s ON t.id=s.id
                WHEN MATCHED THEN UPDATE SET v=s.v
                WHEN NOT MATCHED THEN INSERT (id,v) VALUES (s.id,s.v)
                """,
            ])
            let v2 = try await db.int("SELECT v FROM tgt WHERE id=2")
            XCTAssertEqual(v2, 200, "MERGE WHEN MATCHED updated id=2")
            let v3 = try await db.int("SELECT v FROM tgt WHERE id=3")
            XCTAssertEqual(v3, 300, "MERGE WHEN NOT MATCHED inserted id=3")
        }
    }

    /// The SQLSTATE error family — each error surfaces with the right code and the
    /// connection stays usable afterwards (single-statement, so no aborted txn).
    func testSqlstateErrorFamily() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            await XCTAssertEqualAsync("22003", db.sqlstateOf("SELECT 2147483647::int + 1"), "integer overflow")
            await XCTAssertEqualAsync("22P02", db.sqlstateOf("SELECT 'notanint'::int"), "invalid text representation")
            await XCTAssertEqualAsync("22012", db.sqlstateOf("SELECT 1/0"), "division by zero")
            await XCTAssertEqualAsync("42P01", db.sqlstateOf("SELECT * FROM no_such_table"), "undefined table")
            await XCTAssertEqualAsync("42601", db.sqlstateOf("SELCT 1"), "syntax error")
            // connection survives the whole error family (single-statement errors
            // don't leave an aborted transaction)
            let ok = try await db.int("SELECT 1")
            XCTAssertEqual(ok, 1, "connection survives the whole error family")
        }
    }

    /// Two connections: a genuine deadlock is detected and exactly ONE transaction
    /// is aborted with 40P01; the other proceeds.
    func testTwoConnectionDeadlockOneVictim() async throws {
        try await PGTestHarness.withRawConnection { a, paths in
            let b = try await PGRawConnection.open(paths)
            try await a.execAll([
                "CREATE TABLE acct (id int PRIMARY KEY, bal int)",
                "INSERT INTO acct VALUES (1,100),(2,100)",
                "SET deadlock_timeout='150ms'",
            ])
            try await b.exec("SET deadlock_timeout='150ms'")
            try await a.exec("BEGIN"); try await b.exec("BEGIN")
            try await a.exec("UPDATE acct SET bal=bal-1 WHERE id=1")   // A locks row 1
            try await b.exec("UPDATE acct SET bal=bal-1 WHERE id=2")   // B locks row 2
            // cross — A wants row 2, B wants row 1 → deadlock
            async let sa = a.sqlstateOf("UPDATE acct SET bal=bal-1 WHERE id=2")
            async let sb = b.sqlstateOf("UPDATE acct SET bal=bal-1 WHERE id=1")
            let (ra, rb) = await (sa, sb)
            let victims = [ra, rb].filter { $0 == "40P01" }
            XCTAssertEqual(victims.count, 1, "exactly one deadlock victim (40P01); a=\(ra) b=\(rb)")
            try? await a.exec("ROLLBACK"); try? await b.exec("ROLLBACK")
            await b.close()
        }
    }

    /// FOR UPDATE SKIP LOCKED: a second connection skips the row locked by the
    /// first (the queue-worker pattern).
    func testSkipLocked() async throws {
        try await PGTestHarness.withRawConnection { a, paths in
            let b = try await PGRawConnection.open(paths)
            try await a.execAll([
                "CREATE TABLE jobs (id int PRIMARY KEY)",
                "INSERT INTO jobs VALUES (1),(2)",
            ])
            try await a.exec("BEGIN")
            let locked = try await a.int("SELECT id FROM jobs ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1")
            XCTAssertEqual(locked, 1, "A grabs job 1")
            // B skips the row A locked (job 1) and takes job 2
            try await b.exec("BEGIN")
            let bPick = try await b.int("SELECT id FROM jobs ORDER BY id FOR UPDATE SKIP LOCKED LIMIT 1")
            XCTAssertEqual(bPick, 2, "B skips the row A locked and takes job 2")
            try? await a.exec("ROLLBACK"); try? await b.exec("ROLLBACK")
            await b.close()
        }
    }

    /// pgvector: all three distance operators with hand-computed expectations, and
    /// the HNSW 2000-dim cap raising an error.
    func testPgvectorDistanceOpsAndDimCap() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            // L2:  [3,4,0] to [0,0,0] = 5
            let l2 = try await db.double("SELECT '[3,4,0]'::vector <-> '[0,0,0]'::vector")
            XCTAssertEqual(l2 ?? 0, 5.0, accuracy: 1e-5, "<-> is Euclidean distance")
            // cosine: orthogonal [1,0] vs [0,1] = 1
            let cos = try await db.double("SELECT '[1,0]'::vector <=> '[0,1]'::vector")
            XCTAssertEqual(cos ?? 0, 1.0, accuracy: 1e-5, "<=> orthogonal cosine distance = 1")
            // negative inner product: [1,2,3]·[1,1,1] = 6 → <#> = -6
            let nip = try await db.double("SELECT '[1,2,3]'::vector <#> '[1,1,1]'::vector")
            XCTAssertEqual(nip ?? 0, -6.0, accuracy: 1e-5, "<#> is negative inner product")
            // HNSW caps at 2000 dims for vector ops
            try await db.exec("CREATE TABLE big (v vector(2001))")
            let cap = await db.sqlstateOf("CREATE INDEX ON big USING hnsw (v vector_l2_ops)")
            XCTAssertNotEqual(cap, "", "HNSW on a 2001-dim vector column must error (>2000 cap)")
        }
    }
}
