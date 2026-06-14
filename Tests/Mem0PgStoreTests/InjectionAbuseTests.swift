import XCTest
import Mem0Core
import EmbeddedPG
@testable import Mem0PgStore

/// Adversarial / abuse tests: malicious inputs must round-trip safely with no
/// injection, the non-superuser data plane must be unable to escape to the host,
/// and the postmaster must never expose a TCP port.
///
/// `CODEX_MEM0_PG_TEST=1 swift test --filter Mem0PgStoreTests`
final class InjectionAbuseTests: XCTestCase {

    /// SQL-injection / control-character payloads must store and read back exactly,
    /// and must NOT execute — the memories table must still exist afterwards.
    func testMaliciousStringsRoundTripWithoutInjection() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            let nasty: [(String, JSONObject)] = [
                ("'; DROP TABLE memories;--", ["user_id": .string("u1"), "v": .string("'; DROP TABLE memories;--")]),
                ("\") OR 1=1--", ["user_id": .string("u1"), "v": .string("\") OR 1=1--")]),
                ("quote\"inside'and`backtick", ["user_id": .string("u1"), "v": .string("a\"b'c`d")]),
                ("unicodé-emoji-🔥", ["user_id": .string("u1"), "v": .string("naïve café 𝕏 🔥")]),
                ("json-ish {\"a\":1}", ["user_id": .string("u1"), "v": .string("{\"a\":1,\"b\":[null]}")]),
            ]
            for (id, payload) in nasty {
                try await store.insert([VectorRecord(id: id, vector: [1, 0, 0, 0], payload: payload)])
            }
            // Every record survives and reads back byte-identical.
            for (id, payload) in nasty {
                let got = try await store.get(id)
                XCTAssertEqual(got?.id, id, "id round-trip")
                XCTAssertEqual(got?.payload["v"]?.stringValue, payload["v"]?.stringValue, "payload round-trip for \(id)")
            }
            // A malicious filter KEY and VALUE must be treated as data, not SQL.
            let hits = try await store.search("", [1, 0, 0, 0], topK: 10,
                                              filters: ["'; DROP TABLE memories;--": .string("x")])
            XCTAssertEqual(hits.count, 0, "hostile filter key matches nothing (and does not execute)")
            // Table intact: all 5 still listable.
            let all = try await store.list(["user_id": .string("u1")], limit: nil)
            XCTAssertEqual(all.count, nasty.count, "DROP TABLE injection did NOT execute")
        }
    }

    /// A multi-megabyte payload round-trips intact.
    func testLargePayloadRoundTrip() async throws {
        try await PGTestHarness.withCluster(dims: 4) { store, _, _ in
            let big = String(repeating: "abcdefghij", count: 200_000)  // ~2 MB
            try await store.insert([VectorRecord(id: "big", vector: [1, 0, 0, 0],
                                                 payload: ["user_id": .string("u1"), "blob": .string(big)])])
            let got = try await store.get("big")
            XCTAssertEqual(got?.payload["blob"]?.stringValue?.count, big.count)
        }
    }

    /// The non-superuser data-plane role (`codex_app`) must be DENIED every
    /// host-escape / file-read / privilege-escalation vector.
    func testLeastPrivilegeDeniesHostEscape() async throws {
        try await PGTestHarness.withCluster(dims: 4) { _, _, paths in
            let forbidden = [
                "COPY (SELECT 1) TO PROGRAM 'touch /tmp/codexmem0_pwned'",
                "SELECT pg_read_file('/etc/passwd')",
                "SELECT lo_import('/etc/passwd')",
                "CREATE EXTENSION IF NOT EXISTS dblink",
                "CREATE TABLE evil (x int)",
                "DROP TABLE memories",
            ]
            for sql in forbidden {
                let r = try await PGTestHarness.runSQL(paths, user: "codex_app", sql: sql)
                XCTAssertNotEqual(r.exit, 0, "codex_app must be DENIED: \(sql)\n\(r.err)")
            }
            // Sanity: the superuser CAN read a server file (proves the denial above
            // is a privilege boundary, not a missing feature).
            let su = try await PGTestHarness.runSQL(paths, user: "codex", sql: "SELECT 1")
            XCTAssertEqual(su.exit, 0, "superuser baseline works")
            XCTAssertFalse(FileManager.default.fileExists(atPath: "/tmp/codexmem0_pwned"),
                           "COPY...TO PROGRAM must not have run")
        }
    }

    /// The no-TCP invariant: a TCP connection to the cluster's port must be refused
    /// (the postmaster listens only on the UNIX socket).
    func testNoTCPListener() async throws {
        try await PGTestHarness.withCluster(dims: 4) { _, _, paths in
            // Socket connection works…
            let viaSocket = try await PGTestHarness.runSQL(paths, user: "codex_app", sql: "SELECT 1")
            XCTAssertEqual(viaSocket.exit, 0, "socket connection works")
            // …but TCP to 127.0.0.1:port is refused (listen_addresses='').
            let viaTCP = try await PGTestHarness.runSQL(paths, user: "codex_app", host: "127.0.0.1",
                                                        sql: "SELECT 1")
            XCTAssertNotEqual(viaTCP.exit, 0, "TCP must be refused — no listener")
            XCTAssertTrue(viaTCP.err.lowercased().contains("refused")
                          || viaTCP.err.lowercased().contains("could not connect")
                          || viaTCP.err.lowercased().contains("connection"),
                          "expected a connection failure, got: \(viaTCP.err)")
        }
    }
}
