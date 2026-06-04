import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
import WireProtocol
import ProtocolModel
import InfraPrimitives

// codex-send — ADDONS #7 owner-path CLI.
//
//   codex-send <target> <text> [--idempotency-key K]
//
// Routes an owner-trusted push through the daemon's durable PushRouter. The
// owner boundary in codex-swift IS the transport: codexd's stdio transport is
// owner-local, so this CLI spawns a fresh stdio-only codexd and issues
// `initialize -> outbound/send`. The daemon must have the push feature enabled
// (CODEX_FEATURE_PUSH=1 / [features].push) — the env is forwarded to the child.
//
// A keyless send is at-least-once WITHOUT dedup; pass --idempotency-key for
// crash-safe deduplication.

let usage = """
usage: codex-send <target> <text> [--idempotency-key K]
  target: e.g. "ntfy:my-topic" or "webhook:https://host/path"
  requires the daemon push feature (CODEX_FEATURE_PUSH=1 / [features].push)
  set CODEXD_BIN to override the codexd binary path

"""

/// Single-consumer mailbox: a background reader yields decoded frames into an
/// AsyncStream, one Task drains them here, and the main flow polls by id.
actor Inbox {
    private var messages: [JSONRPCMessage] = []
    func add(_ m: JSONRPCMessage) { messages.append(m) }

    enum Outcome { case ok(JSONValue); case failed(String) }

    private func response(id: Int64) -> JSONRPCResponse? {
        for m in messages { if case .response(let r) = m, r.id == .int(id) { return r } }
        return nil
    }
    private func errorMessage(id: Int64) -> String? {
        for m in messages { if case .error(let e) = m, e.id == .int(id) { return e.error.message } }
        return nil
    }
    func awaitResponse(id: Int64, timeoutMs: Int) async -> JSONRPCResponse? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let r = response(id: id) { return r }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
    func awaitOutcome(id: Int64, timeoutMs: Int) async -> Outcome? {
        let deadline = Date().addingTimeInterval(Double(timeoutMs) / 1000)
        while Date() < deadline {
            if let r = response(id: id) { return .ok(r.result) }
            if let m = errorMessage(id: id) { return .failed(m) }
            try? await Task.sleep(for: .milliseconds(20))
        }
        return nil
    }
}

@main
struct CodexSend {
    static func main() async {
        // --- parse args -----------------------------------------------------
        let argv = Array(CommandLine.arguments.dropFirst())
        var positionals: [String] = []
        var idemKey: String?
        var i = 0
        while i < argv.count {
            let a = argv[i]
            switch a {
            case "--idempotency-key", "-k":
                i += 1
                if i < argv.count { idemKey = argv[i] }
            case "-h", "--help":
                FileHandle.standardError.write(Data(usage.utf8)); exit(0)
            default:
                if a.hasPrefix("--idempotency-key=") {
                    idemKey = String(a.dropFirst("--idempotency-key=".count))
                } else {
                    positionals.append(a)
                }
            }
            i += 1
        }
        guard positionals.count >= 2 else {
            FileHandle.standardError.write(Data(usage.utf8)); exit(2)
        }
        let target = positionals[0]
        let text = positionals[1]

        // --- locate codexd --------------------------------------------------
        let env = ProcessInfo.processInfo.environment
        let codexd = env["CODEXD_BIN"]
            ?? URL(fileURLWithPath: CommandLine.arguments[0])
                .deletingLastPathComponent().appendingPathComponent("codexd").path
        guard FileManager.default.isExecutableFile(atPath: codexd) else {
            FileHandle.standardError.write(
                Data("codex-send: codexd not found at \(codexd) (set CODEXD_BIN)\n".utf8))
            exit(127)
        }

        // --- spawn an isolated, stdio-only codexd ---------------------------
        // Force `--listen stdio://` and strip the socket / web / memory env so
        // this one-shot never fights a running daemon for a socket, a port, or
        // the codex-memory WAL lock. The push config, CODEX_FEATURE_PUSH and
        // CODEX_HOME are inherited so the child sees the same sinks + push log.
        var childEnv = env
        for k in ["CODEXKIT_LISTEN", "CODEXKIT_LISTEN_WEB", "CODEXKIT_MEMORY"] {
            childEnv.removeValue(forKey: k)
        }
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: codexd)
        proc.arguments = ["--listen", "stdio://"]
        proc.environment = childEnv
        let toChild = Pipe()
        let fromChild = Pipe()
        proc.standardInput = toChild
        proc.standardOutput = fromChild
        // stderr is inherited so the user sees the daemon's own log lines.
        do { try proc.run() }
        catch {
            FileHandle.standardError.write(
                Data("codex-send: failed to spawn codexd: \(error)\n".utf8))
            exit(127)
        }

        let writeHandle = toChild.fileHandleForWriting
        let pid = proc.processIdentifier
        // Reap the child on every exit path: EOF its stdin, SIGTERM, then SIGKILL.
        func shutdownAndExit(_ code: Int32) -> Never {
            try? writeHandle.close()
            if proc.isRunning { proc.terminate() }
            let deadline = Date().addingTimeInterval(2)
            while proc.isRunning && Date() < deadline { usleep(20_000) }
            if proc.isRunning { kill(pid, SIGKILL) }
            exit(code)
        }

        // --- background reader: child stdout -> AsyncStream -> Inbox ---------
        let codec = WireCodec(maxInboundBytes: 8 * 1024 * 1024)
        let (stream, cont) = AsyncStream<JSONRPCMessage>.makeStream()
        let readFD = fromChild.fileHandleForReading.fileDescriptor   // Int32 (Sendable)
        let reader = Thread {
            let h = FileHandle(fileDescriptor: readFD, closeOnDealloc: false)
            var buffer = Data()
            while true {
                let chunk = h.availableData
                if chunk.isEmpty { break }    // EOF
                buffer.append(chunk)
                while let nl = buffer.firstIndex(of: 0x0A) {
                    let line = buffer.subdata(in: buffer.startIndex..<nl)
                    buffer.removeSubrange(buffer.startIndex...nl)
                    if line.isEmpty { continue }
                    if let m = try? codec.decode(line) { cont.yield(m) }
                }
            }
            cont.finish()
        }
        reader.stackSize = 1 << 20
        reader.name = "codex-send.reader"
        reader.start()

        let inbox = Inbox()
        let pump = Task { for await m in stream { await inbox.add(m) } }
        defer { pump.cancel() }

        func write(_ msg: JSONRPCMessage) {
            if let d = try? codec.encodeLine(msg) { writeHandle.write(d) }
        }

        // 1) initialize handshake.
        write(.request(JSONRPCRequest(id: .int(1), method: "initialize",
            params: .object([
                "clientInfo": .object(["name": .string("codex-send")]),
                "capabilities": .object([:]),
            ]))))
        guard await inbox.awaitResponse(id: 1, timeoutMs: 10_000) != nil else {
            FileHandle.standardError.write(
                Data("codex-send: no initialize response from codexd\n".utf8))
            shutdownAndExit(69)   // EX_UNAVAILABLE
        }
        write(.notification(JSONRPCNotification(method: "initialized")))

        // 2) outbound/send.
        var params: [String: JSONValue] = ["target": .string(target), "text": .string(text)]
        if let idemKey { params["idempotencyKey"] = .string(idemKey) }
        write(.request(JSONRPCRequest(id: .int(2), method: "outbound/send",
            params: .object(params))))

        guard let outcome = await inbox.awaitOutcome(id: 2, timeoutMs: 30_000) else {
            FileHandle.standardError.write(
                Data("codex-send: no outbound/send response (timeout)\n".utf8))
            shutdownAndExit(69)
        }
        switch outcome {
        case .failed(let msg):
            FileHandle.standardError.write(Data("codex-send: \(msg)\n".utf8))
            shutdownAndExit(1)
        case .ok(let result):
            let data = (try? JSONEncoder().encode(result)) ?? Data()
            let resp = (try? JSONDecoder().decode(OutboundSendResponse.self, from: data))
                ?? OutboundSendResponse(ok: false, detail: "unparseable response")
            FileHandle.standardOutput.write(Data((resp.detail + "\n").utf8))
            shutdownAndExit(resp.ok ? 0 : 1)
        }
    }
}
