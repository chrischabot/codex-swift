import Foundation
#if os(Linux)
import Glibc
#elseif os(macOS)
import Darwin
#endif

/// Resource governor states (rework §6.3 / hardening §5). Only the offending
/// worker is ever moved off Normal; quiet workers are untouched.
public enum GovernorState: String, Sendable, Codable, Equatable {
    case normal      // full QoS
    case soft        // demote QoS to .utility, shrink broker weight, coalesce harder
    case hard        // freeze new turns, reject turn/start with -32001
    case terminal    // SIGKILL + restart + fail session
}

/// One resource sample for a worker process.
public struct ResourceSample: Sendable, Equatable {
    public let atMonotonic: Double
    public let cpuFractionOverWindow: Double  // [0, nCores]
    public let residentBytes: Int
    public init(atMonotonic: Double, cpuFractionOverWindow: Double, residentBytes: Int) {
        self.atMonotonic = atMonotonic
        self.cpuFractionOverWindow = cpuFractionOverWindow
        self.residentBytes = residentBytes
    }
}

/// Pure decision function — deterministic and unit-testable in isolation
/// (the actual `proc_pid_rusage` sampling is injected, see `ResourceLedger`).
public struct GovernorPolicy: Sendable {
    public let softCPUFraction: Double
    public let hardMemoryBytes: Int

    public init(limits: Limits) {
        self.softCPUFraction = limits.ledgerSoftCPUFraction
        self.hardMemoryBytes = limits.ledgerHardMemoryBytes
    }

    public func evaluate(_ s: ResourceSample, hung: Bool) -> GovernorState {
        if hung || s.residentBytes >= hardMemoryBytes { return .terminal }
        if s.cpuFractionOverWindow >= softCPUFraction * 1.15 { return .hard }
        if s.cpuFractionOverWindow >= softCPUFraction { return .soft }
        return .normal
    }
}

/// Samples a process's CPU/memory. Portable stub uses task-info where
/// available; on macOS the real `proc_pid_rusage` is wired here.
public protocol ResourceSampler: Sendable {
    func sample(pid: Int32) -> ResourceSample?
    func sampleTree(rootPID: Int32) -> ResourceSample?
}

public extension ResourceSampler {
    func sampleTree(rootPID: Int32) -> ResourceSample? {
        sample(pid: rootPID)
    }
}

/// Portable sampler. Linux reads `/proc/<pid>/statm`; macOS uses
/// `proc_pid_rusage(RUSAGE_INFO_V4)` for resident/physical footprint and
/// cumulative CPU time, converted into a per-core fraction over the sampling
/// window.
public final class DefaultResourceSampler: ResourceSampler, @unchecked Sendable {
    private let cores: Double
    private let lock = NSLock()
    private var previousCPU: [Int32: (at: Double, totalNanoseconds: UInt64)] = [:]

    public init() {
        cores = Double(ProcessInfo.processInfo.activeProcessorCount)
    }

    public func sample(pid: Int32) -> ResourceSample? {
        #if os(Linux)
        return linuxSample(pid: pid)
        #elseif os(macOS)
        return darwinSample(pid: pid)
        #else
        return ResourceSample(atMonotonic: MonotonicClock.now(),
                              cpuFractionOverWindow: 0,
                              residentBytes: 0)
        #endif
    }

    public func sampleTree(rootPID: Int32) -> ResourceSample? {
        let pids = Self.processTreePIDs(root: rootPID)
        var at = 0.0
        var cpu = 0.0
        var resident = 0
        var found = false
        for pid in pids {
            guard let sample = sample(pid: pid) else { continue }
            found = true
            at = max(at, sample.atMonotonic)
            cpu += sample.cpuFractionOverWindow
            resident = saturatedAdd(resident, sample.residentBytes)
        }
        guard found else { return nil }
        return ResourceSample(atMonotonic: at,
                              cpuFractionOverWindow: min(cpu, cores),
                              residentBytes: resident)
    }

    static func processTreePIDs(root: Int32) -> [Int32] {
        guard root > 0 else { return [root] }
        var children = processChildrenByParent()
        var result: [Int32] = [root]
        var queue: [Int32] = [root]
        var index = 0
        while index < queue.count {
            let parent = queue[index]
            index += 1
            let kids = children.removeValue(forKey: parent) ?? []
            for child in kids where !result.contains(child) {
                result.append(child)
                queue.append(child)
            }
        }
        return result
    }

    private static func processChildrenByParent() -> [Int32: [Int32]] {
        #if os(Linux)
        return linuxChildrenByParent()
        #elseif os(macOS)
        return darwinChildrenByParent()
        #else
        return [:]
        #endif
    }

    #if os(Linux)
    private static func linuxChildrenByParent() -> [Int32: [Int32]] {
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else {
            return [:]
        }
        var children: [Int32: [Int32]] = [:]
        for entry in entries {
            guard let pid = Int32(entry),
                  let stat = try? String(contentsOfFile: "/proc/\(entry)/stat", encoding: .utf8),
                  let end = stat.lastIndex(of: ")") else {
                continue
            }
            let tail = stat[stat.index(after: end)...].split(separator: " ")
            guard tail.count > 1, let ppid = Int32(tail[1]) else { continue }
            children[ppid, default: []].append(pid)
        }
        return children
    }
    #endif

    #if os(macOS)
    private static func darwinChildrenByParent() -> [Int32: [Int32]] {
        let bytesNeeded = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard bytesNeeded > 0 else { return [:] }
        let count = Int(bytesNeeded) / MemoryLayout<pid_t>.stride
        var pids = Array(repeating: pid_t(0), count: count)
        let bytesReturned = pids.withUnsafeMutableBufferPointer { buffer in
            proc_listpids(UInt32(PROC_ALL_PIDS), 0, buffer.baseAddress, Int32(count * MemoryLayout<pid_t>.stride))
        }
        let returnedCount = max(0, Int(bytesReturned) / MemoryLayout<pid_t>.stride)
        var children: [Int32: [Int32]] = [:]
        for rawPID in pids.prefix(returnedCount) where rawPID > 0 {
            var info = proc_bsdinfo()
            let rc = withUnsafeMutablePointer(to: &info) { ptr in
                proc_pidinfo(rawPID, PROC_PIDTBSDINFO, 0, ptr, Int32(MemoryLayout<proc_bsdinfo>.stride))
            }
            guard rc == Int32(MemoryLayout<proc_bsdinfo>.stride) else { continue }
            let pid = Int32(rawPID)
            let ppid = Int32(info.pbi_ppid)
            children[ppid, default: []].append(pid)
        }
        return children
    }
    #endif

    private func saturatedAdd(_ lhs: Int, _ rhs: Int) -> Int {
        let (sum, overflow) = lhs.addingReportingOverflow(rhs)
        return overflow ? Int.max : sum
    }

    #if os(Linux)
    private func linuxSample(pid: Int32) -> ResourceSample? {
        guard let statm = try? String(contentsOfFile: "/proc/\(pid)/statm", encoding: .utf8) else {
            return nil
        }
        let pages = statm.split(separator: " ")
        let rssPages = pages.count > 1 ? Int(pages[1]) ?? 0 : 0
        let pageSize = sysconf(Int32(_SC_PAGESIZE))
        let resident = rssPages * pageSize
        return ResourceSample(atMonotonic: MonotonicClock.now(),
                              cpuFractionOverWindow: 0,  // CPU delta tracked by ResourceLedger
                              residentBytes: resident)
    }
    #endif

    #if os(macOS)
    private func darwinSample(pid: Int32) -> ResourceSample? {
        var info = rusage_info_v4()
        let rc = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { raw in
                proc_pid_rusage(pid, RUSAGE_INFO_V4, raw)
            }
        }
        guard rc == 0 else { return nil }

        let now = MonotonicClock.now()
        let total = info.ri_user_time &+ info.ri_system_time
        let resident = clampUInt64ToInt(max(info.ri_phys_footprint,
                                            info.ri_resident_size))
        let cpu = cpuFraction(pid: pid, now: now, totalNanoseconds: total)
        return ResourceSample(atMonotonic: now,
                              cpuFractionOverWindow: cpu,
                              residentBytes: resident)
    }

    private func cpuFraction(pid: Int32, now: Double,
                             totalNanoseconds: UInt64) -> Double {
        lock.lock()
        defer { lock.unlock() }
        defer { previousCPU[pid] = (now, totalNanoseconds) }
        guard let prev = previousCPU[pid], now > prev.at,
              totalNanoseconds >= prev.totalNanoseconds else {
            return 0
        }
        let cpuSeconds = Double(totalNanoseconds - prev.totalNanoseconds) / 1_000_000_000
        let fraction = cpuSeconds / (now - prev.at)
        return min(max(fraction, 0), cores)
    }

    private func clampUInt64ToInt(_ value: UInt64) -> Int {
        let maxInt = UInt64(Int.max)
        return Int(value > maxInt ? maxInt : value)
    }
    #endif
}

/// Tracks a worker's resource trajectory and exposes governor transitions.
/// Hardening §5 / rework §6.3. Pure logic + injected sampler so it is fully
/// testable; the Supervisor consumes `tick()` transitions.
public actor ResourceLedger {
    private let pid: Int32
    private let policy: GovernorPolicy
    private let sampler: any ResourceSampler
    public private(set) var state: GovernorState = .normal
    private var lastSample: ResourceSample?

    public init(pid: Int32, limits: Limits, sampler: any ResourceSampler = DefaultResourceSampler()) {
        self.pid = pid
        self.policy = GovernorPolicy(limits: limits)
        self.sampler = sampler
    }

    /// Inject a sample directly (used by tests and by the supervisor's
    /// CPU-delta accounting); returns the new state if it changed.
    @discardableResult
    public func observe(_ s: ResourceSample, hung: Bool = false) -> GovernorState? {
        lastSample = s
        let next = policy.evaluate(s, hung: hung)
        if next != state {
            state = next
            return next
        }
        return nil
    }

    /// Sample the process now via the sampler.
    @discardableResult
    public func tick(hung: Bool = false) -> GovernorState? {
        guard let s = sampler.sampleTree(rootPID: pid) else { return nil }
        return observe(s, hung: hung)
    }

    public func currentState() -> GovernorState { state }
}
