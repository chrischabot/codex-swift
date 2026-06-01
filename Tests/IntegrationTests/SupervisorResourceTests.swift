import XCTest
import Foundation
@testable import Supervisor
@testable import IPC
@testable import ProtocolModel
@testable import InfraPrimitives
@testable import Persistence
@testable import WireProtocol
@testable import SessionWorkerCore
@testable import HarnessCore
@testable import ModelClient
@testable import Tools
@testable import Sandbox

#if canImport(Glibc)
import Glibc
#elseif canImport(Darwin)
import Darwin
#endif

final class SupervisorResourceTests: XCTestCase {
    #if os(macOS)
    func testPhysicalFootprintLimitRoundsBytesToMebibytes() {
        XCTAssertEqual(ProcessResourceControl.physicalFootprintLimitMebibytes(forBytes: 1), 1)
        XCTAssertEqual(ProcessResourceControl.physicalFootprintLimitMebibytes(forBytes: 1_048_576), 1)
        XCTAssertEqual(ProcessResourceControl.physicalFootprintLimitMebibytes(forBytes: 1_048_577), 2)
        XCTAssertEqual(ProcessResourceControl.physicalFootprintLimitMebibytes(forBytes: 0), 0)
    }
    #endif

    func testResourceControlIPCEnvelopeRoundTrip() throws {
        let control = WorkerResourceControl.throttled(memoryLimitBytes: 96 * 1024 * 1024)
        let encoded = try JSONEncoder().encode(IPCEnvelope.s2w(.resourceControl(control)))
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: encoded)
        guard case .resourceControl(let decodedControl)? = decoded.toS2W() else {
            return XCTFail("expected resource-control supervisor message")
        }
        XCTAssertEqual(decodedControl, control)
    }

    func testHeartbeatIPCEnvelopeRoundTrip() throws {
        let threadId = ThreadId("thr_heartbeat_roundtrip")
        let encoded = try JSONEncoder().encode(IPCEnvelope.w2s(.heartbeat(threadId)))
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: encoded)
        guard case .heartbeat(let decodedThreadId)? = decoded.toW2S() else {
            return XCTFail("expected heartbeat worker message")
        }
        XCTAssertEqual(decodedThreadId, threadId)
    }

    func testServerResponseIPCEnvelopeRoundTripCarriesRawJSON() throws {
        let result: JSONValue = .object(["token": .string("v1.opaque")])
        let encoded = try JSONEncoder().encode(IPCEnvelope.s2w(.serverResponse(
            WorkerServerResponse(requestId: "attestation-1", result: result))))
        let decoded = try JSONDecoder().decode(IPCEnvelope.self, from: encoded)
        guard case .serverResponse(let response)? = decoded.toS2W() else {
            return XCTFail("expected server response")
        }
        XCTAssertEqual(response.requestId, "attestation-1")
        XCTAssertEqual(response.result, result)
        XCTAssertEqual(response.failed, false)
    }

    func testWorkerMcpIPCEnvelopeRoundTripCarriesDirectRequestAndResponse() throws {
        let threadId = ThreadId("thr_mcp_ipc_roundtrip")
        let request = WorkerMcpRequest(
            requestId: "mcp-\(threadId.raw)-1",
            kind: .callTool,
            threadId: threadId,
            server: "counter",
            tool: "count",
            argumentsJSON: #"{"value":1}"#)
        let encodedRequest = try JSONEncoder().encode(IPCEnvelope.s2w(.mcpRequest(request)))
        let decodedRequest = try JSONDecoder().decode(IPCEnvelope.self, from: encodedRequest)
        guard case .mcpRequest(let decodedMcpRequest)? = decodedRequest.toS2W() else {
            return XCTFail("expected MCP supervisor request")
        }
        XCTAssertEqual(decodedMcpRequest, request)

        let result: JSONValue = .object(["content": .array([
            .object(["type": .string("text"), "text": .string("ok")])
        ])])
        let response = WorkerMcpResponse(requestId: request.requestId, result: result)
        let encodedResponse = try JSONEncoder().encode(IPCEnvelope.w2s(.mcpResponse(response)))
        let decodedResponse = try JSONDecoder().decode(IPCEnvelope.self, from: encodedResponse)
        guard case .mcpResponse(let decodedMcpResponse)? = decodedResponse.toW2S() else {
            return XCTFail("expected MCP worker response")
        }
        XCTAssertEqual(decodedMcpResponse, response)
    }

    func testWorkerAttestationBrokerWrapsOpaqueClientToken() async throws {
        let link = WorkerLink.make()
        let broker = WorkerAttestationBroker(timeout: .seconds(2))
        let headerTask = Task { await broker.header(for: "thr_attest", link: link) }

        let request = try await nextWorkerToSupervisorMessage(from: link)
        guard case .serverRequest(let serverRequest) = request,
              case .attestationGenerate(let requestId, _) = serverRequest else {
            return XCTFail("expected attestation/generate request")
        }
        await broker.resolve(WorkerServerResponse(
            requestId: requestId.description,
            result: .object(["token": .string("v1.opaque-client-payload")])))

        let headerValue = await headerTask.value
        let header = try XCTUnwrap(headerValue)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(header.utf8))
        XCTAssertEqual(envelope["v"]?.intValue, 1)
        XCTAssertEqual(envelope["s"]?.intValue, 0)
        XCTAssertEqual(envelope["t"]?.stringValue, "v1.opaque-client-payload")
    }

    func testWorkerAttestationBrokerReportsMalformedClientResponse() async throws {
        let link = WorkerLink.make()
        let broker = WorkerAttestationBroker(timeout: .seconds(2))
        let headerTask = Task { await broker.header(for: "thr_attest", link: link) }

        let request = try await nextWorkerToSupervisorMessage(from: link)
        guard case .serverRequest(let serverRequest) = request,
              case .attestationGenerate(let requestId, _) = serverRequest else {
            return XCTFail("expected attestation/generate request")
        }
        await broker.resolve(WorkerServerResponse(
            requestId: requestId.description,
            result: .object(["notToken": .string("nope")])))

        let headerValue = await headerTask.value
        let header = try XCTUnwrap(headerValue)
        let envelope = try JSONDecoder().decode(JSONValue.self, from: Data(header.utf8))
        XCTAssertEqual(envelope["v"]?.intValue, 1)
        XCTAssertEqual(envelope["s"]?.intValue, 4)
        XCTAssertNil(envelope["t"])
    }

    func testSupervisorRoutesAttestationOnlyToCapableSubscriberAndReturnsRawToken() async throws {
        let cfg = SessionConfig(threadId: ThreadId("thr_attestation_route"), cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = ServerRequestProbe()
        _ = await supervisor.ensureWorker(
            cfg,
            requestAttestation: false,
            onNotification: { _ in },
            onServerRequest: { req in Task { await probe.append(req, label: "plain") } })
        _ = await supervisor.ensureWorker(
            cfg,
            requestAttestation: true,
            onNotification: { _ in },
            onServerRequest: { req in Task { await probe.append(req, label: "capable") } })
        _ = try await nextSupervisorToWorkerMessage(from: link)

        link.sendToSupervisor(.serverRequest(.attestationGenerate(.string("att-1"), .init())))
        try await eventually {
            await probe.labels() == ["capable"]
        }
        await supervisor.deliverServerResponse("att-1",
                                               result: .object(["token": .string("v1.token")]))
        let response = try await nextSupervisorToWorkerMessage(from: link)
        guard case .serverResponse(let payload) = response else {
            return XCTFail("expected server response")
        }
        XCTAssertEqual(payload.requestId, "att-1")
        XCTAssertEqual(payload.result?["token"]?.stringValue, "v1.token")
        XCTAssertFalse(payload.failed)
    }

    func testSupervisorOmitsAttestationWhenNoCapableSubscriberExists() async throws {
        let cfg = SessionConfig(threadId: ThreadId("thr_attestation_none"), cwd: "/tmp")
        let link = WorkerLink.make()
        let supervisor = SessionSupervisor(factory: { _ in
            WorkerHandle(link: link, task: Task {})
        })
        let probe = ServerRequestProbe()
        _ = await supervisor.ensureWorker(
            cfg,
            requestAttestation: false,
            onNotification: { _ in },
            onServerRequest: { req in Task { await probe.append(req, label: "plain") } })
        _ = try await nextSupervisorToWorkerMessage(from: link)

        link.sendToSupervisor(.serverRequest(.attestationGenerate(.string("att-none"), .init())))
        let response = try await nextSupervisorToWorkerMessage(from: link)
        let labels = await probe.labels()
        XCTAssertEqual(labels, [])
        guard case .serverResponse(let payload) = response else {
            return XCTFail("expected server response")
        }
        XCTAssertEqual(payload.requestId, "att-none")
        XCTAssertEqual(payload.result, .null)
        XCTAssertFalse(payload.failed)
    }

    func testProcessIPCIgnoresMalformedFramesAndRecovers() async throws {
        var sv: [Int32] = [0, 0]
        #if canImport(Glibc)
        let rc = sv.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, Int32(SOCK_STREAM.rawValue), 0, $0.baseAddress)
        }
        #else
        let rc = sv.withUnsafeMutableBufferPointer {
            socketpair(AF_UNIX, SOCK_STREAM, 0, $0.baseAddress)
        }
        #endif
        XCTAssertEqual(rc, 0)
        let supervisorFD = sv[0]
        let workerFD = sv[1]
        defer {
            close(supervisorFD)
            close(workerFD)
        }

        let link = WorkerLink.make()
        ProcessIPC.runSupervisorBridge(link: link, fd: supervisorFD)

        let threadId = ThreadId("thr_ipc_malformed_recovery")
        let valid = try JSONEncoder().encode(IPCEnvelope.w2s(.heartbeat(threadId)))
        var validLine = valid
        validLine.append(0x0A)
        try writeIPCLine(workerFD, Data("not-json\n".utf8))
        try writeIPCLine(workerFD, Data((#"{"unknown":true}"# + "\n").utf8))
        try writeIPCLine(workerFD, validLine)

        let received = try await nextWorkerToSupervisorMessage(from: link)
        guard case .heartbeat(let decodedThreadId) = received else {
            return XCTFail("expected bridge to ignore malformed frames and deliver later heartbeat")
        }
        XCTAssertEqual(decodedThreadId, threadId)
    }

    func testWorkerRuntimeEmitsHeartbeatAfterBind() async throws {
        let home = NSTemporaryDirectory() + "runtime-heartbeat-" + UUID().uuidString
        try FileManager.default.createDirectory(atPath: home, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(atPath: home) }
        let limits = Limits()
        let store = try ThreadStore(codexHome: home, limits: limits)
        let threadId = ThreadId("thr_runtime_heartbeat")
        let cfg = SessionConfig(threadId: threadId, cwd: home)
        _ = try await store.create(cfg)
        let link = WorkerLink.make()
        let runtime = WorkerRuntime(link: link, heartbeatInterval: .milliseconds(20)) { config in
            let sandbox = WorkspaceSandbox(SandboxPolicy(mode: .workspaceWrite,
                                                         writableRoots: [config.cwd]))
            return SessionEngine(config: config,
                                 model: MockModelClient(repeating: .hello(), times: 1),
                                 store: store,
                                 router: ToolRouter(limits: limits),
                                 limits: limits,
                                 sandbox: sandbox)
        }
        let task = Task { await runtime.run() }
        defer {
            link.sendToWorker(.quiesce)
            task.cancel()
        }
        let sink = WorkerMessageProbe()
        let drain = Task {
            for await message in link.outbound {
                await sink.append(message)
            }
        }
        defer { drain.cancel() }

        link.sendToWorker(.bind(cfg))
        try await eventually {
            let ready = await sink.sawReady(threadId)
            let heartbeat = await sink.sawHeartbeat(threadId)
            return ready && heartbeat
        }
    }

    func testHardGovernorStateRejectsNewTurnsWithoutKillingWorker() async throws {
        var limits = Limits()
        limits.ledgerSoftCPUFraction = 0.50
        limits.ledgerHardMemoryBytes = 512 * 1024 * 1024
        let pid: Int32 = 42
        let sampler = ScriptedResourceSampler([
            pid: [ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.80, residentBytes: 32 * 1024 * 1024)]
        ])
        let probe = WorkerProbe()
        let terminator = TerminationProbe()
        let supervisor = SessionSupervisor(factory: { _ in
            makeProbedHandle(pid: pid, probe: probe, terminator: terminator)
        }, limits: limits, sampler: sampler)
        let cfg = SessionConfig(threadId: ThreadId("thr_resource_hard"), cwd: "/tmp")
        let notifications = NotificationProbe()

        _ = await supervisor.ensureWorker(cfg) { notification in
            notifications.append(notification)
        }
        try await eventually { await probe.binds() == 1 }

        await supervisor.tickResources()

        let governorState = await supervisor.governorState(cfg.threadId)
        let isBound = await supervisor.isBound(cfg.threadId)
        let terminationCount = terminator.value()
        XCTAssertEqual(governorState, .hard)
        XCTAssertTrue(isBound)
        XCTAssertEqual(terminationCount, 0)

        await supervisor.submit(cfg.threadId, .startTurn(input: [TurnInput(text: "should be rejected")],
                                                         model: nil, turnId: nil))
        try await Task.sleep(for: .milliseconds(100))

        let opCount = await probe.ops()
        XCTAssertEqual(opCount, 0)
        let seen = notifications.values()
        XCTAssertTrue(seen.contains {
            if case .warning(let threadId, let message) = $0 {
                return threadId == cfg.threadId && message.contains("hard")
            }
            return false
        })
        XCTAssertTrue(seen.contains {
            if case .error(let threadId, _, let willRetry, let body) = $0 {
                return threadId == cfg.threadId
                    && body.reason == "Overloaded"
                    && willRetry == false
            }
            return false
        })
        let controlQoS = await probe.resourceControlQoS()
        XCTAssertEqual(controlQoS, [.normal, .throttled])
        let controlCaps = await probe.resourceControlCaps()
        XCTAssertEqual(controlCaps, [limits.ledgerHardMemoryBytes, limits.ledgerHardMemoryBytes])
    }

    func testSoftGovernorThrottlesWorkerAndNormalRestoresIt() async throws {
        var limits = Limits()
        limits.ledgerSoftCPUFraction = 0.50
        limits.ledgerHardMemoryBytes = 512 * 1024 * 1024
        let pid: Int32 = 55
        let sampler = ScriptedResourceSampler([
            pid: [
                ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.55, residentBytes: 32 * 1024 * 1024),
                ResourceSample(atMonotonic: 2, cpuFractionOverWindow: 0.10, residentBytes: 32 * 1024 * 1024)
            ]
        ])
        let probe = WorkerProbe()
        let terminator = TerminationProbe()
        let cfg = SessionConfig(threadId: ThreadId("thr_resource_qos_restore"), cwd: "/tmp")
        let supervisor = SessionSupervisor(factory: { _ in
            makeProbedHandle(pid: pid, probe: probe, terminator: terminator)
        }, limits: limits, sampler: sampler)

        _ = await supervisor.ensureWorker(cfg) { _ in }
        try await eventually { await probe.binds() == 1 }

        await supervisor.tickResources()
        await supervisor.tickResources()

        try await eventually { await probe.resourceControlQoS() == [.normal, .throttled, .normal] }
        let controlQoS = await probe.resourceControlQoS()
        XCTAssertEqual(controlQoS, [.normal, .throttled, .normal])
        let controlCaps = await probe.resourceControlCaps()
        XCTAssertEqual(controlCaps, [
            limits.ledgerHardMemoryBytes,
            limits.ledgerHardMemoryBytes,
            limits.ledgerHardMemoryBytes
        ])
        let governorState = await supervisor.governorState(cfg.threadId)
        XCTAssertEqual(governorState, .normal)
        XCTAssertEqual(terminator.value(), 0)
    }

    func testHardGovernorDoesNotRepeatThrottleControlWhileAlreadyThrottled() async throws {
        var limits = Limits()
        limits.ledgerSoftCPUFraction = 0.50
        limits.ledgerHardMemoryBytes = 512 * 1024 * 1024
        let pid: Int32 = 56
        let sampler = ScriptedResourceSampler([
            pid: [
                ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.80, residentBytes: 32 * 1024 * 1024),
                ResourceSample(atMonotonic: 2, cpuFractionOverWindow: 0.90, residentBytes: 32 * 1024 * 1024)
            ]
        ])
        let probe = WorkerProbe()
        let terminator = TerminationProbe()
        let cfg = SessionConfig(threadId: ThreadId("thr_resource_qos_no_spam"), cwd: "/tmp")
        let supervisor = SessionSupervisor(factory: { _ in
            makeProbedHandle(pid: pid, probe: probe, terminator: terminator)
        }, limits: limits, sampler: sampler)

        _ = await supervisor.ensureWorker(cfg) { _ in }
        try await eventually { await probe.binds() == 1 }

        await supervisor.tickResources()
        await supervisor.tickResources()

        try await eventually { await probe.resourceControlQoS() == [.normal, .throttled] }
        let controlQoS = await probe.resourceControlQoS()
        XCTAssertEqual(controlQoS, [.normal, .throttled])
        let controlCaps = await probe.resourceControlCaps()
        XCTAssertEqual(controlCaps, [limits.ledgerHardMemoryBytes, limits.ledgerHardMemoryBytes])
        let governorState = await supervisor.governorState(cfg.threadId)
        XCTAssertEqual(governorState, .hard)
        XCTAssertEqual(terminator.value(), 0)
    }

    func testHardGovernorStateMapsTurnStartToOverloadWireError() async throws {
        var limits = Limits()
        limits.ledgerSoftCPUFraction = 0.50
        limits.ledgerHardMemoryBytes = 512 * 1024 * 1024
        let pid: Int32 = 77
        let sampler = ScriptedResourceSampler([
            pid: [ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.80, residentBytes: 32 * 1024 * 1024)]
        ])
        let probe = WorkerProbe()
        let terminator = TerminationProbe()
        let supervisor = SessionSupervisor(factory: { _ in
            makeProbedHandle(pid: pid, probe: probe, terminator: terminator)
        }, limits: limits, sampler: sampler)
        let cfg = SessionConfig(threadId: ThreadId("thr_resource_wire_overload"), cwd: "/tmp")
        let home = NSTemporaryDirectory() + "supervisor-resource-" + UUID().uuidString
        defer { try? FileManager.default.removeItem(atPath: home) }
        let store = try ThreadStore(codexHome: home, limits: limits)
        _ = try await store.create(cfg)
        let router = RequestRouter(supervisor: supervisor, store: store, codexHome: home)
        let conn = InMemoryConnection()

        await router.handle(.request(JSONRPCRequest(
            id: .int(1),
            method: "initialize",
            params: .object(["clientInfo": .object(["name": .string("test")])] )
        )), conn)
        _ = await waitOutbound(conn) {
            if case .response(let response) = $0 { return response.id == .int(1) }
            return false
        }
        _ = await supervisor.ensureWorker(cfg) { _ in }
        try await eventually { await probe.binds() == 1 }
        await supervisor.tickResources()

        await router.handle(.request(JSONRPCRequest(
            id: .int(2),
            method: "turn/start",
            params: .object([
                "threadId": .string(cfg.threadId.raw),
                "input": .array([.object(["type": .string("text"), "text": .string("blocked")])])
            ])
        )), conn)
        let out = await waitOutbound(conn) {
            if case .error(let error) = $0 { return error.id == .int(2) }
            return false
        }

        guard case .error(let error)? = out.first(where: {
            if case .error(let error) = $0 { return error.id == .int(2) }
            return false
        }) else {
            return XCTFail("expected overload error")
        }
        XCTAssertEqual(error.error.code, WireError.overloadCode)
        XCTAssertEqual(error.error.message, WireError.overloadMessage)
        let opCount = await probe.ops()
        XCTAssertEqual(opCount, 0)
    }

    func testTerminalGovernorStateTerminatesAndQuarantinesOnlyOffendingWorker() async throws {
        var limits = Limits()
        limits.ledgerHardMemoryBytes = 64 * 1024 * 1024
        let hotPID: Int32 = 101
        let quietPID: Int32 = 202
        let sampler = ScriptedResourceSampler([
            hotPID: [ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.10, residentBytes: 80 * 1024 * 1024)],
            quietPID: [ResourceSample(atMonotonic: 1, cpuFractionOverWindow: 0.01, residentBytes: 16 * 1024 * 1024)]
        ])
        let hotTerminator = TerminationProbe()
        let quietTerminator = TerminationProbe()
        let hotProbe = WorkerProbe()
        let quietProbe = WorkerProbe()
        let hotThread = ThreadId("thr_resource_terminal_hot")
        let quietThread = ThreadId("thr_resource_terminal_quiet")
        let notifications = NotificationProbe()
        let supervisor = SessionSupervisor(factory: { cfg in
            if cfg.threadId == hotThread {
                return makeProbedHandle(pid: hotPID, probe: hotProbe, terminator: hotTerminator)
            }
            return makeProbedHandle(pid: quietPID, probe: quietProbe, terminator: quietTerminator)
        }, limits: limits, sampler: sampler)

        _ = await supervisor.ensureWorker(SessionConfig(threadId: hotThread, cwd: "/tmp")) { notification in
            notifications.append(notification)
        }
        _ = await supervisor.ensureWorker(SessionConfig(threadId: quietThread, cwd: "/tmp")) { notification in
            notifications.append(notification)
        }
        try await eventually {
            let hotBinds = await hotProbe.binds()
            let quietBinds = await quietProbe.binds()
            return hotBinds == 1 && quietBinds == 1
        }

        await supervisor.tickResources()

        let hotBound = await supervisor.isBound(hotThread)
        let quietBound = await supervisor.isBound(quietThread)
        let hotTerminations = hotTerminator.value()
        let quietTerminations = quietTerminator.value()
        XCTAssertFalse(hotBound)
        XCTAssertTrue(quietBound)
        XCTAssertEqual(hotTerminations, 1)
        XCTAssertEqual(quietTerminations, 0)
        let seen = notifications.values()
        XCTAssertTrue(seen.contains {
            if case .error(let threadId, _, let willRetry, let body) = $0 {
                return threadId == hotThread
                    && body.reason == "ResourceGovernorTerminal"
                    && willRetry == false
            }
            return false
        })
    }

    func testTerminalGovernorCountsDescendantResourceUsage() async throws {
        var limits = Limits()
        limits.ledgerHardMemoryBytes = 64 * 1024 * 1024
        let pid: Int32 = 303
        let sampler = TreeResourceSampler(rootOnly: [
            pid: ResourceSample(atMonotonic: 1,
                                cpuFractionOverWindow: 0.01,
                                residentBytes: 8 * 1024 * 1024)
        ], tree: [
            pid: ResourceSample(atMonotonic: 1,
                                cpuFractionOverWindow: 0.01,
                                residentBytes: 96 * 1024 * 1024)
        ])
        let terminator = TerminationProbe()
        let probe = WorkerProbe()
        let thread = ThreadId("thr_resource_descendant_terminal")
        let notifications = NotificationProbe()
        let supervisor = SessionSupervisor(factory: { _ in
            makeProbedHandle(pid: pid, probe: probe, terminator: terminator)
        }, limits: limits, sampler: sampler)

        _ = await supervisor.ensureWorker(SessionConfig(threadId: thread, cwd: "/tmp")) { notification in
            notifications.append(notification)
        }
        try await eventually { await probe.binds() == 1 }

        await supervisor.tickResources()

        let bound = await supervisor.isBound(thread)
        XCTAssertFalse(bound)
        XCTAssertEqual(terminator.value(), 1)
        let seen = notifications.values()
        XCTAssertTrue(seen.contains {
            if case .error(let threadId, _, let willRetry, let body) = $0 {
                return threadId == thread
                    && body.reason == "ResourceGovernorTerminal"
                    && willRetry == false
            }
            return false
        })
    }

    func testWatchdogTerminatesOnlyWorkerThatMissesHeartbeat() async throws {
        var limits = Limits()
        limits.heartbeatInterval = .milliseconds(200)
        limits.watchdogMissedHeartbeats = 1
        let staleThread = ThreadId("thr_watchdog_stale")
        let liveThread = ThreadId("thr_watchdog_live")
        let staleTerminator = TerminationProbe()
        let liveTerminator = TerminationProbe()
        let staleProbe = WorkerProbe()
        let liveProbe = WorkerProbe()
        let handles = WorkerHandleBox()
        let supervisor = SessionSupervisor(factory: { cfg in
            let terminator = cfg.threadId == staleThread ? staleTerminator : liveTerminator
            let probe = cfg.threadId == staleThread ? staleProbe : liveProbe
            let handle = makeProbedHandle(pid: cfg.threadId == staleThread ? 401 : 402,
                                          probe: probe,
                                          terminator: terminator)
            handles.store(handle.link, for: cfg.threadId)
            return handle
        }, limits: limits, sampler: ScriptedResourceSampler([:]))

        _ = await supervisor.ensureWorker(SessionConfig(threadId: staleThread, cwd: "/tmp")) { _ in }
        _ = await supervisor.ensureWorker(SessionConfig(threadId: liveThread, cwd: "/tmp")) { _ in }
        try await eventually {
            let staleBinds = await staleProbe.binds()
            let liveBinds = await liveProbe.binds()
            return staleBinds == 1 && liveBinds == 1
        }

        try await Task.sleep(for: .milliseconds(250))
        guard let liveLink = handles.link(for: liveThread) else {
            return XCTFail("missing live worker link")
        }
        liveLink.sendToSupervisor(.heartbeat(liveThread))
        try await Task.sleep(for: .milliseconds(20))

        await supervisor.tickWatchdogs()

        let staleBound = await supervisor.isBound(staleThread)
        let liveBound = await supervisor.isBound(liveThread)
        XCTAssertFalse(staleBound)
        XCTAssertTrue(liveBound)
        XCTAssertEqual(staleTerminator.value(), 1)
        XCTAssertEqual(liveTerminator.value(), 0)
    }
}

private func makeProbedHandle(pid: Int32,
                              probe: WorkerProbe,
                              terminator: TerminationProbe) -> WorkerHandle {
    let link = WorkerLink.make()
    let task = Task {
        for await message in link.inbound {
            await probe.record(message)
        }
    }
    return WorkerHandle(link: link, task: task, pid: pid) { terminator.record() }
}

private final class ScriptedResourceSampler: ResourceSampler, @unchecked Sendable {
    private let lock = NSLock()
    private var samples: [Int32: [ResourceSample]]

    init(_ samples: [Int32: [ResourceSample]]) {
        self.samples = samples
    }

    func sample(pid: Int32) -> ResourceSample? {
        lock.lock()
        defer { lock.unlock() }
        guard var pidSamples = samples[pid], let first = pidSamples.first else { return nil }
        if pidSamples.count > 1 {
            pidSamples.removeFirst()
            samples[pid] = pidSamples
        }
        return first
    }
}

private final class TreeResourceSampler: ResourceSampler, @unchecked Sendable {
    private let rootOnly: [Int32: ResourceSample]
    private let tree: [Int32: ResourceSample]

    init(rootOnly: [Int32: ResourceSample], tree: [Int32: ResourceSample]) {
        self.rootOnly = rootOnly
        self.tree = tree
    }

    func sample(pid: Int32) -> ResourceSample? {
        rootOnly[pid]
    }

    func sampleTree(rootPID: Int32) -> ResourceSample? {
        tree[rootPID] ?? rootOnly[rootPID]
    }
}

private final class WorkerHandleBox: @unchecked Sendable {
    private let lock = NSLock()
    private var links: [ThreadId: WorkerLink] = [:]

    func store(_ link: WorkerLink, for threadId: ThreadId) {
        lock.lock()
        links[threadId] = link
        lock.unlock()
    }

    func link(for threadId: ThreadId) -> WorkerLink? {
        lock.lock()
        defer { lock.unlock() }
        return links[threadId]
    }
}

private actor WorkerMessageProbe {
    private var messages: [WorkerToSupervisor] = []

    func append(_ message: WorkerToSupervisor) {
        messages.append(message)
    }

    func sawReady(_ threadId: ThreadId) -> Bool {
        messages.contains {
            if case .ready(let seen) = $0 { return seen == threadId }
            return false
        }
    }

    func sawHeartbeat(_ threadId: ThreadId) -> Bool {
        messages.contains {
            if case .heartbeat(let seen) = $0 { return seen == threadId }
            return false
        }
    }
}

private actor ServerRequestProbe {
    private var entries: [(String, ServerRequest)] = []

    func append(_ request: ServerRequest, label: String) {
        entries.append((label, request))
    }

    func labels() -> [String] {
        entries.map(\.0)
    }
}

private actor WorkerProbe {
    private var bindCount = 0
    private var opCount = 0
    private var controlValues: [WorkerResourceControl] = []

    func record(_ message: SupervisorToWorker) {
        switch message {
        case .bind:
            bindCount += 1
        case .op:
            opCount += 1
        case .resourceControl(let control):
            controlValues.append(control)
        case .quiesce, .serverResponse, .mcpRequest:
            break
        }
    }

    func binds() -> Int { bindCount }
    func ops() -> Int { opCount }
    func resourceControls() -> [WorkerResourceControl] { controlValues }
    func resourceControlQoS() -> [WorkerResourceQoS] { controlValues.map(\.qos) }
    func resourceControlCaps() -> [Int?] { controlValues.map(\.physicalMemoryLimitBytes) }
}

private final class TerminationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func record() {
        lock.lock()
        count += 1
        lock.unlock()
    }

    func value() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return count
    }
}

private final class NotificationProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [ServerNotification] = []

    func append(_ notification: ServerNotification) {
        lock.lock()
        recorded.append(notification)
        lock.unlock()
    }

    func values() -> [ServerNotification] {
        lock.lock()
        defer { lock.unlock() }
        return recorded
    }
}

private func eventually(timeout: Duration = .seconds(2),
                        _ predicate: @escaping @Sendable () async -> Bool) async throws {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await predicate() { return }
        try await Task.sleep(for: .milliseconds(10))
    }
    XCTFail("condition was not met before timeout")
}

private func nextWorkerToSupervisorMessage(from link: WorkerLink,
                                           timeout: Duration = .seconds(2)) async throws -> WorkerToSupervisor {
    try await withThrowingTaskGroup(of: WorkerToSupervisor.self) { group in
        group.addTask {
            for await message in link.outbound {
                return message
            }
            throw NSError(domain: "SupervisorResourceTests", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "worker link closed before message"])
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw NSError(domain: "SupervisorResourceTests", code: 2,
                          userInfo: [NSLocalizedDescriptionKey: "timed out waiting for worker message"])
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func nextSupervisorToWorkerMessage(from link: WorkerLink,
                                           timeout: Duration = .seconds(2)) async throws -> SupervisorToWorker {
    try await withThrowingTaskGroup(of: SupervisorToWorker.self) { group in
        group.addTask {
            for await message in link.inbound {
                return message
            }
            throw NSError(domain: "SupervisorResourceTests", code: 3,
                          userInfo: [NSLocalizedDescriptionKey: "worker link closed before message"])
        }
        group.addTask {
            try await Task.sleep(for: timeout)
            throw NSError(domain: "SupervisorResourceTests", code: 4,
                          userInfo: [NSLocalizedDescriptionKey: "timed out waiting for supervisor message"])
        }
        let value = try await group.next()!
        group.cancelAll()
        return value
    }
}

private func writeIPCLine(_ fd: Int32, _ data: Data) throws {
    try data.withUnsafeBytes { raw in
        guard let base = raw.bindMemory(to: UInt8.self).baseAddress else { return }
        var written = 0
        while written < data.count {
            #if canImport(Glibc)
            let n = Glibc.write(fd, base + written, data.count - written)
            #else
            let n = Darwin.write(fd, base + written, data.count - written)
            #endif
            if n <= 0 {
                throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno),
                              userInfo: [NSLocalizedDescriptionKey: "write failed"])
            }
            written += n
        }
    }
}

private func waitOutbound(_ conn: InMemoryConnection,
                          _ predicate: @escaping @Sendable (JSONRPCMessage) -> Bool,
                          timeoutMs: Int = 3000) async -> [JSONRPCMessage] {
    let stream = conn.clientOutbound()
    let collector = Task { () -> [JSONRPCMessage] in
        var out: [JSONRPCMessage] = []
        for await message in stream {
            out.append(message)
            if predicate(message) { break }
        }
        return out
    }
    let timeout = Task {
        try? await Task.sleep(for: .milliseconds(timeoutMs))
        collector.cancel()
    }
    let result = await collector.value
    timeout.cancel()
    return result
}
