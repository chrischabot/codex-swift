#if canImport(CryptoKit)
import XCTest
import Foundation
import CryptoKit
@testable import HarnessCore

/// P5c: persisted, encrypted-at-rest agent metadata (#25721 / #26210).
final class AgentRecordStoreTests: XCTestCase {
    private func tmpFile() -> String {
        let dir = NSTemporaryDirectory() + "agent-store-\(UUID().uuidString)"
        return dir + "/agents.json"
    }

    func testWriteThroughThenHydrateSurvivesRestart() async throws {
        let path = tmpFile()
        let key = SymmetricKey(size: .bits256)
        let p = AgentPath.root.child("worker-1")

        // First "process": write through a store.
        let store1 = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg1 = AgentRegistry(store: store1)
        try await reg1.reserve(p, parent: .root)
        await reg1.setResult(p, output: "the secret answer is 42",
                             error: nil, status: .completed)

        // Second "process": a fresh registry with a store over the same file,
        // hydrated from disk, must resurface the record + its decrypted payload.
        let store2 = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg2 = AgentRegistry(store: store2)
        await reg2.hydrate()
        let rec = await reg2.get(p)
        XCTAssertNotNil(rec, "record must survive a restart")
        XCTAssertEqual(rec?.status, .completed)
        XCTAssertEqual(rec?.result, "the secret answer is 42")
    }

    func testPayloadIsEncryptedAtRest() async throws {
        let path = tmpFile()
        let key = SymmetricKey(size: .bits256)
        let p = AgentPath.root.child("worker-2")
        let secret = "TOP-SECRET-PLAINTEXT-MARKER"

        let store = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg = AgentRegistry(store: store)
        try await reg.reserve(p, parent: .root)
        await reg.setResult(p, output: secret, error: nil, status: .completed)

        // The raw bytes on disk must NOT contain the plaintext payload.
        let raw = try Data(contentsOf: URL(fileURLWithPath: path))
        let text = String(data: raw, encoding: .utf8) ?? ""
        XCTAssertFalse(text.contains(secret),
                       "result payload must be sealed, not stored in cleartext")
        // But routing metadata (the path) stays in clear.
        XCTAssertTrue(text.contains("worker-2"), "path metadata is cleartext")
    }

    func testWrongKeyCannotDecrypt() async throws {
        let path = tmpFile()
        let p = AgentPath.root.child("worker-3")
        let storeA = EncryptedFileAgentRecordStore(path: path, key: SymmetricKey(size: .bits256))
        let regA = AgentRegistry(store: storeA)
        try await regA.reserve(p, parent: .root)
        await regA.setResult(p, output: "classified", error: nil, status: .completed)

        // A store opened with a DIFFERENT key cannot recover the payload
        // (the record metadata still loads; the sealed field decrypts to nil).
        let storeB = EncryptedFileAgentRecordStore(path: path, key: SymmetricKey(size: .bits256))
        let regB = AgentRegistry(store: storeB)
        await regB.hydrate()
        let rec = await regB.get(p)
        XCTAssertNotNil(rec, "metadata still loads under the wrong key")
        XCTAssertNil(rec?.result, "payload must not decrypt under the wrong key")
    }

    func testFileStays0600AcrossMultipleWrites() async throws {
        // Review finding #1: replaceItemAt preserves the destination's perms, so
        // 0600 must be re-asserted on the final path on EVERY write, not just the
        // first. Write twice and confirm the perms stay 0600.
        let path = tmpFile()
        let key = SymmetricKey(size: .bits256)
        let store = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg = AgentRegistry(store: store)
        try await reg.reserve(AgentPath.root.child("a"), parent: .root)
        try await reg.reserve(AgentPath.root.child("b"), parent: .root)   // second write
        let attrs = try FileManager.default.attributesOfItem(atPath: path)
        let perms = (attrs[.posixPermissions] as? NSNumber)?.intValue ?? -1
        XCTAssertEqual(perms, 0o600, "records file must stay 0600 across writes")
    }

    func testCorruptFileIsPreservedNotSilentlyDiscarded() async throws {
        // Review finding #7: a corrupt file must be moved aside, not silently
        // obliterated by the next put.
        let path = tmpFile()
        let key = SymmetricKey(size: .bits256)
        try FileManager.default.createDirectory(
            atPath: (path as NSString).deletingLastPathComponent,
            withIntermediateDirectories: true)
        try Data("{ this is not valid json".utf8).write(to: URL(fileURLWithPath: path))

        let store = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg = AgentRegistry(store: store)
        try await reg.reserve(AgentPath.root.child("fresh"), parent: .root)

        // A .corrupt-<pid> sidecar must exist next to the (now rewritten) file.
        let dir = (path as NSString).deletingLastPathComponent
        let siblings = (try? FileManager.default.contentsOfDirectory(atPath: dir)) ?? []
        XCTAssertTrue(siblings.contains { $0.contains("corrupt") },
                      "corrupt file must be preserved as a sidecar: \(siblings)")
    }

    func testRemoveDeletesFromDisk() async throws {
        let path = tmpFile()
        let key = SymmetricKey(size: .bits256)
        let p = AgentPath.root.child("worker-4")
        let store = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg = AgentRegistry(store: store)
        try await reg.reserve(p, parent: .root)
        await reg.remove(p)

        let store2 = EncryptedFileAgentRecordStore(path: path, key: key)
        let reg2 = AgentRegistry(store: store2)
        await reg2.hydrate()
        let rec = await reg2.get(p)
        XCTAssertNil(rec, "removed record must not resurface after hydrate")
    }

    func testNoStoreIsPureInMemory() async throws {
        // The default (storeless) registry must behave exactly as before: a
        // fresh storeless registry shares nothing.
        let p = AgentPath.root.child("ephemeral")
        let reg = AgentRegistry()
        try await reg.reserve(p, parent: .root)
        await reg.setResult(p, output: "gone on restart", error: nil, status: .completed)
        let live = await reg.get(p)
        XCTAssertEqual(live?.result, "gone on restart")

        let reg2 = AgentRegistry()
        await reg2.hydrate()   // no store → no-op
        let gone = await reg2.get(p)
        XCTAssertNil(gone, "storeless registries never persist")
    }
}
#endif
