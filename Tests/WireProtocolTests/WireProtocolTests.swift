import XCTest
import Foundation
@testable import WireProtocol
@testable import InfraPrimitives

final class WireProtocolTests: XCTestCase {
    let codec = WireCodec(maxInboundBytes: 1024)

    private func roundTrip(_ m: JSONRPCMessage) throws -> JSONRPCMessage {
        let data = try codec.encode(m)
        return try codec.decode(data)
    }

    func testNoJsonrpcFieldEverEmitted() throws {
        let m = JSONRPCMessage.request(.init(id: .int(1), method: "initialize", params: .object(["x": .int(1)])))
        let s = String(decoding: try codec.encode(m), as: UTF8.self)
        XCTAssertFalse(s.contains("\"jsonrpc\""), "must never emit jsonrpc: \(s)")
    }

    func testUntaggedRoundTripAllFourKinds() throws {
        let req = JSONRPCMessage.request(.init(id: .string("a"), method: "turn/start", params: .object(["t": .string("x")])))
        let note = JSONRPCMessage.notification(.init(method: "item/agentMessage/delta", params: .object(["delta": .string("hi")])))
        let resp = JSONRPCMessage.response(.init(id: .int(7), result: .object(["ok": .bool(true)])))
        let err = JSONRPCMessage.error(.init(id: .int(7), error: .init(code: -32601, message: "x is not supported yet")))
        for m in [req, note, resp, err] {
            XCTAssertEqual(try roundTrip(m), m)
        }
    }

    func testRequestIdStringVsIntFidelity() throws {
        let asInt = JSONRPCMessage.response(.init(id: .int(42), result: .null))
        let asStr = JSONRPCMessage.response(.init(id: .string("42"), result: .null))
        XCTAssertEqual(try roundTrip(asInt), asInt)
        XCTAssertEqual(try roundTrip(asStr), asStr)
        // Ensure they do not collapse into each other on the wire.
        let intWire = String(decoding: try codec.encode(asInt), as: UTF8.self)
        let strWire = String(decoding: try codec.encode(asStr), as: UTF8.self)
        XCTAssertTrue(intWire.contains("\"id\":42"))
        XCTAssertTrue(strWire.contains("\"id\":\"42\""))
    }

    func testOmitNotNullForOptionalParamsAndTrace() throws {
        let m = JSONRPCMessage.notification(.init(method: "ping", params: nil))
        let s = String(decoding: try codec.encode(m), as: UTF8.self)
        XCTAssertFalse(s.contains("params"))
        XCTAssertFalse(s.contains("null"))
    }

    func testLenientStrayJsonrpcOnInputIsIgnored() throws {
        let raw = Data(#"{"jsonrpc":"2.0","id":1,"method":"initialize"}"#.utf8)
        let m = try codec.decode(raw)
        guard case .request(let r) = m else { return XCTFail("expected request") }
        XCTAssertEqual(r.method, "initialize")
        XCTAssertEqual(r.id, .int(1))
    }

    func testSizeCapTriggersInputTooLarge() {
        let big = Data(repeating: 0x20, count: 2048)
        XCTAssertThrowsError(try codec.decode(big)) { err in
            XCTAssertTrue(err is InputTooLargeError)
        }
    }

    func testMalformedAndGarbageNeverCrashes() {
        let cases = [
            "", "{", "}", "[]", "null", "\"x\"", "123",
            "{\"id\":1}", "{\"result\":1}", "{\"trace\":{}}",
            #"{"id":{},"method":3}"#, String(repeating: "{", count: 500),
            "\u{0000}\u{0001}", "{\"method\":\"x\",\"params\":\u{FFFF}}",
        ]
        for c in cases {
            // Must throw, never trap.
            _ = try? codec.decode(Data(c.utf8))
        }
        XCTAssertTrue(true)
    }

    func testRandomizedFuzzNeverTraps() {
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<5000 {
            let n = Int.random(in: 0...64, using: &rng)
            var bytes = [UInt8]()
            for _ in 0..<n { bytes.append(UInt8.random(in: 0...255, using: &rng)) }
            _ = try? codec.decode(Data(bytes))
        }
        XCTAssertTrue(true, "fuzz completed without trapping")
    }

    func testJSONLPartialFramingBuffersRemainder() throws {
        var buf = Data()
        let a = try codec.encodeLine(.notification(.init(method: "a")))
        let b = try codec.encodeLine(.notification(.init(method: "b")))
        buf.append(a)
        buf.append(b.prefix(b.count - 3)) // partial second frame
        var results = codec.decodeFrames(&buf)
        XCTAssertEqual(results.count, 1)
        buf.append(b.suffix(3))           // complete it later
        results = codec.decodeFrames(&buf)
        XCTAssertEqual(results.count, 1)
        if case .success(let m) = results[0], case .notification(let n) = m {
            XCTAssertEqual(n.method, "b")
        } else { XCTFail("expected notification b") }
    }

    func testErrorSentinels() {
        if case .error(let e) = WireError.overload(id: .int(1)) {
            XCTAssertEqual(e.error.code, -32001)
            XCTAssertEqual(e.error.message, "Server overloaded; retry later.")
        } else { XCTFail() }
        if case .error(let e) = WireError.unsupported(id: .int(1), method: "thread/turns/items/list") {
            XCTAssertEqual(e.error.code, -32601)
            XCTAssertEqual(e.error.message, "thread/turns/items/list is not supported yet")
        } else { XCTFail() }
        XCTAssertEqual(WireError.experimentalRequired("thread/start.runtimeWorkspaceRoots"),
                       "thread/start.runtimeWorkspaceRoots requires experimentalApi capability")
    }

    func testExperimentalGateMethodFieldAndEnum() {
        let g = ExperimentalGate()
        let noCaps = ClientCapabilities(experimentalApi: false)
        let caps = ClientCapabilities(experimentalApi: true)
        XCTAssertEqual(g.rejectionDescriptor(method: "process/spawn", presentFields: [], caps: noCaps),
                       "process/spawn")
        XCTAssertNil(g.rejectionDescriptor(method: "process/spawn", presentFields: [], caps: caps))
        XCTAssertEqual(g.rejectionDescriptor(method: "thread/start",
                                             presentFields: ["runtimeWorkspaceRoots"], caps: noCaps),
                       "thread/start.runtimeWorkspaceRoots")
        // Enum-variant gates carry the fixed, method-independent reason from the
        // upstream `#[experimental("askForApproval.granular")]` annotation on the
        // `AskForApproval::Granular` variant — NOT a method-qualified descriptor
        // (shared.rs:168, tests.rs:1481-1745).
        XCTAssertEqual(g.rejectionDescriptor(method: "turn/start",
                                             presentFields: ["askForApproval=granular"], caps: noCaps),
                       "askForApproval.granular")
        XCTAssertEqual(g.rejectionDescriptor(method: "thread/start",
                                             presentFields: ["approvalPolicy=granular"], caps: noCaps),
                       "askForApproval.granular")
        XCTAssertNil(g.rejectionDescriptor(method: "thread/start",
                                           presentFields: ["askForApproval=granular"], caps: caps))
        XCTAssertNil(g.rejectionDescriptor(method: "thread/start",
                                           presentFields: ["cwd"], caps: noCaps))
    }

    /// Audit app-server-registry/finding-1: whole-method `#[experimental(...)]`
    /// markers from upstream common.rs (goal/*, realtime/*, remoteControl/*,
    /// collaborationMode/list, fuzzyFileSearch/session*) must be gated by the
    /// ExperimentalGate so a non-experimental client is rejected with
    /// `<method> requires experimentalApi capability` (-32600).
    func testExperimentalGateCoversWholeMethodMarkers() {
        let g = ExperimentalGate()
        let noCaps = ClientCapabilities(experimentalApi: false)
        let caps = ClientCapabilities(experimentalApi: true)
        // NOTE: thread/goal/{set,get,clear} are intentionally NOT here — upstream
        // #23732 promoted Goals to Stage::Stable (default-on) and dropped the
        // `#[experimental(...)]` markers, so they are reachable without the
        // experimentalApi capability (see ExperimentalGate.defaultMethods).
        let gatedMethods = [
            "thread/realtime/start", "thread/realtime/appendAudio",
            "thread/realtime/appendText", "thread/realtime/stop",
            "thread/realtime/listVoices",
            "remoteControl/enable", "remoteControl/disable",
            "remoteControl/status/read",
            "collaborationMode/list",
            "fuzzyFileSearch/sessionStart", "fuzzyFileSearch/sessionUpdate",
            "fuzzyFileSearch/sessionStop",
        ]
        for m in gatedMethods {
            XCTAssertTrue(g.isExperimentalMethod(m),
                          "\(m) must be a whole-method experimental marker")
            XCTAssertEqual(g.rejectionDescriptor(method: m, presentFields: [], caps: noCaps),
                           m, "\(m) must be rejected without experimentalApi")
            XCTAssertNil(g.rejectionDescriptor(method: m, presentFields: [], caps: caps),
                         "\(m) must be allowed once experimentalApi is negotiated")
        }
    }
}