import AppKit
import ApplicationServices
import ShaprCore

/// One read of an allowed window. Raw window text never leaves `FlowReader`: it is reduced to
/// salient lines (errors, shell commands) on the background thread that read it.
struct FlowReading: Sendable {
    var title: String?
    var documentPath: String?
    var url: String?
    var projectHint: String?
    var salient: String?
    var skipped: String?
    var ms: Double
}

/// Reads the front window of an app Shapr Flow is allowed to observe. Accessibility only, with short
/// timeouts and a node budget. It never clicks, types, scrolls, takes screenshots or touches the clipboard.
enum FlowReader {
    static let browsers: Set<String> = [
        "com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta",
        "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    /// AppleScript runs one at a time, off the main thread.
    private static let scriptQueue = DispatchQueue(label: "app.shapr.flow.applescript", qos: .utility)

    private static let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXToolbar", "AXScrollBar", "AXButton", "AXPopUpButton",
                                                 "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXTabGroup", "AXSplitter",
                                                 "AXIncrementor", "AXDisclosureTriangle", "AXImage", "AXSearchField", "AXSecureTextField"]

    static func read(pid: pid_t, bundleID: String, wantText: Bool) -> FlowReading {
        let started = DispatchTime.now()
        func done(_ r: FlowReading) -> FlowReading {
            var r = r
            r.ms = Double(DispatchTime.now().uptimeNanoseconds - started.uptimeNanoseconds) / 1e6
            return r
        }
        var r = FlowReading(ms: 0)
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.3)
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = ChatReader.attr(app, kAXFocusedWindowAttribute) ?? ChatReader.attr(app, kAXMainWindowAttribute) else {
            r.skipped = "no window"
            return done(r)
        }
        // Typing a password right now: read nothing at all.
        if let focused: AXUIElement = ChatReader.attr(app, kAXFocusedUIElementAttribute), isSecure(focused) {
            r.skipped = "secure field"
            return done(r)
        }
        r.title = (ChatReader.attr(window, kAXTitleAttribute) as String?)?.nonEmpty
        if let doc: String = ChatReader.attr(window, kAXDocumentAttribute), let u = URL(string: doc), u.isFileURL {
            r.documentPath = u.path
            r.projectHint = projectFolder(for: u)
        }
        if browsers.contains(bundleID) {
            guard let page = browserPage(bundleID) else { r.skipped = "private window or no page"; return done(r) }
            r.url = page.url
            r.title = page.title ?? r.title
        }
        if wantText {
            var lines: [String] = []
            var count = 0
            walk(window, into: &lines, count: &count, maxNodes: 3000, deadline: Date().addingTimeInterval(0.5), depth: 0)
            let salient = Salience.lines(in: lines.joined(separator: "\n"))
            if !salient.isEmpty { r.salient = salient.map(\.text).joined(separator: "\n") }
        }
        return done(r)
    }

    private static func isSecure(_ el: AXUIElement) -> Bool {
        let role: String? = ChatReader.attr(el, kAXRoleAttribute)
        let subrole: String? = ChatReader.attr(el, kAXSubroleAttribute)
        return role == "AXSecureTextField" || subrole == "AXSecureTextField"
    }

    private static func walk(_ el: AXUIElement, into lines: inout [String], count: inout Int, maxNodes: Int, deadline: Date, depth: Int) {
        count += 1
        let keys = [kAXRoleAttribute, kAXSubroleAttribute, kAXValueAttribute, kAXChildrenAttribute] as CFArray
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, keys, [], &values) == .success, let arr = values as? [Any], arr.count == 4 else { return }
        let role = arr[0] as? String ?? ""
        let subrole = arr[1] as? String ?? ""
        guard !skipRoles.contains(role), subrole != "AXSecureTextField" else { return }
        if ["AXStaticText", "AXTextArea", "AXTextField", "AXHeading"].contains(role), let v = (arr[2] as? String)?.nonEmpty {
            // Terminals keep their whole scrollback in one text area: the newest part is at the end.
            lines.append(String(v.suffix(20_000)))
        }
        guard role != "AXStaticText", depth < 60, let kids = arr[3] as? [AXUIElement] else { return }
        for k in kids.suffix(400) {
            guard count < maxNodes, Date() < deadline else { break }
            walk(k, into: &lines, count: &count, maxNodes: maxNodes, deadline: deadline, depth: depth + 1)
        }
    }

    /// The repository or project folder a file belongs to: the nearest folder with .git, Package.swift or package.json.
    static func projectFolder(for file: URL) -> String? {
        var dir = file.deletingLastPathComponent()
        let fm = FileManager.default
        for _ in 0..<8 {
            for marker in [".git", "Package.swift", "package.json", "pyproject.toml", "Cargo.toml", "go.mod"]
                where fm.fileExists(atPath: dir.appendingPathComponent(marker).path) {
                return dir.lastPathComponent
            }
            let up = dir.deletingLastPathComponent()
            if up.path == dir.path || up.path == "/" || up.path == fm.homeDirectoryForCurrentUser.path { break }
            dir = up
        }
        return nil
    }

    /// Front tab address and title. Nil for Chrome-family incognito windows (Safari can't tell; see the privacy spec).
    static func browserPage(_ bundleID: String) -> (url: String?, title: String?)? {
        let script: String
        if bundleID.hasPrefix("com.apple.Safari") {
            script = """
            tell application id "\(bundleID)"
              if (count of documents) > 0 then return {URL of front document, name of front document, "normal"}
            end tell
            """
        } else {
            script = """
            tell application id "\(bundleID)"
              if (count of windows) > 0 then return {URL of active tab of front window, title of active tab of front window, mode of front window}
            end tell
            """
        }
        return scriptQueue.sync {
            var err: NSDictionary?
            guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err), out.numberOfItems >= 3 else { return nil }
            if out.atIndex(3)?.stringValue == "incognito" { return nil }
            return (out.atIndex(1)?.stringValue?.nonEmpty, out.atIndex(2)?.stringValue?.nonEmpty)
        }
    }
}

/// Watches for meaningful activity in allowed apps: app switches, window and title changes, and a
/// slow re-read while you keep working in the same window. No keyboard monitoring, no clipboard
/// watching, no screenshots, no timers while nothing is happening.
@MainActor
final class ActivityObserver {
    private let engine: FlowEngine
    /// The app needs a decision: show the prompt.
    var onNeedsPermission: (NSRunningApplication) -> Void = { _ in }
    var onRead: () -> Void = {}

    private var tokens: [NSObjectProtocol] = []
    private var distributed: [NSObjectProtocol] = []
    private var debounce: DispatchWorkItem?
    private var settle: DispatchWorkItem?
    private var front: NSRunningApplication?
    private var axObserver: AXObserver?
    private var axPID: pid_t = 0
    private var observedWindow: AXUIElement?
    private var lastTextRead: [String: Date] = [:]
    private var lastTitle: [String: String] = [:]
    private var reading = false
    private var pendingRead = false
    private var systemSuspended = false
    private(set) var running = false

    init(engine: FlowEngine) { self.engine = engine }

    func start() {
        guard !running else { return }
        running = true
        let ws = NSWorkspace.shared.notificationCenter
        tokens = [
            ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { self?.activated(app) }
            },
            ws.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] n in
                let app = n.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                MainActor.assumeIsolated { if let b = app?.bundleIdentifier { self?.engine.noteDeactivated(b) } }
            },
            ws.addObserver(forName: NSWorkspace.willSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            ws.addObserver(forName: NSWorkspace.screensDidSleepNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            ws.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            },
            ws.addObserver(forName: NSWorkspace.screensDidWakeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            },
        ]
        let dc = DistributedNotificationCenter.default()
        distributed = [
            dc.addObserver(forName: Notification.Name("com.apple.screenIsLocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.suspend() }
            },
            dc.addObserver(forName: Notification.Name("com.apple.screenIsUnlocked"), object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.wake() }
            },
        ]
        activated(NSWorkspace.shared.frontmostApplication)
    }

    /// Stops everything at once: notifications, the Accessibility observer, pending reads.
    func stop() {
        running = false
        tokens.forEach { NSWorkspace.shared.notificationCenter.removeObserver($0) }
        distributed.forEach { DistributedNotificationCenter.default().removeObserver($0) }
        tokens = []
        distributed = []
        debounce?.cancel()
        settle?.cancel()
        detachAX()
        engine.session.invalidate()
    }

    private func suspend() {
        systemSuspended = true
        debounce?.cancel()
        settle?.cancel()
        engine.suspendForSystem()
    }

    private func wake() {
        guard systemSuspended else { return }
        systemSuspended = false
        activated(NSWorkspace.shared.frontmostApplication)
    }

    /// Re-evaluate the front app (after a permission change, or Resume).
    func refresh() { activated(NSWorkspace.shared.frontmostApplication) }

    private func activated(_ app: NSRunningApplication?) {
        guard running, let app, let b = app.bundleIdentifier, b != Bundle.main.bundleIdentifier else { return }
        if let prev = front?.bundleIdentifier, prev != b { engine.noteDeactivated(prev) }
        front = app
        engine.noteActivated(b)
        settle?.cancel()
        debounce?.cancel()
        // Rapid switching (⌘-Tab through apps) settles before anything is looked at.
        let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.evaluate(app) } }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0, execute: work)
    }

    private func evaluate(_ app: NSRunningApplication) {
        guard running, !systemSuspended, front?.processIdentifier == app.processIdentifier, let b = app.bundleIdentifier else { return }
        switch engine.decision(for: b) {
        case .ask:
            detachAX()
            onNeedsPermission(app)
        case .observe:
            attachAX(app)
            scheduleRead(app, titleChanged: true)
        case .deny:
            detachAX()
        }
    }

    // MARK: Reads

    private func scheduleRead(_ app: NSRunningApplication, titleChanged: Bool) {
        guard let b = app.bundleIdentifier else { return }
        if reading { pendingRead = true; return }
        guard let ticket = engine.ticket(for: b) else { return }
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled || ProcessInfo.processInfo.thermalState.rawValue >= ProcessInfo.ThermalState.serious.rawValue
        let gap: TimeInterval = lowPower ? 60 : 15
        let wantText = titleChanged || Date().timeIntervalSince(lastTextRead[b] ?? .distantPast) > gap
        if wantText { lastTextRead[b] = Date() }
        reading = true
        let pid = app.processIdentifier
        let name = app.localizedName ?? b
        Task { [weak self] in
            let r = await Task.detached(priority: .utility) { FlowReader.read(pid: pid, bundleID: b, wantText: wantText) }.value
            guard let self else { return }
            self.reading = false
            self.engine.metrics.record("read", ms: r.ms)
            if let s = r.skipped { self.engine.metrics.count("reads.skipped." + s.replacingOccurrences(of: " ", with: "_")) }
            if r.skipped == nil {
                let now = Date()
                let focus = ObservationEvent(at: now, sessionID: nil, kind: .focus, bundleID: b, appName: name, windowTitle: r.title,
                                             documentPath: r.documentPath, url: r.url, projectHint: r.projectHint)
                self.engine.submit(focus, ticket: ticket)
                if let text = r.salient {
                    var content = focus
                    content.id = UUID()
                    content.kind = .content
                    content.text = text
                    self.engine.submit(content, ticket: ticket)
                }
                if let t = r.title { self.lastTitle[b] = t }
                self.onRead()
            }
            if self.pendingRead, let f = self.front, f.bundleIdentifier == b {
                self.pendingRead = false
                self.scheduleRead(f, titleChanged: false)
            }
            self.scheduleSettle(app)
        }
    }

    /// While you keep working in the same allowed window, look again now and then — only if you've
    /// touched the keyboard or mouse recently (an idle-time check; no keystrokes are seen).
    private func scheduleSettle(_ app: NSRunningApplication) {
        settle?.cancel()
        let lowPower = ProcessInfo.processInfo.isLowPowerModeEnabled
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.running, !self.systemSuspended, self.front?.processIdentifier == app.processIdentifier else { return }
                let idle = CGEventSource.secondsSinceLastEventType(.combinedSessionState, eventType: CGEventType(rawValue: ~0)!)
                if idle < 60 { self.scheduleRead(app, titleChanged: false) } else { self.scheduleSettle(app) }
            }
        }
        settle = work
        DispatchQueue.main.asyncAfter(deadline: .now() + (lowPower ? 180 : 60), execute: work)
    }

    // MARK: Accessibility notifications (window and title changes)

    private func attachAX(_ app: NSRunningApplication) {
        guard app.processIdentifier != axPID else { return }
        detachAX()
        var obs: AXObserver?
        let callback: AXObserverCallback = { _, _, notification, refcon in
            guard let refcon else { return }
            let me = Unmanaged<ActivityObserver>.fromOpaque(refcon).takeUnretainedValue()
            let name = notification as String
            MainActor.assumeIsolated { me.axChanged(name) }
        }
        guard AXObserverCreate(app.processIdentifier, callback, &obs) == .success, let obs else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        let refcon = Unmanaged.passUnretained(self).toOpaque()
        for n in [kAXFocusedWindowChangedNotification, kAXMainWindowChangedNotification] {
            AXObserverAddNotification(obs, el, n as CFString, refcon)
        }
        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        axObserver = obs
        axPID = app.processIdentifier
        watchFocusedWindow()
    }

    private func watchFocusedWindow() {
        guard let obs = axObserver else { return }
        let el = AXUIElementCreateApplication(axPID)
        if let old = observedWindow { AXObserverRemoveNotification(obs, old, kAXTitleChangedNotification as CFString) }
        observedWindow = ChatReader.attr(el, kAXFocusedWindowAttribute)
        if let w = observedWindow {
            AXObserverAddNotification(obs, w, kAXTitleChangedNotification as CFString, Unmanaged.passUnretained(self).toOpaque())
        }
    }

    private func detachAX() {
        if let obs = axObserver {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(obs), .defaultMode)
        }
        axObserver = nil
        observedWindow = nil
        axPID = 0
    }

    private func axChanged(_ name: String) {
        guard running, let app = front, app.processIdentifier == axPID else { return }
        if name != (kAXTitleChangedNotification as String) { watchFocusedWindow() }
        debounce?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, let b = app.bundleIdentifier, self.engine.decision(for: b) == .observe else { return }
                self.scheduleRead(app, titleChanged: true)
            }
        }
        debounce = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5, execute: work)
    }
}
