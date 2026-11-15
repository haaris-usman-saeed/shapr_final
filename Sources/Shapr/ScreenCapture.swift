import AppKit
import ApplicationServices
import ScreenCaptureKit
import Vision

/// Grabs a region of the screen (never Shapr's own windows) with ScreenCaptureKit.
enum ScreenCapture {
    enum CaptureError: LocalizedError {
        case noPermission, noDisplay
        var errorDescription: String? {
            switch self {
            case .noPermission: return "Shapr needs Screen Recording access to capture the screen."
            case .noDisplay: return "Couldn't find that display."
            }
        }
    }

    static var hasPermission: Bool { CGPreflightScreenCaptureAccess() }

    /// Shows the system prompt the first time; after that, the user turns it on in System Settings.
    static func requestPermission() { CGRequestScreenCaptureAccess() }

    static func openSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture") {
            NSWorkspace.shared.open(url)
        }
    }

    /// `rect` is in global AppKit coordinates (origin bottom-left of the main screen).
    static func capture(rect: CGRect, on screen: NSScreen) async throws -> CGImage {
        guard hasPermission else { throw CaptureError.noPermission }
        let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) else { throw CaptureError.noDisplay }
        let me = content.applications.filter { $0.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, excludingApplications: me, exceptingWindows: [])

        let config = SCStreamConfiguration()
        // sourceRect is in the display's own points, origin top-left.
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY,
                                   width: rect.width, height: rect.height)
        let scale = screen.backingScaleFactor
        config.width = max(1, Int(rect.width * scale))
        config.height = max(1, Int(rect.height * scale))
        config.showsCursor = false
        config.captureResolution = .best
        return try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    /// The focused window of `app` (in AppKit screen coordinates) and its screen; the screen under the
    /// pointer when there's no window to read.
    @MainActor
    static func frontWindow(of app: NSRunningApplication?) -> (CGRect, NSScreen) {
        let fallbackScreen = NSScreen.underMouse ?? NSScreen.main ?? NSScreen.screens[0]
        guard let app, let primary = NSScreen.screens.first else { return (fallbackScreen.frame, fallbackScreen) }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.5)
        var winRef: CFTypeRef?
        var posRef: CFTypeRef?
        var sizeRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXFocusedWindowAttribute as CFString, &winRef) == .success, let winRef,
              CFGetTypeID(winRef) == AXUIElementGetTypeID() else { return (fallbackScreen.frame, fallbackScreen) }
        let win = winRef as! AXUIElement
        var pos = CGPoint.zero, size = CGSize.zero
        guard AXUIElementCopyAttributeValue(win, kAXPositionAttribute as CFString, &posRef) == .success,
              AXUIElementCopyAttributeValue(win, kAXSizeAttribute as CFString, &sizeRef) == .success,
              let p = posRef, let z = sizeRef,
              AXValueGetValue(p as! AXValue, .cgPoint, &pos), AXValueGetValue(z as! AXValue, .cgSize, &size), size.width > 50, size.height > 50
        else { return (fallbackScreen.frame, fallbackScreen) }
        // Accessibility measures from the top-left of the main display; AppKit from the bottom-left.
        let rect = CGRect(x: pos.x, y: primary.frame.maxY - pos.y - size.height, width: size.width, height: size.height)
        let screen = NSScreen.screens.first { $0.frame.contains(CGPoint(x: rect.midX, y: rect.midY)) } ?? fallbackScreen
        let visible = rect.intersection(screen.frame)
        return (visible.isNull || visible.width < 50 ? screen.frame : visible, screen)
    }

    /// A smaller PNG for sending to an AI: long side at most `maxSide` pixels (sharp enough to read, quick to send).
    static func pngForAI(_ image: CGImage, maxSide: Int = 1568) -> Data? {
        let longSide = max(image.width, image.height)
        guard longSide > maxSide else { return png(image) }
        let scale = Double(maxSide) / Double(longSide)
        let w = Int((Double(image.width) * scale).rounded()), h = Int((Double(image.height) * scale).rounded())
        guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: 0,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { return png(image) }
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage().flatMap(png) ?? png(image)
    }

    static func png(_ image: CGImage) -> Data? {
        NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])
    }
}

/// Reads text out of an image on this Mac with Vision.
enum OCR {
    static func text(in image: CGImage) async -> String {
        await Task.detached(priority: .userInitiated) { recognize(image) }.value
    }

    static func recognize(_ image: CGImage) -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true
        try? VNImageRequestHandler(cgImage: image).perform([request])
        let items = (request.results ?? []).compactMap { obs -> (box: CGRect, text: String)? in
            guard let s = obs.topCandidates(1).first?.string, !s.isEmpty else { return nil }
            return (obs.boundingBox, s)
        }
        // Group into rows (Vision's y axis points up), then read each row left to right.
        var rows: [[(box: CGRect, text: String)]] = []
        for item in items.sorted(by: { $0.box.midY > $1.box.midY }) {
            if let last = rows.last?.first, abs(last.box.midY - item.box.midY) < max(last.box.height, item.box.height) * 0.5 {
                rows[rows.count - 1].append(item)
            } else {
                rows.append([item])
            }
        }
        return rows.map { $0.sorted { $0.box.minX < $1.box.minX }.map(\.text).joined(separator: " ") }
            .joined(separator: "\n")
    }

    /// A few words about a picture with little or no text, so auto-sort has something to go on.
    static func labels(for image: CGImage, limit: Int = 3) -> [String] {
        let request = VNClassifyImageRequest()
        try? VNImageRequestHandler(cgImage: image).perform([request])
        return (request.results ?? [])
            .filter { $0.confidence > 0.3 }
            .prefix(limit)
            .map { $0.identifier.replacingOccurrences(of: "_", with: " ") }
    }
}

/// Which app and page a screen region came from.
@MainActor
enum ScreenSource {
    struct Info {
        var appName: String?
        var bundleID: String?
        var title: String?
        var url: String?
    }


    /// The frontmost normal window under `point` (global AppKit coordinates), skipping Shapr's own.
    static func at(_ point: CGPoint) -> Info {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let cgPoint = CGPoint(x: point.x, y: mainHeight - point.y)
        let me = ProcessInfo.processInfo.processIdentifier
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]] ?? []
        for w in list {
            guard (w[kCGWindowLayer as String] as? Int) == 0,
                  let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid != me,
                  let b = w[kCGWindowBounds as String] as? [String: CGFloat],
                  CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0).contains(cgPoint)
            else { continue }
            let app = NSRunningApplication(processIdentifier: pid)
            var info = Info(appName: app?.localizedName ?? w[kCGWindowOwnerName as String] as? String,
                            bundleID: app?.bundleIdentifier,
                            title: (w[kCGWindowName as String] as? String)?.nonEmpty)
            if let bid = app?.bundleIdentifier, let page = CaptureService.browserInfo(bundleID: bid) {
                info.url = page.url
                info.title = page.title ?? info.title
            }
            return info
        }
        return Info()
    }
}

/// Fires when a modifier key (Control by default) is tapped twice quickly on its own.
@MainActor
final class DoubleTapDetector {
    enum Key: String, CaseIterable, Identifiable {
        case command, control, option, off
        var id: String { rawValue }
        var title: String {
            switch self {
            case .command: return "Double-tap Command (⌘⌘)"
            case .control: return "Double-tap Control (⌃⌃)"
            case .option: return "Double-tap Option (⌥⌥)"
            case .off: return "Off"
            }
        }
        var flag: NSEvent.ModifierFlags {
            switch self {
            case .command: return .command
            case .option: return .option
            default: return .control
            }
        }
        var keyCodes: Set<UInt16> {
            switch self {
            case .command: return [55, 54]
            case .option: return [58, 61]
            default: return [59, 62]
            }
        }
        var symbol: String {
            switch self {
            case .command: return "⌘⌘"
            case .control: return "⌃⌃"
            case .option: return "⌥⌥"
            case .off: return "Off"
            }
        }

        static let defaultsKey = "circleKey"
        static var current: Key {
            get { UserDefaults.standard.string(forKey: defaultsKey).flatMap(Key.init) ?? .command }
            set { UserDefaults.standard.set(newValue.rawValue, forKey: defaultsKey) }
        }
    }

    /// Read live, so changing it in Settings takes effect right away.
    var key: Key { Key.current }
    /// True once Shapr is actually hearing modifier keys system-wide.
    private(set) static var isListening = false
    private let onDoubleTap: () -> Void
    private var tap: CFMachPort?
    private var tapSource: CFRunLoopSource?
    private var fallbackMonitors: [Any] = []
    private var retry: Timer?
    private var downAt: Date?
    private var usedWithOtherInput = false
    private var lastTap: Date?

    /// Listens with an event tap. Hearing keys in other apps needs Accessibility, and a listener set up
    /// before that permission arrives never starts hearing, so until it's granted Shapr checks every
    /// two seconds and starts listening the moment it is (no relaunch needed).
    init(listen: Bool = true, onDoubleTap: @escaping () -> Void) {
        self.onDoubleTap = onDoubleTap
        if listen, !startListening() {
            retry = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] t in
                MainActor.assumeIsolated {
                    if self?.startListening() != false { t.invalidate() }
                }
            }
        }
    }

    deinit {
        retry?.invalidate()
        fallbackMonitors.forEach(NSEvent.removeMonitor)
        if let tap { CGEvent.tapEnable(tap: tap, enable: false) }
        if let tapSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), tapSource, .commonModes) }
    }

    private func startListening() -> Bool {
        guard AXIsProcessTrusted() else { return false }
        let types: [CGEventType] = [.flagsChanged, .keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel]
        let mask = types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << $1.rawValue) }
        let callback: CGEventTapCallBack = { _, type, event, refcon in
            if let refcon {
                let me = Unmanaged<DoubleTapDetector>.fromOpaque(refcon).takeUnretainedValue()
                MainActor.assumeIsolated { me.handle(type, event) }
            }
            return Unmanaged.passUnretained(event)
        }
        if let t = CGEvent.tapCreate(tap: .cgSessionEventTap, place: .headInsertEventTap, options: .listenOnly,
                                     eventsOfInterest: mask, callback: callback,
                                     userInfo: Unmanaged.passUnretained(self).toOpaque()) {
            let src = CFMachPortCreateRunLoopSource(nil, t, 0)
            CFRunLoopAddSource(CFRunLoopGetMain(), src, .commonModes)
            CGEvent.tapEnable(tap: t, enable: true)
            tap = t
            tapSource = src
        } else {
            // Very unlikely once trusted, but keep the old way as a backup.
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
                MainActor.assumeIsolated { self?.flags(keyCode: e.keyCode, mods: e.modifierFlags) }
            }) { fallbackMonitors.append(m) }
            if let m = NSEvent.addGlobalMonitorForEvents(matching: [.keyDown, .leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel],
                                                        handler: { [weak self] _ in MainActor.assumeIsolated { self?.otherInput() } }) {
                fallbackMonitors.append(m)
            }
            if let m = NSEvent.addLocalMonitorForEvents(matching: [.flagsChanged], handler: { [weak self] e in
                MainActor.assumeIsolated { self?.flags(keyCode: e.keyCode, mods: e.modifierFlags) }
                return e
            }) { fallbackMonitors.append(m) }
        }
        Self.isListening = true
        return true
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        case .flagsChanged:
            let code = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            flags(keyCode: code, mods: NSEvent.ModifierFlags(rawValue: UInt(event.flags.rawValue)))
        default:
            otherInput()
        }
    }

    func otherInput() {
        if downAt != nil { usedWithOtherInput = true }
        lastTap = nil
    }

    /// One modifier change. Public to the module so the self-test can tap keys without a keyboard.
    func flags(keyCode: UInt16, mods raw: NSEvent.ModifierFlags) {
        guard key != .off, key.keyCodes.contains(keyCode) else {
            // Another modifier changed: not a clean tap.
            if downAt != nil { usedWithOtherInput = true }
            return
        }
        let mods = raw.intersection(.deviceIndependentFlagsMask)
        let others = NSEvent.ModifierFlags([.command, .option, .control, .shift]).subtracting(key.flag)
        if mods.contains(key.flag) {
            downAt = Date()
            usedWithOtherInput = !mods.intersection(others).isEmpty
        } else if let down = downAt {
            downAt = nil
            let now = Date()
            guard !usedWithOtherInput, now.timeIntervalSince(down) < 0.35 else { lastTap = nil; return }
            if let last = lastTap, now.timeIntervalSince(last) < 0.45 {
                lastTap = nil
                onDoubleTap()
            } else {
                lastTap = now
            }
        }
    }
}
