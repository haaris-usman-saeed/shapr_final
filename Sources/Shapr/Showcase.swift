import AppKit
import ScreenCaptureKit
import SwiftUI

/// `Shapr --showcase <dir>`: shows Shapr's floating surfaces on screen for a moment, over a busy
/// backdrop, and captures them. Offscreen renders can't draw real Liquid Glass (it samples what's
/// behind the window), so this is how the glass itself gets checked. Captures only Shapr's own windows.
@MainActor
enum Showcase {
    static func run(to dir: URL) async {
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        guard let screen = NSScreen.main else { return }
        let size = CGSize(width: 820, height: 600)
        let vf = screen.visibleFrame
        let frame = CGRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2, width: size.width, height: size.height)

        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-showcase-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let defaults = UserDefaults(suiteName: "app.shapr.showcase")!
        defaults.removePersistentDomain(forName: "app.shapr.showcase")
        let store = PackStore(root: tmp, defaults: defaults)
        let mat = store.createPack(name: "MAT223", emoji: nil, autoNamed: false)
        store.add(CaptureDraft(text: "Eigenvalues of A are the roots of det(A − λI) = 0. For each λ, solve (A − λI)v = 0 for the eigenspace.",
                               appName: "Safari", title: "Lecture 14 · Eigenvalues", url: "https://q.utoronto.ca/courses/mat223"), to: mat.id)
        let acme = store.createPack(name: "Acme", emoji: nil, autoNamed: false)
        store.add(CaptureDraft(text: "Ana: the proposal is due March 22.", appName: "Mail", title: "Call notes"), to: acme.id)
        let trip = store.createPack(name: "Japan Trip", emoji: nil, autoNamed: false)
        _ = store.createPack(name: "Bug 42", emoji: nil, autoNamed: false)
        store.equip(mat.id)

        let voice = VoiceModel()
        voice.preparing = false
        voice.text = "When is the Acme proposal due"
        voice.level = 0.55
        voice.hint = "Let go when you're done · esc cancels"
        voice.pack = store.pack(mat.id)

        let ask = AskModel()
        ask.scope = mat.id
        ask.question = "Find the eigenvalues of A = [2 1; 1 2]"
        ask.asked = ask.question
        ask.hits = AskEngine.hits(for: "eigenvalues det", in: [store.pack(mat.id)!])
        ask.answer = "Solve det(A − λI) = 0: (2 − λ)² − 1 = 0, so λ² − 4λ + 3 = 0 [1].\nAnswer: λ = 1 and λ = 3."
        ask.phase = .done("Claude Opus 5.5")

        let wheel = WheelModel()
        wheel.slots = store.wheelSlots.map { id in
            guard let p = store.pack(id) else { return WheelSlot(packID: nil, badge: "", name: "", count: 0) }
            return WheelSlot(packID: p.id, badge: PackStyle.initials(p.name), name: p.name, count: p.captures.count,
                             color: PackStyle.color(p.id), isEmoji: false, deep: PackStyle.deep(p.id),
                             latest: p.captures.last?.displayTitle)
        }
        wheel.equipped = store.wheelSlots.firstIndex(of: mat.id) ?? 0
        wheel.highlighted = store.wheelSlots.firstIndex(of: acme.id)
        wheel.sticky = true
        wheel.appeared = true

        let toast = ToastContent(icon: .pack(store.pack(acme.id)!), title: "Call notes with Ana",
                                 subtitle: "Mail · just now", actions: [ToastAction(title: "Undo"), ToastAction(title: "Move", style: .menu([]))],
                                 pack: store.pack(acme.id), eyebrow: "Added to")
        _ = trip

        let quick = QuickModel()
        quick.pack = store.pack(mat.id)
        quick.context = "Safari"
        quick.items = [
            QuickItem(id: "answer", symbol: "sparkle.magnifyingglass", title: "Answer this with MAT223", subtitle: "Reads your screen and works it out", keys: nil) {},
            QuickItem(id: "scoop", symbol: "plus.square.on.square", title: "Save to MAT223", subtitle: "The selection, or this page", keys: "⌥C") {},
            QuickItem(id: "ask", symbol: "questionmark.bubble", title: "Ask MAT223…", subtitle: "Get the answer here, from your notes", keys: nil) {},
            QuickItem(id: "voice", symbol: "mic", title: "Talk to Shapr", subtitle: "Say a command, ask a question, or save a note", keys: "⌥V") {},
            QuickItem(id: "switch", symbol: "circle.grid.cross", title: "Switch pack", subtitle: "Now: MAT223", keys: "⌥S") {},
        ]
        quick.selected = 0

        let surfaces: [(String, AnyView)] = [
            ("quick", AnyView(QuickView(model: quick))),
            ("voice", AnyView(VoiceView(model: voice))),
            ("toast", AnyView(ToastView(content: toast))),
            ("ask", AnyView(AskView(model: ask, store: store))),
            ("wheel", AnyView(WheelView(model: wheel))),
        ]
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let backdrop = NSWindow(contentRect: frame, styleMask: [.borderless], backing: .buffered, defer: false)
            backdrop.level = .floating
            backdrop.appearance = appearance
            backdrop.contentView = NSHostingView(rootView: ShowcaseBackdrop(dark: dark))
            backdrop.orderFrontRegardless()
            for (name, view) in surfaces {
                let panel = FloatingPanel(size: .zero, level: .statusBar)
                panel.appearance = appearance
                let host = NSHostingView(rootView: view)
                panel.contentView = host
                let fit = host.fittingSize
                panel.setFrame(CGRect(x: frame.midX - fit.width / 2, y: frame.midY - fit.height / 2, width: fit.width, height: fit.height), display: true)
                panel.orderFrontRegardless()
                try? await Task.sleep(for: .milliseconds(650))
                if let img = await capture(frame, on: screen) {
                    let out = dir.appendingPathComponent("\(name)\(dark ? "-dark" : "").png")
                    try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?.write(to: out)
                }
                panel.orderOut(nil)
            }
            backdrop.orderOut(nil)
        }
        // The library: a real window, so the native toolbar, glass sidebar and inspector show.
        store.add(CaptureDraft(text: "Diagonalize A when it has n independent eigenvectors: A = PDP⁻¹.", appName: "Preview",
                               title: "Lecture 15 · Diagonalization", url: "https://q.utoronto.ca/courses/mat223/l15"), to: mat.id)
        let state = LibraryState()
        state.selection = mat.id
        state.selectedCapture = store.pack(mat.id)?.captures.first?.id
        for dark in [false, true] {
            let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
            let w = NSWindow(contentRect: NSRect(x: frame.minX - 140, y: frame.minY - 40, width: 1100, height: 680),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
            LibraryWindow.style(w)
            w.appearance = appearance
            w.level = .floating
            let host = NSHostingView(rootView: LibraryView(actions: LibraryActions()).environmentObject(store).environmentObject(state)
                .environmentObject(SourceSync(store: store)).environmentObject(SharedPacks(store: store)))
            host.sceneBridgingOptions = [.title, .toolbars]
            w.contentView = host
            w.orderFrontRegardless()
            try? await Task.sleep(for: .milliseconds(900))
            if let img = await capture(w.frame, on: screen) {
                try? NSBitmapImageRep(cgImage: img).representation(using: .png, properties: [:])?
                    .write(to: dir.appendingPathComponent("library\(dark ? "-dark" : "").png"))
            }
            w.orderOut(nil)
        }
        print("Showcase saved to \(dir.path)")
    }

    /// Only Shapr's own windows, so nothing else on screen is captured.
    private static func capture(_ rect: CGRect, on screen: NSScreen) async -> CGImage? {
        guard let content = try? await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true) else { return nil }
        let id = screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID
        guard let display = content.displays.first(where: { $0.displayID == id }) else { return nil }
        let mine = content.windows.filter { $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier }
        let filter = SCContentFilter(display: display, including: mine)
        let config = SCStreamConfiguration()
        config.sourceRect = CGRect(x: rect.minX - screen.frame.minX, y: screen.frame.maxY - rect.maxY, width: rect.width, height: rect.height)
        config.width = Int(rect.width * screen.backingScaleFactor)
        config.height = Int(rect.height * screen.backingScaleFactor)
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}

/// Something busy behind the glass: color, shapes and text, like a real desktop.
private struct ShowcaseBackdrop: View {
    let dark: Bool
    var body: some View {
        ZStack(alignment: .topLeading) {
            LinearGradient(colors: dark ? [Color(red: 0.12, green: 0.1, blue: 0.3), Color(red: 0.35, green: 0.1, blue: 0.3), Color(red: 0.05, green: 0.2, blue: 0.3)]
                                        : [Color(red: 0.55, green: 0.75, blue: 1), Color(red: 1, green: 0.7, blue: 0.6), Color(red: 0.7, green: 0.95, blue: 0.75)],
                           startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.orange.opacity(0.8)).frame(width: 220).offset(x: 520, y: 40)
            Circle().fill(Color.blue.opacity(0.7)).frame(width: 180).offset(x: 60, y: 360)
            VStack(alignment: .leading, spacing: 10) {
                Text("MAT223 · Problem Set 6").font(.system(size: 30, weight: .bold))
                ForEach(0..<9, id: \.self) { i in
                    Text("Question \(i + 1). Let A be a 2×2 matrix. Find its eigenvalues and a basis for each eigenspace.")
                        .font(.system(size: 15))
                }
            }
            .foregroundStyle(dark ? .white : .black)
            .padding(36)
        }
        .frame(width: 820, height: 600)
    }
}
