import XCTest
import Foundation
import PostgresNIO
@testable import Mem0PgStore

/// Proves the embedded Postgres supports the full SQL surface — DDL, DML, joins,
/// CTEs, window functions, transactions, data types, constraints, and indexes —
/// driven through a raw PostgresNIO connection. Tag-gated (CODEX_MEM0_PG_TEST=1).
final class SQLCapabilityTests: XCTestCase {

    // MARK: DDL + DML + queries

    func testCreateInsertSelectJoinAggregate() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.execAll([
                "CREATE TABLE authors (id int PRIMARY KEY, name text NOT NULL)",
                "CREATE TABLE books (id int PRIMARY KEY, author_id int REFERENCES authors(id), title text, year int)",
                "INSERT INTO authors VALUES (1,'Ada'),(2,'Alan')",
                "INSERT INTO books VALUES (10,1,'Notes',1843),(11,1,'Engine',1842),(12,2,'Machinery',1936)",
            ])
            // inner join + aggregate + group by + having
            let n = try await db.int("""
                SELECT count(*) FROM (
                  SELECT a.name, count(*) c FROM authors a JOIN books b ON b.author_id=a.id
                  GROUP BY a.name HAVING count(*) >= 2
                ) s
                """)
            XCTAssertEqual(n, 1, "Ada has 2 books, Alan 1 → one group passes HAVING>=2")
            // left join keeps authors with no books
            try await db.exec("INSERT INTO authors VALUES (3,'Grace')")
            let authorsWithCounts = try await db.rowCount(
                "SELECT a.id, count(b.id) FROM authors a LEFT JOIN books b ON b.author_id=a.id GROUP BY a.id")
            XCTAssertEqual(authorsWithCounts, 3)
        }
    }

    func testWindowFunctionsAndCTE() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.execAll([
                "CREATE TABLE sales (region text, amount int)",
                "INSERT INTO sales VALUES ('w',10),('w',30),('e',20),('e',5)",
            ])
            // window: rank within region; assert the top region-w amount ranks 1
            let topW = try await db.int("""
                SELECT amount FROM (
                  SELECT amount, rank() OVER (PARTITION BY region ORDER BY amount DESC) r
                  FROM sales WHERE region='w'
                ) s WHERE r=1
                """)
            XCTAssertEqual(topW, 30)
            // recursive CTE: 1..5 sum = 15
            let sum = try await db.int("""
                WITH RECURSIVE t(n) AS (SELECT 1 UNION ALL SELECT n+1 FROM t WHERE n<5)
                SELECT sum(n)::int FROM t
                """)
            XCTAssertEqual(sum, 15)
        }
    }

    func testUpsertAndReturning() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE TABLE kv (k text PRIMARY KEY, v int)")
            try await db.exec("INSERT INTO kv VALUES ('a',1)")
            // ON CONFLICT DO UPDATE + RETURNING
            let v = try await db.int("INSERT INTO kv VALUES ('a',5) ON CONFLICT (k) DO UPDATE SET v=kv.v+excluded.v RETURNING v")
            XCTAssertEqual(v, 6, "1 + 5 via ON CONFLICT DO UPDATE")
        }
    }

    // MARK: transactions

    func testTransactionRollbackAndSavepoint() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE TABLE t (id int)")
            try await db.exec("BEGIN")
            try await db.exec("INSERT INTO t VALUES (1)")
            try await db.exec("SAVEPOINT sp")
            try await db.exec("INSERT INTO t VALUES (2)")
            try await db.exec("ROLLBACK TO sp")          // undoes the 2
            try await db.exec("COMMIT")
            try await XCTAssertEqualAsync(1, db.int("SELECT count(*)::int FROM t"), "savepoint rollback kept only row 1")
            try await XCTAssertEqualAsync(1, db.int("SELECT id FROM t"))
        }
    }

    // MARK: data types (round-trip through PostgresNIO)

    func testDataTypeRoundTrips() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await XCTAssertEqualAsync(Int(Int64.max), db.int("SELECT 9223372036854775807::bigint"))
            try await XCTAssertEqualAsync(3.5, db.double("SELECT 3.5::double precision"))
            try await XCTAssertEqualAsync(true, db.bool("SELECT true"))
            try await XCTAssertEqualAsync("naïve café 𝕏 🔥", db.string("SELECT 'naïve café 𝕏 🔥'"))
            try await XCTAssertEqualAsync("[1, 2]", db.string("SELECT '{\"a\":[1,2]}'::jsonb ->> 'a'"))
            try await XCTAssertEqualAsync(20, db.int("SELECT ('{10,20,30}'::int[])[2]"))
            try await XCTAssertEqualAsync("11111111-1111-1111-1111-111111111111",
                                          db.string("SELECT '11111111-1111-1111-1111-111111111111'::uuid"))
            try await XCTAssertEqualAsync(true, db.bool("SELECT '{\"x\":1}'::jsonb @> '{\"x\":1}'"))
            try await XCTAssertEqualAsync(true, db.bool("SELECT 20 = ANY('{10,20}'::int[])"))
        }
    }

    // MARK: constraints → SQLSTATE

    func testConstraintViolationsRaiseSqlstate() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.execAll([
                "CREATE TABLE p (id int PRIMARY KEY, age int CHECK (age >= 0), email text UNIQUE NOT NULL)",
                "INSERT INTO p VALUES (1, 30, 'a@x')",
            ])
            try await XCTAssertEqualAsync("23505", db.expectError("INSERT INTO p VALUES (1, 1, 'b@x')", "dup PK"))
            try await XCTAssertEqualAsync("23505", db.expectError("INSERT INTO p VALUES (2, 1, 'a@x')", "dup unique email"))
            try await XCTAssertEqualAsync("23514", db.expectError("INSERT INTO p VALUES (3, -1, 'c@x')", "check violation"))
            try await XCTAssertEqualAsync("23502", db.expectError("INSERT INTO p VALUES (4, 1, NULL)", "not null"))
        }
    }

    // MARK: PL/pgSQL function + trigger

    func testPlpgsqlFunctionAndTrigger() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("""
                CREATE FUNCTION add(a int, b int) RETURNS int LANGUAGE plpgsql AS $$
                BEGIN RETURN a + b; END $$
                """)
            try await XCTAssertEqualAsync(42, db.int("SELECT add(40,2)"))
            // trigger that stamps a column on insert
            try await db.execAll([
                "CREATE TABLE audited (id int, tag text)",
                """
                CREATE FUNCTION stamp() RETURNS trigger LANGUAGE plpgsql AS $$
                BEGIN NEW.tag := 'stamped'; RETURN NEW; END $$
                """,
                "CREATE TRIGGER trg BEFORE INSERT ON audited FOR EACH ROW EXECUTE FUNCTION stamp()",
                "INSERT INTO audited (id) VALUES (1)",
            ])
            try await XCTAssertEqualAsync("stamped", db.string("SELECT tag FROM audited WHERE id=1"))
        }
    }

    // MARK: indexes (btree / gin / hnsw) + EXPLAIN proves usage

    func testIndexesAndExplainUsesThem() async throws {
        try await PGTestHarness.withRawConnection { db, _ in
            try await db.exec("CREATE EXTENSION IF NOT EXISTS vector")
            try await db.execAll([
                "CREATE TABLE docs (id int, meta jsonb, v vector(3))",
                "INSERT INTO docs SELECT g, jsonb_build_object('k', g), ('['||g||',0,0]')::vector FROM generate_series(1,500) g",
                "CREATE INDEX docs_meta_gin ON docs USING gin (meta)",
                // L2 ops so the [g,0,0] vectors are DISTINCT points (cosine would
                // tie them all — they're parallel); row 1 = [1,0,0] is the unique
                // nearest to the query (distance 0).
                "CREATE INDEX docs_v_hnsw ON docs USING hnsw (v vector_l2_ops)",
                "ANALYZE docs",
            ])
            try await db.exec("SET enable_seqscan=off")   // force the planner to consider indexes on the small table
            // gin index used for jsonb containment
            let ginPlan = try await db.text("EXPLAIN SELECT id FROM docs WHERE meta @> '{\"k\":42}'")
            XCTAssertTrue(ginPlan.contains("docs_meta_gin"), "gin index expected; plan:\n\(ginPlan)")
            // hnsw used for nearest-neighbour
            let hnswPlan = try await db.text("EXPLAIN SELECT id FROM docs ORDER BY v <-> '[1,0,0]' LIMIT 1")
            XCTAssertTrue(hnswPlan.contains("docs_v_hnsw"), "hnsw index expected; plan:\n\(hnswPlan)")
            let nn = try await db.int("SELECT id FROM docs ORDER BY v <-> '[1,0,0]' LIMIT 1")
            XCTAssertEqual(nn, 1, "nearest (L2) to [1,0,0] is row 1 = [1,0,0], distance 0")
        }
    }
}
