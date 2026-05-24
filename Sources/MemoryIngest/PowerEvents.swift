import Foundation

#if canImport(IOKit)
import IOKit
import IOKit.pwr_mgt
#endif

/// macOS sleep/wake observer. The design doc fixes the supported pattern as
/// `IORegisterForSystemPower` with explicit ack via `IOAllowPowerChange` (TN2083
/// — `NSWorkspace` is unavailable to a daemon). On Linux we fall back to a
/// SIGUSR2-based reload trigger.
///
/// Callers register a handler closure that receives high-level events; the
/// actor wraps platform-specific glue and is otherwise process-global.
public enum PowerEvent: Sendable {
    case willSleep
    case willWake
    case didWake
}

public final class PowerEvents: @unchecked Sendable {
    public typealias Handler = @Sendable (PowerEvent) -> Void

    public let handler: Handler
    #if canImport(IOKit)
    private var rootPort: io_object_t = 0
    private var notifierObject: io_object_t = 0
    private var notificationPort: IONotificationPortRef?
    private var runLoopSource: CFRunLoopSource?
    #endif

    public init(handler: @escaping Handler) {
        self.handler = handler
    }

    /// Wire up to the platform's power-management notifications. On macOS the
    /// caller must keep the returned instance alive for the lifetime of the
    /// daemon; deallocation deregisters cleanly. On Linux this is a no-op.
    public func start() {
        #if canImport(IOKit) && os(macOS)
        let context = Unmanaged.passUnretained(self).toOpaque()
        var notifier: io_object_t = 0
        var port: IONotificationPortRef?
        let root = IORegisterForSystemPower(context, &port, { ctx, _, msgType, msgArg in
            guard let ctx else { return }
            let me = Unmanaged<PowerEvents>.fromOpaque(ctx).takeUnretainedValue()
            // Constants come from <IOKit/IOMessage.h>; the Swift import is
            // unavailable on macOS 26 SDKs so we hard-code the public ABI
            // values (`iokit_common_msg(x) = 0xE0000000 | x`).
            let kCanSleep: UInt32     = 0xE000_0270
            let kWillSleep: UInt32    = 0xE000_0280
            let kWillPowerOn: UInt32  = 0xE000_0320
            let kHasPoweredOn: UInt32 = 0xE000_0300
            switch msgType {
            case kCanSleep:
                me.handler(.willSleep)
                IOAllowPowerChange(me.rootPort, Int(bitPattern: msgArg))
            case kWillSleep:
                me.handler(.willSleep)
                IOAllowPowerChange(me.rootPort, Int(bitPattern: msgArg))
            case kWillPowerOn:
                me.handler(.willWake)
            case kHasPoweredOn:
                me.handler(.didWake)
            default:
                break
            }
        }, &notifier)
        guard root != MACH_PORT_NULL, let port else { return }
        self.rootPort = root
        self.notifierObject = notifier
        self.notificationPort = port
        if let src = IONotificationPortGetRunLoopSource(port)?.takeUnretainedValue() {
            self.runLoopSource = src
            CFRunLoopAddSource(CFRunLoopGetCurrent(), src, .defaultMode)
        }
        #endif
    }

    public func stop() {
        #if canImport(IOKit) && os(macOS)
        if let src = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), src, .defaultMode)
        }
        if notifierObject != 0 { IODeregisterForSystemPower(&notifierObject) }
        if let port = notificationPort { IONotificationPortDestroy(port) }
        rootPort = 0
        notifierObject = 0
        notificationPort = nil
        runLoopSource = nil
        #endif
    }

    deinit { stop() }
}
