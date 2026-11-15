import AppKit

let args = CommandLine.arguments

func argument(after flag: String) -> URL? {
    guard let i = args.firstIndex(of: flag), i + 1 < args.count else { return nil }
    return URL(fileURLWithPath: args[i + 1], isDirectory: true)
}

if args.contains("--selftest") || args.contains("--render") || args.contains("--make-icon") || args.contains("--share-smoke") {
    Keychain.blockedServices = [Keychain.defaultService]
}

if args.contains("--mcp") {
    MCPServer.runStdio()
} else if args.contains("--selftest") {
    // A real main run loop (not dispatchMain) so main-actor work runs on the main thread,
    // which AppKit windows require.
    _ = MainActor.assumeIsolated { NSApplication.shared }
    Task { @MainActor in exit(await SelfTest.run()) }
    RunLoop.main.run()
} else if let dir = argument(after: "--render") {
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        NSApp.setActivationPolicy(.prohibited)
        Render.run(to: dir)
    }
} else if let i = args.firstIndex(of: "--share-smoke"), i + 1 < args.count, let server = URL(string: args[i + 1]) {
    _ = MainActor.assumeIsolated { NSApplication.shared }
    Task { @MainActor in exit(await ShareSmoke.run(server: server)) }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--verify-update"), i + 1 < args.count {
    // Developer check: would this copy of Shapr accept the app at <path> as an update?
    let ok = MainActor.assumeIsolated { Updater.isTrusted(URL(fileURLWithPath: args[i + 1])) }
    print(ok ? "trusted" : "rejected")
    exit(ok ? 0 : 1)
} else if args.contains("--probe-downloads") {
    // Developer check, read-only: which ↓ button Shapr would press for each file link on the front Safari page.
    MainActor.assumeIsolated { LinkFinder.probeFrontPage() }
} else if let i = args.firstIndex(of: "--probe-chat") {
    // Developer check, read-only: what Shapr reads from the frontmost AI chat (after 3 seconds).
    // Optional: an output file, then an app's bundle ID to read instead of the front app.
    let report = ChatReader.probe(bundleID: i + 2 < args.count ? args[i + 2] : nil)
    if i + 1 < args.count { try? report.write(toFile: args[i + 1], atomically: true, encoding: .utf8) } else { print(report) }
    exit(0)
} else if let i = args.firstIndex(of: "--probe-window-text") {
    // Developer check, read-only: how much text Shapr reads from an app's front window. Sizes only,
    // never the text itself. Arguments: an output file, then the app's bundle ID.
    var report = "That app isn't running"
    if i + 2 < args.count, let app = NSRunningApplication.runningApplications(withBundleIdentifier: args[i + 2]).first {
        let started = Date()
        if let w = WindowText.read(pid: app.processIdentifier) {
            let lines = w.text.components(separatedBy: "\n")
            report = "Trusted: \(AXIsProcessTrusted()) · \(w.text.count) characters in \(lines.count) lines, "
                + "\(w.text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count) words, \(Int(Date().timeIntervalSince(started) * 1000)) ms"
        } else {
            report = "Trusted: \(AXIsProcessTrusted()) · couldn't read a window"
        }
    }
    if i + 1 < args.count { try? report.write(toFile: args[i + 1], atomically: true, encoding: .utf8) } else { print(report) }
    exit(0)
} else if let i = args.firstIndex(of: "--transcribe"), i + 1 < args.count {
    // Developer check: speech to text on this Mac, for an audio file (`say -o note.aiff "…"`).
    let url = URL(fileURLWithPath: args[i + 1])
    Task {
        do { print(try await VoiceRecorder.transcribe(file: url)); exit(0) } catch { print("error: \(error.localizedDescription)"); exit(1) }
    }
    RunLoop.main.run()
} else if let i = args.firstIndex(of: "--probe-form") {
    // Developer check: the form fields Shapr reads in the front window (after 3 s). With "fill", it also
    // fills test values into them (never submits) and reads them back. Use it on a test page only.
    let out = i + 1 < args.count ? args[i + 1] : nil
    let fill = args.contains("fill")
    Task { @MainActor in
        try? await Task.sleep(for: .seconds(3))
        guard let app = NSWorkspace.shared.frontmostApplication else { exit(1) }
        func describe(_ fields: [FormField]) -> String {
            fields.map { f in
                var line = "\(f.id). [\(f.kind)] \(f.label) = \(f.currentValue ?? "–")"
                if !f.options.isEmpty { line += "  options: " + f.options.joined(separator: " | ") }
                if f.isConsent { line += "  (consent: never ticked)" }
                return line
            }.joined(separator: "\n")
        }
        var report = "App: \(app.localizedName ?? "?")\n"
        var fields = FormScanner.scan(app: app)
        if fields.isEmpty { try? await Task.sleep(for: .milliseconds(600)); fields = FormScanner.scan(app: app) }
        report += describe(fields) + "\n"
        @MainActor func dump(_ el: AXUIElement, _ d: Int) {
            guard d < 4 else { return }
            let role: String = FormScanner.attr(el, kAXRoleAttribute) ?? ""
            let sub: String = FormScanner.attr(el, kAXSubroleAttribute) ?? ""
            let desc: String = FormScanner.attr(el, kAXDescriptionAttribute) ?? ""
            let value: Any? = FormScanner.attr(el, kAXValueAttribute)
            let title: String = FormScanner.attr(el, kAXTitleAttribute) ?? ""
            report += String(repeating: "  ", count: d) + "\(role)/\(sub) desc=\(desc) title=\(title) value=\(value.map { "\($0)" } ?? "nil")\n"
            for k in (FormScanner.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { dump(k, d + 1) }
        }
        if !fill { for f in fields where f.kind == .date { report += "Date field tree:\n"; dump(f.element, 0) } }
        if fill {
            let el = AXUIElementCreateApplication(app.processIdentifier)
            for f in fields where f.sensitive == nil && !f.isConsent {
                let value: String
                switch f.kind {
                case .text: value = "Test \(f.id)"
                case .choice: value = f.options.last ?? "Pakistan"
                case .checkbox: value = "yes"
                case .date: value = "2026-03-15"
                }
                let ok = f.kind == .text ? await FormScanner.fill(f, with: value, app: el) : await FormScanner.fill(choice: f, with: value, app: el)
                report += "fill \(f.id) → \(value): \(ok ? "ok" : "FAILED")\n"
            }
            try? await Task.sleep(for: .milliseconds(400))
            let after = FormScanner.scan(app: app)
            report += "After:\n" + describe(after) + "\n"
            for f in after where f.kind == .date { report += "Date field tree:\n"; dump(f.element, 0) }
        }
        if let out { try? report.write(toFile: out, atomically: true, encoding: .utf8) } else { print(report) }
        exit(0)
    }
    RunLoop.main.run()
} else if let dir = argument(after: "--showcase") {
    // Developer check: the floating surfaces on screen for a moment, captured with real Liquid Glass.
    _ = MainActor.assumeIsolated { NSApplication.shared }
    MainActor.assumeIsolated { NSApp.setActivationPolicy(.accessory) }
    Task { @MainActor in await Showcase.run(to: dir); exit(0) }
    RunLoop.main.run()
} else if args.contains("--probe-window") {
    // Developer check, read-only: the front window Shapr would read for "answer this using my screen",
    // next to macOS's own window list (no screenshot is taken).
    MainActor.assumeIsolated {
        let app = NSWorkspace.shared.frontmostApplication
        let (rect, screen) = ScreenCapture.frontWindow(of: app)
        let primaryTop = NSScreen.screens.first?.frame.maxY ?? 0
        print("App: \(app?.localizedName ?? "?")")
        print("Shapr's rect (AppKit): \(rect) on screen \(screen.frame)")
        print("Same rect, top-left origin: \(CGRect(x: rect.minX, y: primaryTop - rect.maxY, width: rect.width, height: rect.height))")
        let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] ?? []
        if let w = list.first(where: { ($0[kCGWindowOwnerPID as String] as? pid_t) == app?.processIdentifier && ($0[kCGWindowLayer as String] as? Int) == 0 }),
           let b = w[kCGWindowBounds as String] as? [String: CGFloat] {
            print("macOS window list (top-left origin): \(CGRect(x: b["X"] ?? 0, y: b["Y"] ?? 0, width: b["Width"] ?? 0, height: b["Height"] ?? 0))")
        }
    }
    exit(0)
} else if let i = args.firstIndex(of: "--probe-source"), i + 1 < args.count {
    // Developer check, read-only: what Shapr would keep from a link or folder (no tokens are used).
    Task { @MainActor in
        guard let src = PackSource.from(link: args[i + 1]) else { print("Not a link or folder Shapr can follow"); exit(1) }
        do {
            let scan: SourceScan
            switch src.kind {
            case .github: scan = try await GitHubSource.scan(repo: src.location, token: nil, known: [:])
            case .web: scan = try await WebSource.scan(link: src.location, knownRev: nil)
            case .folder: scan = try await FolderSource.scan(path: src.location, known: [:])
            case .notion: scan = try await NotionSource.scan(link: src.location, token: nil, knownRev: nil)
            case .page, .mail: print("\(src.kindTitle): updates from your screen whenever you open it"); exit(0)
            }
            print("\(src.kindTitle): \(scan.title ?? src.title) · \(scan.changed.count) item(s)")
            for item in scan.changed {
                print("- [\(item.key)] \(item.draft.title ?? "") · \(item.draft.text.count) chars · \(item.draft.text.firstLine.truncated(90))")
            }
        } catch {
            print("Couldn't update: \(error.localizedDescription)")
        }
        exit(0)
    }
    RunLoop.main.run()
} else if let dir = argument(after: "--make-icon") {
    MainActor.assumeIsolated { Render.makeIcon(to: dir) }
} else {
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let controller = AppController()
        app.delegate = controller
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(controller) { app.run() }
    }
}
