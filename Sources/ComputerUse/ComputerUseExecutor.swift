import Foundation
#if canImport(AppKit)
import AppKit
import CoreGraphics
import ApplicationServices
import ImageIO
import UniformTypeIdentifiers

/// Drives the real macOS desktop for the OpenAI `computer` tool: screenshots
/// (eyes) via `screencapture`, and mouse/keyboard/scroll (hands) via
/// CoreGraphics `CGEvent`, with model↔screen coordinate mapping.
///
/// The model reasons in a `display_width × display_height` image space; we
/// capture the main display, RESIZE the screenshot to `targetWidth` (aspect
/// preserved — OpenAI recommends ~1280–1600 wide, NOT full Retina res), report
/// those dims as the tool's display size, and map the model's returned
/// coordinates back to on-screen points for `CGEvent`.
///
/// Requires TWO macOS TCC permissions, granted to whatever binary hosts this:
///   • Screen Recording  — for `screencapture` to capture other apps' windows
///   • Accessibility     — for `CGEvent.post` to synthesize input
public struct ComputerUseExecutor: Sendable {
    public let targetWidth: Int
    public let targetHeight: Int
    /// Main display bounds in POINTS, top-left origin (CGEvent coordinate space).
    private let screen: CGRect

    public init(targetWidth: Int = 1280) {
        // Match `screencapture -D 1` (the MAIN/primary display) for BOTH the
        // screenshot the model sees AND the coordinate mapping, so eyes and hands
        // target the same display. `CGDisplayBounds(CGMainDisplayID())` is the
        // main display in the global display coordinate space (top-left origin,
        // points) — exactly the space `CGEvent` mouse positions use. We must NOT
        // use `NSScreen.main`: that is the screen with KEYBOARD FOCUS, which on a
        // multi-monitor setup diverges from `-D 1` and makes every click land on
        // the wrong display (the pre-fix bug).
        let b = CGDisplayBounds(CGMainDisplayID())
        let frame = (b.width > 0 && b.height > 0) ? b : CGRect(x: 0, y: 0, width: 1440, height: 900)
        self.screen = frame
        self.targetWidth = targetWidth
        self.targetHeight = max(1, Int((CGFloat(targetWidth) * frame.height / frame.width).rounded()))
    }

    // MARK: Permissions

    public struct Permissions: Sendable { public let screenRecording: Bool; public let accessibility: Bool
        public var ok: Bool { screenRecording && accessibility } }

    /// Check (and optionally prompt for) the two required permissions.
    public func checkPermissions(prompt: Bool = true) -> Permissions {
        let screen = CGPreflightScreenCaptureAccess()
        if !screen && prompt { _ = CGRequestScreenCaptureAccess() }
        // Literal of `kAXTrustedCheckOptionPrompt` (avoids referencing the
        // non-concurrency-safe global CFString under strict concurrency).
        let axOpts = ["AXTrustedCheckOptionPrompt": prompt] as CFDictionary
        let ax = AXIsProcessTrustedWithOptions(axOpts)
        return Permissions(screenRecording: screen, accessibility: ax)
    }

    // MARK: Eyes — screenshot

    /// Capture the main display and return PNG bytes resized to
    /// `targetWidth × targetHeight`. nil on failure (e.g. no Screen Recording).
    public func screenshotPNG() -> Data? {
        let tmp = NSTemporaryDirectory() + "cu-\(UUID().uuidString).png"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        p.arguments = ["-x", "-t", "png", "-D", "1", tmp]   // -x silent, -D 1 main display
        do { try p.run() } catch { return nil }
        p.waitUntilExit()
        defer { try? FileManager.default.removeItem(atPath: tmp) }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: tmp)) else { return nil }
        return Self.resizePNG(raw, toWidth: targetWidth, height: targetHeight) ?? raw
    }

    /// data: URL for a `computer_screenshot` output (detail:"original").
    public func screenshotDataURL() -> String? {
        guard let png = screenshotPNG() else { return nil }
        return "data:image/png;base64," + png.base64EncodedString()
    }

    static func resizePNG(_ data: Data, toWidth w: Int, height h: Int) -> Data? {
        guard let src = CGImageSourceCreateWithData(data as CFData, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: cs,
                                  bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        ctx.interpolationQuality = .high
        ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
        guard let out = ctx.makeImage() else { return nil }
        let buf = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(buf, UTType.png.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, out, nil)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return buf as Data
    }

    // MARK: coordinate mapping (model image space → screen points, top-left)

    private func point(_ mx: Double, _ my: Double) -> CGPoint {
        let x = screen.minX + CGFloat(mx) / CGFloat(targetWidth) * screen.width
        let y = screen.minY + CGFloat(my) / CGFloat(targetHeight) * screen.height
        return CGPoint(x: x, y: y)
    }

    // Testing seams (internal): the resolved screen bounds the model↔screen map
    // uses, and the map itself — so a test can assert it tracks the MAIN display
    // (`-D 1`) rather than the keyboard-focused screen.
    var screenBoundsForTesting: CGRect { screen }
    func mapModelPointForTesting(_ x: Double, _ y: Double) -> CGPoint { point(x, y) }

    // MARK: Hands — mouse

    private func postMouse(_ type: CGEventType, at p: CGPoint, button: CGMouseButton, flags: CGEventFlags) {
        guard let e = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: p, mouseButton: button)
        else { return }
        if !flags.isEmpty { e.flags = flags }
        e.post(tap: .cghidEventTap)
    }

    public func move(x: Double, y: Double) {
        postMouse(.mouseMoved, at: point(x, y), button: .left, flags: [])
    }

    public func click(x: Double, y: Double, button: String = "left", keys: [String] = []) {
        let p = point(x, y); let flags = Self.modifierFlags(keys)
        let (b, down, up) = Self.mouseKind(button)
        postMouse(.mouseMoved, at: p, button: .left, flags: [])
        postMouse(down, at: p, button: b, flags: flags)
        postMouse(up, at: p, button: b, flags: flags)
    }

    public func doubleClick(x: Double, y: Double, button: String = "left") {
        let p = point(x, y); let (b, down, up) = Self.mouseKind(button)
        for click in 1...2 {
            guard let d = CGEvent(mouseEventSource: nil, mouseType: down, mouseCursorPosition: p, mouseButton: b),
                  let u = CGEvent(mouseEventSource: nil, mouseType: up, mouseCursorPosition: p, mouseButton: b)
            else { return }
            d.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            u.setIntegerValueField(.mouseEventClickState, value: Int64(click))
            d.post(tap: .cghidEventTap); u.post(tap: .cghidEventTap)
        }
    }

    public func drag(path: [(Double, Double)], button: String = "left") {
        guard let first = path.first else { return }
        let (b, down, up) = Self.mouseKind(button)
        let dragType: CGEventType = (b == .right) ? .rightMouseDragged : .leftMouseDragged
        postMouse(down, at: point(first.0, first.1), button: b, flags: [])
        for pt in path.dropFirst() { postMouse(dragType, at: point(pt.0, pt.1), button: b, flags: []) }
        postMouse(up, at: point(path.last!.0, path.last!.1), button: b, flags: [])
    }

    public func scroll(x: Double, y: Double, scrollX: Double, scrollY: Double) {
        move(x: x, y: y)
        // CGEvent scroll is in lines (units .line); OpenAI scroll deltas are in
        // pixels — divide to lines (~10px/line) and invert Y (scrollY>0 = down).
        // Clamp before the Int32 conversion: the deltas are untrusted model JSON
        // (read verbatim), and `Int32(huge)` traps. NaN/∞ collapse to 0.
        let lines = Self.clampInt32(-scrollY / 10)
        let hLines = Self.clampInt32(scrollX / 10)
        guard let e = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2,
                              wheel1: lines, wheel2: hLines, wheel3: 0) else { return }
        e.post(tap: .cghidEventTap)
    }

    /// Round a Double to Int32, saturating to the representable range and mapping
    /// NaN/∞ to 0 — so an out-of-range or non-finite (untrusted) model value can
    /// never trap the `Int32(...)` conversion.
    static func clampInt32(_ d: Double) -> Int32 {
        guard d.isFinite else { return 0 }
        let r = d.rounded()
        if r >= Double(Int32.max) { return Int32.max }
        if r <= Double(Int32.min) { return Int32.min }
        return Int32(r)
    }

    private static func mouseKind(_ button: String) -> (CGMouseButton, CGEventType, CGEventType) {
        switch button.lowercased() {
        case "right": return (.right, .rightMouseDown, .rightMouseUp)
        case "middle", "wheel": return (.center, .otherMouseDown, .otherMouseUp)
        default: return (.left, .leftMouseDown, .leftMouseUp)
        }
    }

    // MARK: Hands — keyboard

    /// Type literal text (the model's `type` action). Uses Unicode injection so
    /// arbitrary characters work without per-key mapping.
    public func type(_ text: String) {
        for ch in text {
            var utf16 = Array(String(ch).utf16)
            guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                  let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
            down.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            up.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: &utf16)
            down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
        }
    }

    /// Press a chord of named keys (the model's `keypress` action), e.g.
    /// ["CMD","S"] or ["ENTER"]. Modifiers are held while the non-modifier keys
    /// are pressed.
    public func keypress(_ keys: [String]) {
        let flags = Self.modifierFlags(keys)
        let nonMods = keys.filter { !Self.isModifier($0) }
        // A pure-modifier chord (e.g. just ["SHIFT"]) has nothing to press.
        if nonMods.isEmpty { return }
        for key in nonMods {
            switch Self.keyDispatch(key) {
            case .keycode(let code):
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: code, keyDown: false) else { continue }
                down.flags = flags; up.flags = flags
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            case .unicode(let s):
                // Unmapped single character (a SHIFTED symbol like "+", ":", "?"
                // with no direct keycode): inject via Unicode so it actually types
                // instead of the old silent no-op. A Unicode-string event CANNOT
                // carry modifier flags — so if the chord has modifiers (e.g.
                // ⌘+"+"), injecting the bare character would type a stray symbol
                // into the focused field rather than perform the chord. In that
                // case do nothing (the inert pre-fix behavior) instead of
                // corrupting content; modifier+symbol chords whose symbol is
                // unshifted already take the keycode path above.
                if !flags.isEmpty { continue }
                var u = Array(s.utf16)
                guard let down = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: true),
                      let up = CGEvent(keyboardEventSource: nil, virtualKey: 0, keyDown: false) else { continue }
                down.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                up.keyboardSetUnicodeString(stringLength: u.count, unicodeString: &u)
                down.post(tap: .cghidEventTap); up.post(tap: .cghidEventTap)
            case .unsupported:
                continue   // multi-char unknown token (no keycode, not a single char)
            }
        }
    }

    /// How a non-modifier `keypress` key is realized. Pure + `internal` so it is
    /// unit-testable without synthesizing real events.
    enum KeyDispatch: Equatable { case keycode(CGKeyCode), unicode(String), unsupported }
    static func keyDispatch(_ key: String) -> KeyDispatch {
        if let c = keyCode(key) { return .keycode(c) }
        if key.count == 1 { return .unicode(key) }
        return .unsupported
    }

    private static func isModifier(_ k: String) -> Bool {
        ["CMD","COMMAND","META","SUPER","CTRL","CONTROL","ALT","OPTION","SHIFT","FN"].contains(k.uppercased())
    }
    private static func modifierFlags(_ keys: [String]) -> CGEventFlags {
        var f: CGEventFlags = []
        for k in keys.map({ $0.uppercased() }) {
            switch k {
            case "CMD","COMMAND","META","SUPER": f.insert(.maskCommand)
            case "CTRL","CONTROL": f.insert(.maskControl)
            case "ALT","OPTION": f.insert(.maskAlternate)
            case "SHIFT": f.insert(.maskShift)
            case "FN": f.insert(.maskSecondaryFn)
            default: break
            }
        }
        return f
    }

    /// Map OpenAI key names to macOS virtual keycodes (US layout).
    private static func keyCode(_ key: String) -> CGKeyCode? {
        let k = key.uppercased()
        let named: [String: CGKeyCode] = [
            "ENTER": 0x24, "RETURN": 0x24, "TAB": 0x30, "SPACE": 0x31, "DELETE": 0x33,
            "BACKSPACE": 0x33, "ESC": 0x35, "ESCAPE": 0x35, "ARROWLEFT": 0x7B,
            "LEFT": 0x7B, "ARROWRIGHT": 0x7C, "RIGHT": 0x7C, "ARROWDOWN": 0x7D,
            "DOWN": 0x7D, "ARROWUP": 0x7E, "UP": 0x7E, "HOME": 0x73, "END": 0x77,
            "PAGEUP": 0x74, "PAGEDOWN": 0x79, "FORWARDDELETE": 0x75,
            "F1": 0x7A, "F2": 0x78, "F3": 0x63, "F4": 0x76, "F5": 0x60, "F6": 0x61,
            "F7": 0x62, "F8": 0x64, "F9": 0x65, "F10": 0x6D, "F11": 0x67, "F12": 0x6F,
        ]
        if let c = named[k] { return c }
        let letters = "ABCDEFGHIJKLMNOPQRSTUVWXYZ"
        let codes: [CGKeyCode] = [0,11,8,2,14,3,5,4,34,38,40,37,46,45,31,35,12,15,1,17,32,9,13,7,16,6]
        if k.count == 1, let idx = letters.firstIndex(of: Character(k)) {
            return codes[letters.distance(from: letters.startIndex, to: idx)]
        }
        let digits: [String: CGKeyCode] = ["0":29,"1":18,"2":19,"3":20,"4":21,"5":23,"6":22,"7":26,"8":28,"9":25]
        if let c = digits[k] { return c }
        // Unshifted US-layout punctuation — given real keycodes so chords like
        // ⌘- / ⌘= / ⌘/ carry their modifier (the prior code had none, so these
        // fell through to a modifier-less Unicode insert). Matched on the raw key
        // (punctuation is case-invariant). SHIFTED symbols (+, :, ?, …) have no
        // direct keycode and still take the Unicode path.
        let punct: [String: CGKeyCode] = [
            "-": 0x1B, "=": 0x18, "[": 0x21, "]": 0x1E, "\\": 0x2A, ";": 0x29,
            "'": 0x27, ",": 0x2B, ".": 0x2F, "/": 0x2C, "`": 0x32,
        ]
        if let c = punct[key] { return c }
        return nil
    }
}
#endif
