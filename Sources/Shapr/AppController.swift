import AppKit
import Carbon
import Combine
import SwiftUI

@MainActor
final class AppController: NSObject, NSApplicationDelegate, NSMenuDelegate, NSWindowDelegate {
    let store = PackStore(root: PackStore.defaultRoot())
    let sorter = Sorter()
    let toast = ToastController()
    private lazy var wheel: WheelController = {
        let w = WheelController(
            store: store,
            onEquip: { [weak self] id in self?.equip(id, announce: true) },
            onNewPack: { [weak self] slot in self?.newPack(inSlot: slot) }
        )
        w.onAsk = { [weak self] id in self?.ask.open(scope: id) }
        return w
    }()
    lazy var sync = SourceSync(store: store)
    lazy var ask: AskController = {
        let a = AskController(store: store, toast: toast)
        a.onOpenCapture = { [weak self] packID, captureID in self?.showCapture(captureID, in: packID) }
        a.onSaveShot = { [weak self] draft, scope in await self?.saveShot(draft, into: scope) }
        return a
    }()
    private lazy var voice: VoiceNoteController = {
        let v = VoiceNoteController(toast: toast)
        v.destination = { [weak self] in self.flatMap { $0.store.pack($0.store.equippedPackID) } }
        v.onCommand = { [weak self] text in await self?.runVoice(text) ?? false }
        v.onSave = { [weak self] draft in
            guard let self else { return nil }
            let pid = await self.file(draft)
            if let pid { self.feedback.landed(title: draft.title ?? "Voice note", pack: self.store.pack(pid), image: nil) }
            return pid
        }
        return v
    }()

    private lazy var drop = DropController(store: store, toast: toast)
    private lazy var forms = FormFillController(store: store, toast: toast)
    private lazy var checkpoints = CheckpointController(store: store, toast: toast)
    private lazy var resume: ResumeController = {
        let r = ResumeController(store: store, toast: toast)
        r.onNeedsCheckpoint = { [weak self] id in self?.checkpoints.open(packID: id) }
        r.onInserted = { [weak self] handoff, app, packID, cp in self?.relay.startWatching(handoff, in: app, packID: packID, checkpoint: cp) }
        return r
    }()
    lazy var relay = RelayController(store: store, toast: toast)
    private let overlay = CaptureOverlayController()
    private var circleDetector: DoubleTapDetector?
    private lazy var suggester = FileSuggester(store: store, toast: toast, sorter: sorter)
    lazy var shares = SharedPacks(store: store)
    lazy var use = UseController(store: store, toast: toast)
    private let quick = QuickPanelController()
    private let feedback = CaptureFeedback()
    lazy var updater = Updater(toast: toast)
    private var screenCapturing = false

    private var statusItem: NSStatusItem!
    private var libraryWindow: NSWindow?
    private let libraryState = LibraryState()
    private var settingsWindow: NSWindow?
    private var shareWindows: [UUID: NSWindow] = [:]
    private var cancellables: Set<AnyCancellable> = []
    private var watcher: PackWatcher?
    private var scooping = false

    // MARK: Launch

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.mainMenu = Self.makeMainMenu()
        setupStatusItem()
        feedback.target = { [weak self] in self?.statusItem?.button?.window?.frame }
        feedback.pulseTarget = { [weak self] in self?.pulseStatusItem() }
        registerHotkeys()
        NotificationCenter.default.addObserver(forName: ShortcutSettings.changed, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.registerHotkeys() }
        }
        // Claude (through MCP), Finder and imports can change packs while the app runs.
        watcher = PackWatcher(path: store.packsDir.path) { [weak self] in
            MainActor.assumeIsolated { self?.store.load() }
        }
        sorter.prewarm()
        circleDetector = DoubleTapDetector { [weak self] in self?.startScreenCapture(.hover) }
        suggester.start()
        shares.onHeld = { [weak self] pack, n in
            self?.toast.show(ToastContent(icon: .symbol("hand.raised"), title: "\(n) new capture\(n == 1 ? "" : "s") in \(pack.name) need\(n == 1 ? "s" : "") a look",
                                          subtitle: "\(n == 1 ? "It might hold" : "They might hold") something private, so \(n == 1 ? "it isn't" : "they aren't") shared until you check.",
                                          actions: [ToastAction(title: "Review", style: .primary) { [weak self] in self?.safeShare(pack.id) }],
                                          pack: pack, eyebrow: "Live link"), duration: 10)
        }
        shares.start()
        updater.start()
        relay.start()
        sync.start()
        store.$equippedPackID.combineLatest(store.$packs)
            .sink { [weak self] _, _ in DispatchQueue.main.async { self?.updateStatusButton() } }
            .store(in: &cancellables)

        let firstRun = !UserDefaults.standard.bool(forKey: "didOnboard")
        if firstRun || !CaptureService.isTrusted {
            UserDefaults.standard.set(true, forKey: "didOnboard")
            showLibrary()
            if !CaptureService.isTrusted { CaptureService.requestTrust() }
        }
    }

    /// Double-clicking a .shapr file (or dropping it on the app icon) imports it.
    func application(_ application: NSApplication, open urls: [URL]) {
        for url in urls {
            if url.scheme == "shapr" { joinShared(url.absoluteString) }
            else if url.pathExtension.lowercased() == PackBundle.fileExtension { importPack(url) }
        }
    }

    // MARK: Live shared packs

    /// Joins a shared pack from a link (shapr://join/… from the pack page, or a pasted web link).
    func joinShared(_ link: String) {
        let working = toast.show(ToastContent(icon: .spinner, title: "Adding the shared pack…"), duration: nil)
        Task {
            do {
                let p = try await shares.join(link)
                toast.dismiss(ifToken: working)
                toast.show(ToastContent(icon: .pack(p), title: "\(p.name) is in your library",
                                        subtitle: "\(p.captures.count) capture\(p.captures.count == 1 ? "" : "s"). It stays up to date as it's shared.",
                                        actions: [ToastAction(title: "Open", style: .primary) { [weak self] in self?.showLibrary(select: p.id) }],
                                        pack: p, eyebrow: "Joined"), duration: 6)
            } catch {
                toast.dismiss(ifToken: working)
                toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't add that pack",
                                        subtitle: error.localizedDescription, tint: DS.warning), duration: 6)
            }
        }
    }

    /// Creates (or updates) the live link for a pack after Share Safely.
    private func shareLive(_ session: ShareSession, window: NSWindow?) {
        let working = toast.show(ToastContent(icon: .spinner, title: "Making a link for \(session.packName)…"), duration: nil)
        Task {
            do {
                let link = try await shares.share(session)
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(link.absoluteString, forType: .string)
                toast.dismiss(ifToken: working)
                window?.close()
                toast.show(ToastContent(icon: .symbol("link"), title: "Link copied",
                                        subtitle: "Anyone with it can see \(session.packName) and add it to Shapr. New captures are shared as you add them.",
                                        actions: [ToastAction(title: "Open page") { NSWorkspace.shared.open(link) }],
                                        pack: store.pack(session.packID), eyebrow: "Live link for"), duration: 8)
            } catch {
                toast.dismiss(ifToken: working)
                toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't make a link",
                                        subtitle: error.localizedDescription, tint: DS.warning), duration: 6)
            }
        }
    }

    @objc private func menuJoin() {
        let alert = NSAlert()
        alert.messageText = "Add a shared pack"
        alert.informativeText = "Paste the link someone sent you. The pack stays up to date as they add to it."
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 320, height: 24))
        field.placeholderString = ShareServer.pageURL("…").absoluteString
        if let s = NSPasteboard.general.string(forType: .string), ShareServer.packID(from: s) != nil { field.stringValue = s }
        alert.accessoryView = field
        alert.addButton(withTitle: "Add")
        alert.addButton(withTitle: "Cancel")
        NSApp.activate()
        alert.window.initialFirstResponder = field
        guard alert.runModal() == .alertFirstButtonReturn, let link = field.stringValue.nonEmpty else { return }
        joinShared(link)
    }

    @objc private func menuUpdates() { updater.check(silent: false) }
    @objc private func menuRelay(_ sender: NSMenuItem) {
        guard let name = sender.representedObject as? String else { return }
        relay.relay(to: name, from: NSWorkspace.shared.frontmostApplication)
    }
    @objc private func menuStopRelay() { relay.stopWatching() }

    // MARK: One shortcut (⌥⇧Space) and "Use this with my pack" (⌥⇧U)

    func useWithPack() {
        if use.isVisible { use.close(); return }
        use.open()
    }

    /// What you can do right now, beside the pointer, best guess first.
    func showQuick() {
        if quick.isVisible { quick.hide(); return }
        let started = Date()
        // Each row teaches its shortcut when the classic shortcuts are on; otherwise voice does it.
        let k: (String) -> String? = { ShortcutSettings.classic ? $0 : nil }
        let ctx = PointerContext.now()
        let equipped = store.pack(store.equippedPackID) ?? store.pack(store.activePackID)
        let pack = equipped ?? store.packs.max { $0.updated < $1.updated }
        let name = pack?.name ?? "your pack"
        var items: [QuickItem] = []
        if let sel = ctx.selection {
            items.append(QuickItem(id: "use", symbol: "sparkle.magnifyingglass", title: "Use with \(name)",
                                   subtitle: "What in your pack matters for “\(sel.singleLine.truncated(26))”", keys: k("⌥⇧U")) { [weak self] in
                self?.use.open(input: sel, context: ctx)
            })
            items.append(QuickItem(id: "scoop", symbol: "plus.square.on.square", title: "Scoop into \(equipped?.name ?? "a pack")",
                                   subtitle: equipped == nil ? "Shapr picks the pack" : "Save the selection", keys: "⌥C") { [weak self] in self?.scoop() })
        } else if ctx.inTextBox {
            items.append(QuickItem(id: "draft", symbol: "pencil.and.scribble", title: "Draft here with \(name)",
                                   subtitle: "Write what belongs in this box, from your pack", keys: k("⌥⇧D")) { [weak self] in self?.drop.open() })
        }
        // In an AI chat: carry this conversation into another AI, with nothing lost.
        let chatService = ctx.app.flatMap { a in ChatReader.quickService(pid: a.processIdentifier, bundleID: a.bundleIdentifier) }
        if let current = chatService {
            for name in ChatReader.services.map(\.name) where name != current {
                items.append(QuickItem(id: "relay-\(name)", symbol: "arrow.triangle.branch", title: "Continue in \(name)",
                                       subtitle: "Carries this chat, your rules and your pack over", keys: nil) { [weak self, app = ctx.app] in
                    self?.relay.relay(to: name, from: app)
                })
            }
        }
        if let p = pack, let cp = store.latestCheckpoint(for: p.id) {
            items.append(QuickItem(id: "continue", symbol: "arrow.uturn.right", title: "Continue: \(cp.title?.nonEmpty ?? p.name)",
                                   subtitle: cp.nextStep.nonEmpty.map { "Next: \($0)" }, keys: k("⌥⇧R")) { [weak self] in self?.resume.open() })
        }
        if ctx.selection == nil {
            items.append(QuickItem(id: "ask", symbol: "questionmark.bubble", title: "Ask \(equipped?.name ?? "your packs")…",
                                   subtitle: "Get the answer here, from your notes", keys: k("⌥⇧A")) { [weak self] in self?.ask.open() })
        }
        // A page, repo, Notion page or Mail thread: keep the pack up to date from it.
        if let app = ctx.app, let bid = app.bundleIdentifier, chatService == nil, let p = pack,
           bid == "com.apple.mail" || CaptureService.isBrowser(bid) {
            items.append(QuickItem(id: "live", symbol: "arrow.triangle.2.circlepath",
                                   title: bid == "com.apple.mail" ? "Keep this thread in \(p.name)" : "Keep this page updated in \(p.name)",
                                   subtitle: "Shapr adds it now and keeps it current", keys: nil) { [weak self] in
                self?.keepFrontUpdated(in: p.id, app: app)
            })
        }
        items.append(QuickItem(id: "voice", symbol: "mic", title: "Talk to Shapr",
                               subtitle: "Say a command, ask a question, or save a note", keys: "⌥V") { [weak self] in
            self?.voice.hotkeyDown()
            self?.voice.hotkeyUp() // a tap: keeps listening until Save
        })
        items.append(QuickItem(id: "circle", symbol: "lasso", title: "Circle something on screen",
                               subtitle: "Screenshots, text, or file links", keys: DoubleTapDetector.Key.current == .off ? k("⌥⇧X") : DoubleTapDetector.Key.current.symbol) { [weak self] in
            self?.startScreenCapture(DoubleTapDetector.Key.current == .off ? .rect : .hover)
        })
        if ctx.inTextBox && ctx.selection == nil && chatService == nil {
            items.append(QuickItem(id: "fill", symbol: "list.bullet.rectangle", title: "Fill this form", subtitle: "From your packs and Vault; never submits", keys: k("⌥⇧F")) { [weak self] in self?.forms.open() })
        }
        if let p = pack, chatService != nil || store.latestCheckpoint(for: p.id) == nil && !p.captures.isEmpty {
            items.append(QuickItem(id: "save", symbol: "flag", title: "Save progress", subtitle: "So you can continue in any AI later", keys: k("⌥⇧P")) { [weak self] in self?.checkpoints.open() })
        }
        items.append(QuickItem(id: "switch", symbol: "circle.grid.cross", title: "Switch pack", subtitle: equipped.map { "Now: \($0.label)" } ?? "Auto-sort is on", keys: "⌥S") { [weak self] in
            self?.wheel.openSticky()
        })
        items.append(QuickItem(id: "library", symbol: "books.vertical", title: "Open library", keys: nil) { [weak self] in self?.showLibrary() })
        quick.show(pack: equipped, context: ctx.app?.localizedName ?? "", items: items)
        fileLog.notice("quick panel shown after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    }

    /// The menu bar icon reacts when a capture lands in it.
    private func pulseStatusItem() {
        guard let b = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: "checkmark.circle.fill", accessibilityDescription: "Saved")
        img?.isTemplate = true
        b.image = img
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { [weak self] in self?.updateStatusButton() }
    }

    func importPack(_ url: URL) {
        do {
            let p = try PackBundle.importPack(url, into: store)
            toast.show(ToastContent(icon: .pack(p), title: "Imported \(p.name)",
                                    subtitle: "\(p.captures.count) capture\(p.captures.count == 1 ? "" : "s") from \(url.lastPathComponent)",
                                    actions: [
                                        ToastAction(title: "Open", style: .primary) { [weak self] in self?.showLibrary(select: p.id) },
                                        ToastAction(title: "Undo") { [weak self] in self?.store.deletePack(p.id) },
                                    ]), duration: 6)
        } catch {
            toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't import \(url.lastPathComponent)",
                                    subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
        }
    }

    @objc private func menuImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.init(filenameExtension: PackBundle.fileExtension)!]
        panel.allowsMultipleSelection = true
        NSApp.activate()
        guard panel.runModal() == .OK else { return }
        panel.urls.forEach(importPack)
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showLibrary()
        return true
    }

    private static let classicIDs: [UInt32] = [HotKeyCenter.dropID, HotKeyCenter.screenID, HotKeyCenter.formID,
                                               HotKeyCenter.progressID, HotKeyCenter.resumeID, HotKeyCenter.quickID, HotKeyCenter.useID,
                                               HotKeyCenter.askID]

    /// Voice-first: hold ⌥V to talk, ⌥S for the wheel, and double-tap ⌘ to circle (set up elsewhere).
    /// The classic shortcuts are registered only when they're turned on in Settings.
    private func registerHotkeys() {
        let wheelOK = HotKeyCenter.shared.register(id: HotKeyCenter.wheelID, keyCode: kVK_ANSI_S, modifiers: optionKey,
                                                   pressed: { [weak self] in self?.wheel.hotkeyDown() },
                                                   released: { [weak self] in self?.wheel.hotkeyUp() })
        let voiceOK = HotKeyCenter.shared.register(id: HotKeyCenter.voiceID, keyCode: kVK_ANSI_V, modifiers: optionKey,
                                                   pressed: { [weak self] in self?.voice.hotkeyDown() },
                                                   released: { [weak self] in self?.voice.hotkeyUp() })
        let scoopOK = HotKeyCenter.shared.register(id: HotKeyCenter.captureID, keyCode: kVK_ANSI_C, modifiers: optionKey,
                                                   pressed: { [weak self] in self?.scoop() })
        var results = [("⌥C", scoopOK), ("⌥S", wheelOK), ("⌥V", voiceOK)]
        Self.classicIDs.forEach(HotKeyCenter.shared.unregister)
        if ShortcutSettings.classic {
            let both = optionKey | shiftKey
            let classic: [(UInt32, Int, String, () -> Void)] = [
                (HotKeyCenter.dropID, kVK_ANSI_D, "⌥⇧D", { [weak self] in self?.drop.open() }),
                (HotKeyCenter.screenID, kVK_ANSI_X, "⌥⇧X", { [weak self] in self?.startScreenCapture(.rect) }),
                (HotKeyCenter.formID, kVK_ANSI_F, "⌥⇧F", { [weak self] in self?.forms.open() }),
                (HotKeyCenter.progressID, kVK_ANSI_P, "⌥⇧P", { [weak self] in self?.checkpoints.open() }),
                (HotKeyCenter.resumeID, kVK_ANSI_R, "⌥⇧R", { [weak self] in self?.resume.open() }),
                (HotKeyCenter.quickID, kVK_Space, "⌥⇧Space", { [weak self] in self?.showQuick() }),
                (HotKeyCenter.useID, kVK_ANSI_U, "⌥⇧U", { [weak self] in self?.useWithPack() }),
                (HotKeyCenter.askID, kVK_ANSI_A, "⌥⇧A", { [weak self] in
                    guard let self else { return }
                    if self.ask.isVisible { self.ask.close() } else { self.ask.open() }
                }),
            ]
            for (id, key, label, run) in classic {
                results.append((label, HotKeyCenter.shared.register(id: id, keyCode: key, modifiers: both, pressed: run)))
            }
        }
        if let taken = results.first(where: { !$0.1 })?.0 {
            toast.show(ToastContent(icon: .symbol("keyboard"), title: "A shortcut is taken",
                                    subtitle: "Another app is using \(taken). Quit it and relaunch Shapr.",
                                    tint: DS.warning), duration: 8)
        }
    }

    /// A menu-bar-only app has no visible menu bar, but macOS still routes ⌘V, ⌘C, ⌘A, ⌘Z
    /// through the main menu. Without this Edit menu, paste does nothing in Shapr's text fields.
    private static func makeMainMenu() -> NSMenu {
        let main = NSMenu()

        let appItem = NSMenuItem()
        let appMenu = NSMenu(title: "Shapr")
        appMenu.addItem(withTitle: "Quit Shapr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        main.addItem(appItem)

        let editItem = NSMenuItem()
        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")), keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = edit
        main.addItem(editItem)

        let windowItem = NSMenuItem()
        let window = NSMenu(title: "Window")
        window.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowItem.submenu = window
        main.addItem(windowItem)

        return main
    }

    // MARK: Status item

    private func setupStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateStatusButton()
    }

    private func updateStatusButton() {
        guard let button = statusItem?.button else { return }
        let img = NSImage(systemSymbolName: "square.stack.3d.up.fill", accessibilityDescription: "Shapr")
        img?.isTemplate = true
        button.image = img
        button.imagePosition = .imageLeading
        // The equipped pack's first word, small, next to the icon; nothing when Auto-sort is on.
        let word = store.pack(store.equippedPackID)?.name.split(separator: " ").first.map { String($0.prefix(12)) }
        button.title = word.map { " " + $0 } ?? ""
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let equipped = store.pack(store.equippedPackID)
        let header = NSMenuItem(title: equipped.map { "Equipped: \($0.label)" } ?? "Auto-sort is on", action: nil, keyEquivalent: "")
        header.isEnabled = false
        menu.addItem(header)
        menu.addItem(.separator())

        let auto = NSMenuItem(title: "Auto-sort", action: #selector(menuEquip(_:)), keyEquivalent: "0")
        auto.keyEquivalentModifierMask = []
        auto.target = self
        auto.state = equipped == nil ? .on : .off
        menu.addItem(auto)
        for (i, p) in store.packs.prefix(12).enumerated() {
            let item = NSMenuItem(title: p.label, action: #selector(menuEquip(_:)), keyEquivalent: i < 9 ? "\(i + 1)" : "")
            item.keyEquivalentModifierMask = []
            item.target = self
            item.representedObject = p.id
            item.state = p.id == store.equippedPackID ? .on : .off
            menu.addItem(item)
        }
        menu.addItem(.separator())

        var shortcuts = [("Talk to Shapr: hold, say anything", "⌥V"), ("Scoop selection", "⌥C"), ("Open the wheel", "⌥S")]
        let circle = DoubleTapDetector.Key.current
        if circle != .off { shortcuts.insert(("Circle to capture", circle.symbol), at: 2) }
        if ShortcutSettings.classic {
            shortcuts += [("Everything, beside the pointer", "⌥⇧Space"), ("Ask your packs", "⌥⇧A"), ("Use this with my pack", "⌥⇧U"),
                          ("Capture a screen area", "⌥⇧X"), ("Draft into this app", "⌥⇧D"),
                          ("Fill this form", "⌥⇧F"), ("Save progress", "⌥⇧P"), ("Resume in this app", "⌥⇧R")]
        }
        for (title, keys) in shortcuts {
            let i = NSMenuItem(title: "\(title)    \(keys)", action: nil, keyEquivalent: "")
            i.isEnabled = false
            menu.addItem(i)
        }
        let hint = NSMenuItem(title: "Not sure? Hold ⌥V and say “what can I say”", action: nil, keyEquivalent: "")
        hint.isEnabled = false
        menu.addItem(hint)
        if !CaptureService.isTrusted {
            menu.addItem(withTitle: "Allow Accessibility Access…", action: #selector(menuAccessibility), keyEquivalent: "").target = self
        }
        menu.addItem(.separator())
        let relayItem = NSMenuItem(title: "Continue This Chat In", action: nil, keyEquivalent: "")
        let relayMenu = NSMenu()
        for name in ChatReader.services.map(\.name) {
            let i = NSMenuItem(title: name, action: #selector(menuRelay(_:)), keyEquivalent: "")
            i.target = self
            i.representedObject = name
            relayMenu.addItem(i)
        }
        if relay.isWatching {
            relayMenu.addItem(.separator())
            relayMenu.addItem(withTitle: "Stop Watching the New Chat", action: #selector(menuStopRelay), keyEquivalent: "").target = self
        }
        relayItem.submenu = relayMenu
        menu.addItem(relayItem)
        menu.addItem(withTitle: "Talk to Shapr…", action: #selector(menuTalk), keyEquivalent: "").target = self
        menu.addItem(withTitle: "New Pack", action: #selector(menuNewPack), keyEquivalent: "n").target = self
        menu.addItem(withTitle: "Open Library", action: #selector(menuLibrary), keyEquivalent: "l").target = self
        menu.addItem(withTitle: "Import Pack…", action: #selector(menuImport), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Add Shared Pack…", action: #selector(menuJoin), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Open Packs Folder", action: #selector(menuFolder), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(menuSettings), keyEquivalent: ",").target = self
        menu.addItem(withTitle: "Check for Updates…", action: #selector(menuUpdates), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit Shapr", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

        let icons: [(String, String)] = [
            ("Auto-sort", "sparkles"), ("Everything, beside", "command"), ("Use this with", "sparkle.magnifyingglass"),
            ("Ask your packs", "questionmark.bubble"), ("Talk to Shapr", "mic"), ("Not sure?", "questionmark.circle"),
            ("Scoop selection", "text.cursor"), ("Capture a screen area", "rectangle.dashed"),
            ("Circle to capture", "lasso"), ("Open the wheel", "circle.grid.cross"), ("Draft into this app", "pencil.and.scribble"),
            ("Fill this form", "list.bullet.rectangle.portrait"), ("Allow Accessibility", "lock.shield"),
            ("Save progress", "flag.checkered"), ("Resume in this app", "play.circle"), ("Continue This Chat", "arrow.triangle.branch"),
            ("New Pack", "plus.circle"), ("Open Library", "books.vertical"), ("Import Pack", "square.and.arrow.down"),
            ("Add Shared Pack", "link.badge.plus"), ("Check for Updates", "arrow.down.circle"),
            ("Open Packs Folder", "folder"), ("Settings", "gearshape"), ("Quit Shapr", "power"),
        ]
        for item in menu.items where item.image == nil {
            if let (_, symbol) = icons.first(where: { item.title.hasPrefix($0.0) }) {
                item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
            }
        }
    }

    @objc private func menuEquip(_ sender: NSMenuItem) { equip(sender.representedObject as? UUID, announce: true) }
    @objc private func menuLibrary() { showLibrary() }
    @objc private func menuNewPack() { newPack(inSlot: nil) }
    @objc private func menuSettings() { showSettings() }
    @objc private func menuAccessibility() { CaptureService.requestTrust(); CaptureService.openAccessibilitySettings() }
    @objc private func menuFolder() { NSWorkspace.shared.open(store.packsDir) }

    // MARK: Equip

    func equip(_ id: UUID?, announce: Bool) {
        store.equip(id)
        guard announce else { return }
        if let p = store.pack(id) {
            toast.show(ToastContent(icon: .pack(p), title: "Equipped \(p.name)",
                                    subtitle: "Every capture goes here until you switch back to Auto."), duration: 2.2)
        } else {
            toast.show(ToastContent(icon: .symbol("sparkles"), title: "Auto-sort on",
                                    subtitle: "Shapr picks a pack for each capture."), duration: 2.2)
        }
    }

    // MARK: Scoop

    /// `into`: a pack to save to (from "save this to Acme"); otherwise the usual equipped pack or Auto-sort.
    /// Saves what you selected. With `orScreen` (by voice: "add this", "get the context of this chat") and
    /// nothing selected, it saves what's in front of you instead: the whole chat, the page, or the window.
    func scoop(into target: UUID? = nil, orScreen: Bool = false) {
        guard !scooping else { return }
        guard CaptureService.isTrusted else {
            CaptureService.requestTrust()
            let m = CaptureService.Failure.needsAccessibility.message
            toast.show(ToastContent(icon: .symbol("lock.shield"), title: m.title, subtitle: m.subtitle,
                                    actions: [ToastAction(title: "Open Settings", style: .primary) {
                                        CaptureService.openAccessibilitySettings()
                                    }], tint: DS.warning), duration: 8)
            return
        }
        scooping = true
        let front = NSWorkspace.shared.frontmostApplication
        // Feedback first: light up the selection right away, before reading or sorting it.
        let started = Date()
        if let r = PointerContext.now().selectionBounds {
            feedback.highlight(r, color: NSColor(PackStyle.color(store.equippedPackID)))
        }
        let working = toast.show(ToastContent(icon: .spinner, title: "Scooping…"), duration: nil)
        fileLog.notice("scoop feedback after \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        Task {
            defer { scooping = false }
            switch await CaptureService.captureSelection() {
            case .failure(let f):
                feedback.fadeHighlight()
                if orScreen, f == .nothingSelected {
                    toast.dismiss(ifToken: working)
                    await addFront(into: target, app: front)
                    return
                }
                let m = f.message
                toast.show(ToastContent(icon: .symbol("text.cursor"), title: m.title, subtitle: m.subtitle, tint: DS.warning),
                           duration: 3)
            case .success(let draft):
                if let target, store.pack(target) != nil, let c = store.add(draft, to: target) {
                    showAdded(c, packID: target)
                    feedback.landed(title: draft.title?.nonEmpty ?? draft.text.firstLine.truncated(40), pack: store.pack(target), image: nil)
                } else if let pid = await file(draft) {
                    feedback.landed(title: draft.title?.nonEmpty ?? draft.text.firstLine.truncated(40), pack: store.pack(pid), image: nil)
                } else {
                    feedback.fadeHighlight()
                }
            }
            toast.dismiss(ifToken: working)
        }
    }

    // MARK: "Add this" with nothing selected: the chat, the page, or the window

    /// What a chat becomes in a pack: every message, word for word, under the chat's own name.
    nonisolated static func draft(for chat: ChatTranscript, bundleID: String?) -> CaptureDraft {
        let n = chat.turns.count
        let name = chat.title?.nonEmpty ?? "\(chat.service) chat"
        return CaptureDraft(text: String(chat.plainText.prefix(200_000)), appName: chat.service, bundleID: bundleID,
                            title: "\(name) · \(n) message\(n == 1 ? "" : "s")", url: chat.url)
    }

    /// Earlier saves of the same chat in `pack`: the newest save has everything they had, so they can go.
    nonisolated static func olderCopies(of chat: ChatTranscript, in pack: Pack, keeping text: String) -> [Capture] {
        guard let url = chat.url?.nonEmpty else { return [] }
        guard let kept = pack.captures.last(where: { $0.url == url && $0.text == text }) else { return [] }
        return pack.captures.filter { $0.id != kept.id && $0.url == url && $0.appName == chat.service && $0.image == nil && $0.file == nil }
    }

    /// Saves what's in front of you without selecting anything. An AI chat is read whole (every message it
    /// has loaded, not just what's visible), a web page is read as text, another app's window (WhatsApp,
    /// Messages, Notes…) is read as text too, and what can't be read that way is saved as a picture with
    /// its text read off it. `screenOnly` ("get the context of my screen") goes straight to the picture,
    /// of the whole screen.
    private func addFront(into target: UUID?, app: NSRunningApplication?, screenOnly: Bool = false) async {
        guard let app, app.bundleIdentifier != Bundle.main.bundleIdentifier else {
            toast.show(ToastContent(icon: .symbol("macwindow"), title: "Nothing to add yet",
                                    subtitle: "Go to the chat, page or window you want, then hold ⌥V and say it again.", tint: DS.warning), duration: 4)
            return
        }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier
        let appName = app.localizedName
        let working = toast.show(ToastContent(icon: .spinner, title: "Reading what's in front of you…"), duration: nil)
        defer { toast.dismiss(ifToken: working) }
        let started = Date()

        /// Into the pack you named, else the usual way (the equipped pack, or Auto-sort).
        func save(_ draft: CaptureDraft) async -> UUID? {
            if let target, store.pack(target) != nil, let c = store.add(draft, to: target) {
                showAdded(c, packID: target)
                feedback.landed(title: draft.title?.nonEmpty ?? draft.text.firstLine.truncated(40), pack: store.pack(target), image: nil)
                return target
            }
            guard let pid = await file(draft) else { return nil }
            feedback.landed(title: draft.title?.nonEmpty ?? draft.text.firstLine.truncated(40), pack: store.pack(pid), image: nil)
            return pid
        }

        let isBrowser = bid.map { ChatReader.browserIDs.contains($0) || CaptureService.isBrowser($0) } ?? false
        if !screenOnly, isBrowser || ChatReader.mightBeChat(bundleID: bid) {
            // An AI chat: the conversation itself, message by message.
            func readChat() async -> ChatTranscript? {
                await Task.detached(priority: .userInitiated) {
                    let info = ChatReader.pageInfo(pid: pid)
                    guard let service = ChatReader.service(url: info.url, bundleID: bid), ChatReader.isChatPage(info.url) else { return nil }
                    return ChatReader.read(pid: pid, service: service, url: info.url, title: info.title)
                }.value
            }
            var chat = await readChat()
            // A desktop chat app builds what Shapr reads only once it's asked: give it a moment, once.
            if chat == nil, !isBrowser {
                try? await Task.sleep(for: .milliseconds(800))
                chat = await readChat()
            }
            if let chat {
                let draft = Self.draft(for: chat, bundleID: bid)
                fileLog.notice("read a chat of \(chat.turns.count) messages in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
                if let packID = await save(draft), let pack = store.pack(packID) {
                    for old in Self.olderCopies(of: chat, in: pack, keeping: draft.text) { store.removeCapture(old.id, toTrash: false) }
                }
                return
            }
        }
        if !screenOnly, isBrowser {
            // A web page: its text.
            let page = await Task.detached(priority: .userInitiated) { PageText.read(pid: pid) }.value
            if let page, page.text.count >= 40 {
                _ = await save(CaptureDraft(text: String(page.text.prefix(200_000)), appName: appName, bundleID: bid, title: page.title, url: page.url))
                return
            }
        } else if !screenOnly, CaptureService.isTrusted {
            // Another app (WhatsApp, Messages, Slack, Notes…): the text its window has loaded.
            let window = await Task.detached(priority: .userInitiated) { WindowText.read(pid: pid) }.value
            if let window, window.text.count >= 120 {
                _ = await save(CaptureDraft(text: window.text, appName: appName, bundleID: bid, title: window.title ?? appName))
                return
            }
        }
        // Anything else, or "my screen": a picture of it, with its text read off it.
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            toast.show(ToastContent(icon: .symbol("rectangle.dashed.badge.record"), title: "Allow Screen Recording",
                                    subtitle: "Shapr needs it to save what's on your screen. Turn on Shapr in System Settings, then quit and reopen Shapr. Or select the text and say “add this”.",
                                    actions: [ToastAction(title: "Open Settings", style: .primary) { ScreenCapture.openSettings() }],
                                    tint: DS.warning), duration: 10)
            return
        }
        var (rect, screen) = ScreenCapture.frontWindow(of: app)
        if screenOnly {
            screen = NSScreen.underMouse ?? screen
            rect = screen.frame
        }
        do {
            let image = try await ScreenCapture.capture(rect: rect, on: screen)
            let text = await OCR.text(in: image)
            let source = ScreenSource.at(CGPoint(x: rect.midX, y: rect.midY))
            _ = await save(CaptureDraft(text: text, appName: source.appName ?? appName, bundleID: source.bundleID ?? bid,
                                        title: screenOnly ? "Screen: " + (source.title?.nonEmpty ?? appName ?? "what was open") : source.title,
                                        url: source.url, imageData: ScreenCapture.png(image)))
        } catch {
            toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't read your screen",
                                    subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
        }
    }

    // MARK: Talk to Shapr (hold ⌥V)

    /// Runs what you said: a command, or a question for Ask. Returns false when it's a note to save.
    func runVoice(_ text: String) async -> Bool {
        let names = store.packs.map(\.name)
        var steps = VoiceCommand.plan(text, packs: names)
        // Not something Shapr knows by its words, but it sounds like a request: let the AI on this Mac work out
        // the steps. (The voice card shows "Thinking…" meanwhile.)
        if steps.count == 1, steps[0].isNote, VoiceCommand.looksLikeRequest(text), let understood = await VoiceIntent.plan(text, packs: names) {
            steps = understood
        }
        voiceLog.notice("voice: \(steps.map(\.label).joined(separator: ", then "), privacy: .public)")
        // Just something to remember: it's saved as a voice note.
        if steps.count == 1, steps[0].isNote { return false }

        let front = NSWorkspace.shared.frontmostApplication
        for (i, step) in steps.enumerated() {
            await perform(step, front: front)
            guard i < steps.count - 1 else { break }
            if step.opensPanel {
                // That step needs you; the rest waits until you say it.
                let left = steps[(i + 1)...].map(\.label).joined(separator: ", then ")
                toast.show(ToastContent(icon: .symbol("list.number"), title: "Next: \(left)",
                                        subtitle: "Hold ⌥V and say it when you're done here."), duration: 6)
                break
            }
            try? await Task.sleep(for: .milliseconds(700))
        }
        return true
    }

    /// The last thing saved, so "undo that" and "move that to Acme" know what "that" is.
    private var lastAdded: (capture: UUID, pack: UUID)?

    /// Does one thing you said.
    private func perform(_ cmd: VoiceCommand, front: NSRunningApplication?) async {
        func pack(_ name: String?) -> Pack? { name.flatMap { n in store.packs.first { $0.name == n } } }
        /// The pack you named, else the one you're working in.
        func current(_ name: String?) -> Pack? { pack(name) ?? store.pack(store.equippedPackID) ?? store.pack(libraryState.selection) }
        func say(_ title: String, _ subtitle: String? = nil, symbol: String = "checkmark.circle", tint: Color? = nil) {
            toast.show(ToastContent(icon: .symbol(symbol), title: title, subtitle: subtitle, tint: tint ?? DS.accent), duration: 3.5)
        }

        // Right after a screenshot: a question is about it, and "add it" saves it.
        if let shot = pendingShot ?? recentShot.flatMap({ Date().timeIntervalSince($0.at) < 60 ? $0 : nil }) {
            switch cmd {
            case .ask(let q, let p): askAboutShot(shot, question: q, pack: pack(p), spoken: true); return
            case .screen(let q, let p): askAboutShot(shot, question: q, pack: pack(p) ?? store.pack(store.equippedPackID), spoken: true); return
            case .use: askAboutShot(shot, question: "", pack: nil, spoken: true); return
            case .scoop(let p) where pendingShot != nil: addShot(into: pack(p)?.id); return
            default: break
            }
        }

        switch cmd {
        case .note(let body):
            // A note said along with other things ("note that it's due Friday, then switch to Acme").
            _ = await file(CaptureDraft(text: body, appName: "Voice note", title: VoiceNoteController.title(for: body)))
        case .draft(let instruction): drop.open(instruction: instruction)
        case .ask(let q, let p): ask.open(scope: pack(p)?.id, question: q, spoken: true)
        case .quick: showQuick()
        case .screen(let q, let p): await askAboutScreen(question: q, pack: pack(p) ?? store.pack(store.equippedPackID), app: front)
        case .use: use.open()
        case .scoop(let p): scoop(into: pack(p)?.id, orScreen: true)
        case .addScreen(let p): await addFront(into: pack(p)?.id, app: front, screenOnly: true)
        case .screenshot: startScreenCapture(.hover)
        case .fill: forms.open()
        case .saveProgress: checkpoints.open()
        case .resume: resume.open()
        case .continueIn(let service): relay.relay(to: service, from: front)
        case .equip(let name): if let p = pack(name) { equip(p.id, announce: true) }
        case .autoSort: equip(nil, announce: true)
        case .newPack(let name):
            let id = newPack(inSlot: nil, announce: name == nil)
            if let n = name?.nonEmpty {
                store.rename(id, to: n.prefix(1).uppercased() + n.dropFirst())
                toast.show(ToastContent(icon: .symbol("plus.circle.fill"), title: "New pack equipped: \(store.pack(id)?.name ?? n)",
                                        subtitle: "Everything you save goes here until you switch."), duration: 3)
            }
        case .keepUpdated(let p):
            guard let target = pack(p) ?? store.packToUse(nil).pack, let front else { return }
            keepFrontUpdated(in: target.id, app: front)
        case .library: showLibrary()
        case .settings: showSettings()
        case .wheel: wheel.openSticky()
        case .map(let p):
            guard let target = current(p) ?? store.packs.first else { say("No packs yet", "Say “add this” to start one.", symbol: "tray"); return }
            libraryState.layout = .graph
            showLibrary(select: target.id)
        case .openPack(let name):
            if let p = pack(name) { showLibrary(select: p.id) }
        case .share(let p):
            guard let target = current(p) else { say("Which pack?", "Say “share Acme”, or equip a pack first.", symbol: "questionmark.circle"); return }
            safeShare(target.id)
        case .copyPack(let p):
            guard let target = current(p) else { say("Which pack?", "Say “copy Acme”, or equip a pack first.", symbol: "questionmark.circle"); return }
            copyPrompt(target.id)
        case .undo:
            guard let last = lastAdded, let c = store.pack(last.pack)?.captures.first(where: { $0.id == last.capture }) else {
                say("Nothing to take back", "Undo works on the last thing you saved.", symbol: "arrow.uturn.backward")
                return
            }
            store.removeCapture(c.id, toTrash: false)
            lastAdded = nil
            say("Removed “\(c.displayTitle.truncated(40))”", "It's no longer in \(store.pack(last.pack)?.name ?? "the pack").", symbol: "arrow.uturn.backward")
        case .moveLast(let name):
            guard let dest = pack(name), let last = lastAdded, store.pack(last.pack)?.captures.contains(where: { $0.id == last.capture }) == true else {
                say("Nothing to move", "“Move that” works on the last thing you saved.", symbol: "arrow.right.circle")
                return
            }
            store.moveCapture(last.capture, to: dest.id)
            lastAdded = (last.capture, dest.id)
            toast.show(ToastContent(icon: .pack(dest), title: "Moved to \(dest.name)"), duration: 3)
        case .rename(let p, let name):
            guard let target = current(p) else { say("Which pack?", "Say “rename Acme to Globex”.", symbol: "questionmark.circle"); return }
            let clean = name.prefix(1).uppercased() + name.dropFirst()
            store.rename(target.id, to: clean)
            say("\(target.name) is now \(store.pack(target.id)?.name ?? clean)", symbol: "pencil")
        case .type(let words):
            TextInserter.paste(words, into: front)
        case .openApp(let name):
            if let url = Self.application(named: name) {
                _ = try? await NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            } else {
                say("No app called “\(name)”", "Say “open the library” for your packs, or ask a question.", symbol: "questionmark.app", tint: DS.warning)
            }
        case .web(let query):
            var parts = URLComponents(string: "https://www.google.com/search")
            parts?.queryItems = [URLQueryItem(name: "q", value: query)]
            if let url = parts?.url { NSWorkspace.shared.open(url) }
        case .stop:
            Speaker.stop()
        case .help:
            toast.show(ToastContent(icon: .symbol("mic"), title: "Hold ⌥V and say things like",
                                    subtitle: VoiceCommand.examples.joined(separator: " · ") + " · or ask anything, or just talk to save a note.",
                                    expandable: true), duration: 12)
        }
    }

    /// An installed app by the name you said ("safari", "notes", "visual studio code").
    static func application(named said: String) -> URL? {
        let want = VoiceCommand.normalize(said)
        guard !want.isEmpty else { return nil }
        let fm = FileManager.default
        let folders = ["/Applications", "/System/Applications", "/System/Applications/Utilities", "/Applications/Utilities",
                       fm.homeDirectoryForCurrentUser.appendingPathComponent("Applications").path]
        var prefix: URL?
        for folder in folders {
            for item in (try? fm.contentsOfDirectory(atPath: folder)) ?? [] where item.hasSuffix(".app") {
                let name = VoiceCommand.normalize(String(item.dropLast(4)))
                let url = URL(fileURLWithPath: folder).appendingPathComponent(item)
                if name == want { return url }
                if prefix == nil, name.hasPrefix(want + " ") || name.hasSuffix(" " + want) { prefix = url }
            }
        }
        return prefix
    }

    // MARK: After a screenshot: add it, or ask about it

    private struct PendingShot { let id = UUID(); let draft: CaptureDraft; let image: NSImage; let rect: CGRect; let at = Date() }
    /// The screenshot waiting for "Add" or "Ask about it".
    private var pendingShot: PendingShot?
    /// The last screenshot (for a minute): a spoken question right after it is about it.
    private var recentShot: PendingShot?
    private var shotToast: UUID?

    /// A screenshot was taken: offer to add it to the pack or ask about it. Doing nothing adds it, as before.
    private func offerShot(_ d: CaptureDraft, image: NSImage, rect: CGRect) {
        let shot = PendingShot(draft: d, image: image, rect: rect)
        pendingShot = shot
        recentShot = shot
        let target = store.pack(store.equippedPackID)
        // A question on screen (homework, a quiz): offer to answer it straight away, from the pack.
        let isQuestion = AskEngine.looksLikeQuestion(d.text)
        shotToast = toast.show(ToastContent(
            icon: .symbol("camera.viewfinder"), title: d.title?.nonEmpty ?? "Screenshot",
            subtitle: isQuestion ? "Add it, or answer it with \(target?.name ?? "your packs"). Or hold ⌥V and ask."
                                 : "Add it, or ask your packs about it. Or hold ⌥V and ask.",
            actions: [ToastAction(title: target.map { "Add to \($0.name)" } ?? "Add to a pack", style: .primary) { [weak self] in self?.addShot(into: nil) },
                      ToastAction(title: isQuestion ? "Answer it" : "Ask about it") { [weak self] in
                          guard let self, let s = self.pendingShot else { return }
                          self.askAboutShot(s, question: isQuestion ? AskEngine.solveDefault : "", pack: nil, spoken: false)
                      }],
            preview: .image(image), pack: target, eyebrow: "Screenshot"), duration: 12) { [weak self] in
            if self?.pendingShot?.id == shot.id { self?.addShot(into: nil) }
        }
        // If another card replaced this one, still keep the screenshot.
        DispatchQueue.main.asyncAfter(deadline: .now() + 45) { [weak self] in
            if self?.pendingShot?.id == shot.id { self?.addShot(into: nil) }
        }
    }

    /// Saves the waiting screenshot: into `packID`, or the usual way (equipped pack, else Auto-sort).
    private func addShot(into packID: UUID?) {
        guard let shot = pendingShot else { return }
        pendingShot = nil
        if let t = shotToast { toast.dismiss(ifToken: t) }
        Task {
            if let packID, store.pack(packID) != nil, let c = store.add(shot.draft, to: packID) {
                showAdded(c, packID: packID)
                feedback.landed(title: shot.draft.title ?? "Screenshot", pack: store.pack(packID), image: shot.image, from: shot.rect)
            } else if let pid = await file(shot.draft) {
                feedback.landed(title: shot.draft.title ?? "Screenshot", pack: store.pack(pid), image: shot.image, from: shot.rect)
            }
        }
    }

    /// Opens Ask with the screenshot. A bare "ask about it" becomes a sensible first question.
    private func askAboutShot(_ shot: PendingShot, question: String, pack: Pack?, spoken: Bool) {
        if pendingShot?.id == shot.id { pendingShot = nil }
        recentShot = nil
        if let t = shotToast { toast.dismiss(ifToken: t) }
        let bare = question.trimmingCharacters(in: .whitespacesAndNewlines)
            .range(of: #"^(?i)(about )?(it|this|that|the screenshot|this screenshot|the image|this image|the picture)?[.?!]*$"#, options: .regularExpression) != nil
        let questionOnScreen = AskEngine.looksLikeQuestion(shot.draft.text)
        let q = bare ? (spoken ? (questionOnScreen ? AskEngine.solveDefault : "What is this, and what do my notes say about it?") : "") : question
        let forAI = shot.image.cgImage(forProposedRect: nil, context: nil, hints: nil).flatMap { ScreenCapture.pngForAI($0) }
        ask.open(scope: pack?.id, question: q,
                 shot: AskModel.Shot(image: shot.image, png: forAI ?? shot.draft.imageData ?? Data(), text: shot.draft.text, draft: shot.draft),
                 spoken: spoken)
    }

    /// "Answer this using my MAT223 pack": captures the window you're on (no circling) and asks about it.
    private func askAboutScreen(question: String, pack: Pack?, app: NSRunningApplication?) async {
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            toast.show(ToastContent(icon: .symbol("rectangle.dashed.badge.record"), title: "Allow Screen Recording",
                                    subtitle: "Shapr needs it to read your screen. Turn on Shapr in System Settings, then quit and reopen Shapr.",
                                    actions: [ToastAction(title: "Open Settings", style: .primary) { ScreenCapture.openSettings() }],
                                    tint: DS.warning), duration: 10)
            return
        }
        let working = toast.show(ToastContent(icon: .spinner, title: "Reading your screen…",
                                              subtitle: pack.map { "Then answering with \($0.name)" }), duration: nil)
        defer { toast.dismiss(ifToken: working) }
        let (rect, screen) = ScreenCapture.frontWindow(of: app)
        do {
            let image = try await ScreenCapture.capture(rect: rect, on: screen)
            let text = await OCR.text(in: image)
            let source = ScreenSource.at(CGPoint(x: rect.midX, y: rect.midY))
            let draft = CaptureDraft(text: text, appName: source.appName ?? app?.localizedName, bundleID: source.bundleID ?? app?.bundleIdentifier,
                                     title: source.title, url: source.url, imageData: ScreenCapture.png(image))
            recentShot = nil
            askAboutShot(PendingShot(draft: draft, image: NSImage(cgImage: image, size: .zero), rect: rect),
                         question: question, pack: pack, spoken: true)
        } catch {
            toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't read your screen",
                                    subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
        }
    }

    /// "Save it to …" from the Ask panel. Returns the pack's name.
    private func saveShot(_ draft: CaptureDraft, into scope: UUID?) async -> String? {
        if let id = scope ?? store.equippedPackID, let p = store.pack(id), let c = store.add(draft, to: id) {
            showAdded(c, packID: id)
            return p.name
        }
        return await file(draft).flatMap { store.pack($0)?.name }
    }

    @objc private func menuTalk() {
        voice.hotkeyDown()
        voice.hotkeyUp() // a tap: listens until you click Save or tap ⌥V
    }

    // MARK: Screen capture (⌥⇧X rectangle, double-tap Control to circle)

    func startScreenCapture(_ mode: CaptureOverlayView.Mode) {
        if overlay.isVisible { overlay.hide(); return } // double-tap again to cancel
        guard !screenCapturing else { return }
        guard ScreenCapture.hasPermission else {
            ScreenCapture.requestPermission()
            toast.show(ToastContent(icon: .symbol("rectangle.dashed.badge.record"), title: "Allow Screen Recording",
                                    subtitle: "Turn on Shapr in System Settings, then quit and reopen Shapr.",
                                    actions: [ToastAction(title: "Open Settings", style: .primary) { ScreenCapture.openSettings() }],
                                    tint: DS.warning), duration: 10)
            return
        }
        LinkFinder.prepare(NSWorkspace.shared.frontmostApplication) // so file links can be found in the circle
        let target = store.pack(store.equippedPackID).map { "saves to \($0.label)" } ?? "Shapr picks the pack"
        let hint = mode == .hover ? "Circle anything with your pointer, then pause  ·  \(target)  ·  esc to cancel"
                                  : "Drag around anything  ·  \(target)  ·  esc to cancel"
        overlay.show(mode: mode, hint: hint, accent: NSColor(PackStyle.color(store.equippedPackID))) { [weak self] rect, screen in
            self?.finishScreenCapture(rect, on: screen)
        }
    }

    private func finishScreenCapture(_ rect: CGRect, on screen: NSScreen) {
        screenCapturing = true
        let source = ScreenSource.at(CGPoint(x: rect.midX, y: rect.midY))
        let working = toast.show(ToastContent(icon: .spinner, title: "Reading what you picked…"), duration: nil)
        Task {
            defer { screenCapturing = false }
            // Circled a link to a file? Save the file itself.
            if await saveFileLinks(in: rect, source: source) {
                toast.dismiss(ifToken: working)
                return
            }
            do {
                let image = try await ScreenCapture.capture(rect: rect, on: screen)
                var text = await OCR.text(in: image)
                if text.count < 20 {
                    let labels = OCR.labels(for: image)
                    if !labels.isEmpty { text += (text.isEmpty ? "" : "\n") + "Image: " + labels.joined(separator: ", ") }
                }
                let draft = CaptureDraft(text: text, appName: source.appName, bundleID: source.bundleID,
                                         title: source.title, url: source.url, imageData: ScreenCapture.png(image))
                toast.dismiss(ifToken: working)
                offerShot(draft, image: NSImage(cgImage: image, size: .zero), rect: rect)
            } catch {
                toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't capture the screen",
                                        subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
            }
            toast.dismiss(ifToken: working)
        }
    }

    /// Finds links to files inside the region, downloads them (through your browser if they need a
    /// login), and saves each as a capture with its text. Returns false if there were no file links.
    private func saveFileLinks(in rect: CGRect, source: ScreenSource.Info) async -> Bool {
        let rect = rect
        let batchStart = Date()
        let links = LinkFinder.links(in: rect)
        var (found, maybe) = FileLinkResolver.targets(from: links)
        fileLog.notice("circle: \(links.count) link(s), \(found.count) file link(s), \(maybe.count) maybe")
        for url in maybe.prefix(3) {
            if let ext = await FileDownloader.probe(url) {
                found.append(FileTarget(download: url, name: nil, ext: ext, needsLogin: false))
            }
        }
        guard !found.isEmpty else { return false }
        // Circled only the file names? Find each file's ↓ button so it downloads in place, without new tabs.
        for i in found.indices where found[i].needsLogin && found[i].pressElement == nil {
            if let link = found[i].linkElement {
                found[i].pressElement = LinkFinder.downloadButton(near: link, text: found[i].linkText ?? found[i].name,
                                                                  key: found[i].siteKey)
            }
        }
        let targets = Array(found.prefix(30))
        let names = targets.map { $0.name ?? FileDownloader.sanitize($0.download.lastPathComponent) }

        // One progress toast for the whole batch.
        var token = UUID()
        func showProgress(_ done: Int, failed: Int = 0) {
            // Only what's true right now: downloaded, still downloading, and any that need attention.
            let title = targets.count == 1 ? "Downloading \(names[0])…" : "Adding \(targets.count) files"
            var parts = ["\(done) downloaded", "\(max(0, targets.count - done - failed)) in progress"]
            if failed > 0 { parts.append("\(failed) need attention") }
            token = toast.show(ToastContent(icon: .spinner, title: title,
                                            subtitle: targets.count == 1 ? (targets.contains(where: \.needsLogin) ? "Using your browser's login, right on the page"
                                                                                                                   : (targets[0].download.host ?? ""))
                                                                         : parts.joined(separator: " · ")),
                               duration: nil)
        }
        showProgress(0)

        // 1. Public links: download directly, all at once.
        var results: [Int: FileDownloader.Result] = [:]
        var errors: [Int: Error] = [:]
        var viaBrowser = targets.indices.filter { targets[$0].needsLogin }
        let direct = targets.indices.filter { !targets[$0].needsLogin }.map { ($0, targets[$0].download, targets[$0].ext) }
        await withTaskGroup(of: (Int, Swift.Result<FileDownloader.Result, Error>).self) { group in
            for (i, url, ext) in direct {
                group.addTask {
                    do { return (i, .success(try await FileDownloader.download(url, expectedExt: ext))) } catch { return (i, .failure(error)) }
                }
            }
            for await (i, r) in group {
                switch r {
                case .success(let res):
                    results[i] = res
                    showProgress(results.count)
                case .failure(FileDownloader.DownloadError.needsBrowser):
                    viaBrowser.append(i)
                case .failure(let e):
                    fileLog.error("direct download failed: \(e.localizedDescription, privacy: .public)")
                    errors[i] = e
                }
            }
        }

        // 2. Files that need your login: your browser downloads them together, on the page.
        if !viaBrowser.isEmpty {
            let items = viaBrowser.map { FileDownloader.BrowserItem(url: targets[$0].download, press: targets[$0].pressElement,
                                                                     expectedName: targets[$0].name) }
            let already = results.count
            let got = await FileDownloader.viaBrowser(items, browserBundleID: source.bundleID, since: batchStart) { n in showProgress(already + n) }
            for (k, res) in got { results[viaBrowser[k]] = res }
        }

        // 3. Read each file's text and save them together.
        var drafts: [CaptureDraft] = []
        for i in targets.indices {
            guard let res = results[i],
                  let d = await FileImporter.draft(file: res.file, name: targets[i].name ?? res.name, sourceURL: targets[i].download,
                                                   appName: source.appName) else { continue }
            drafts.append(d)
        }
        toast.dismiss(ifToken: token)
        let failed = targets.indices.filter { results[$0] == nil }.map { names[$0] }

        if drafts.count == 1 && failed.isEmpty && targets.count == 1 {
            await file(drafts[0])
        } else if !drafts.isEmpty {
            await fileMany(drafts, failed: failed, total: targets.count, from: rect)
        } else {
            let why = errors.values.first?.localizedDescription ?? "The downloads didn't finish."
            toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"),
                                    title: targets.count == 1 ? "Couldn't save \(names[0])" : "Couldn't save those \(targets.count) files",
                                    subtitle: why, tint: DS.warning), duration: 5)
        }
        return true
    }

    /// Several files at once: one pack for all of them (the equipped one, or one decision for the batch)
    /// and a single summary with Undo and Move.
    private func fileMany(_ allDrafts: [CaptureDraft], failed: [String], total: Int, from rect: CGRect? = nil) async {
        // Files already in a pack aren't added twice.
        let drafts = allDrafts.filter { store.duplicate(of: $0) == nil }
        let already = allDrafts.count - drafts.count
        let packID: UUID
        if let eq = store.equippedPackID, store.pack(eq) != nil {
            packID = eq
        } else {
            toast.show(ToastContent(icon: .spinner, title: "Sorting \(drafts.count) files…"), duration: nil)
            let probe = CaptureDraft(
                text: drafts.map { ($0.title ?? "") + ": " + String($0.text.prefix(300)) }.joined(separator: "\n"),
                title: drafts.compactMap(\.title).joined(separator: ", "), url: drafts.first?.url)
            let decision = await sorter.decide(probe, packs: store.summaries())
            if let pid = decision.packID, store.pack(pid) != nil {
                packID = pid
            } else {
                packID = store.createPack(name: decision.name, emoji: decision.emoji, autoNamed: true).id
            }
        }
        let added = drafts.compactMap { store.add($0, to: packID) }
        store.markActive(packID)
        refineNameIfNeeded(packID)
        guard let p = store.pack(packID) else { return }
        let ids = added.map(\.id)
        let others = store.packs.filter { $0.id != packID }.prefix(8).map { o in
            (o.label, { [weak self] () -> Void in ids.forEach { self?.store.moveCapture($0, to: o.id) } })
        }
        var actions = [ToastAction(title: "Undo") { [weak self] in ids.forEach { self?.store.removeCapture($0, toTrash: false) } }]
        if !others.isEmpty { actions.append(ToastAction(title: "Move", style: .menu(others))) }
        var notes: [String] = []
        if already > 0 { notes.append("\(already) already in your packs") }
        if !failed.isEmpty { notes.append("\(failed.count) need attention: " + failed.prefix(3).joined(separator: ", ") + (failed.count > 3 ? "…" : "")) }
        toast.show(ToastContent(icon: .pack(p), title: "\(added.count) of \(total) files added",
                                subtitle: notes.isEmpty ? added.compactMap(\.title).prefix(4).joined(separator: ", ") : notes.joined(separator: " · "),
                                actions: added.isEmpty ? [] : actions, preview: added.first.map { CapturePreview.of($0, store: store) },
                                pack: p, eyebrow: "Saved to"), duration: failed.isEmpty ? 6 : 10)
        if !added.isEmpty { feedback.landed(title: "\(added.count) file\(added.count == 1 ? "" : "s")", pack: p, image: nil, from: rect) }
    }

    /// Files a capture. Returns the pack it was saved to, or nil if it wasn't saved (for example because
    /// the same thing is already in a pack).
    @discardableResult
    private func file(_ d: CaptureDraft) async -> UUID? {
        if let (p, c) = store.duplicate(of: d) {
            toast.show(ToastContent(icon: .pack(p), title: c.displayTitle,
                                    subtitle: "You saved this \(c.capturedAt.formatted(.relative(presentation: .named))), so it wasn't added again.",
                                    actions: [ToastAction(title: "Show") { [weak self] in self?.showLibrary(select: p.id) },
                                              ToastAction(title: "Add anyway") { [weak self] in _ = self?.store.add(d, to: p.id) }],
                                    preview: CapturePreview.of(c, store: store), pack: p, eyebrow: "Already in"), duration: 5)
            return nil
        }
        // 1. The wheel wins: an equipped pack takes everything.
        if let eq = store.equippedPackID, store.pack(eq) != nil, let c = store.add(d, to: eq) {
            showAdded(c, packID: eq)
            refineNameIfNeeded(eq)
            return eq
        }

        // 2. Where it came from says which pack: who sent the email, the repo, a linked folder or page.
        if let s = await route(d), let p = store.pack(s.packID), let c = store.add(d, to: p.id) {
            if store.isActive(p.id) {
                store.markActive(p.id)
                showAdded(c, packID: p.id)
            } else {
                askToConfirm(c, packID: p.id, decision: SortDecision(packID: p.id, name: p.name, emoji: p.meta.emoji, engine: "Matched"),
                             reason: "Picked because \(s.reason)")
            }
            refineNameIfNeeded(p.id)
            return p.id
        }

        // 3. Auto-sort.
        toast.show(ToastContent(icon: .spinner, title: "Sorting…", subtitle: d.text.singleLine.truncated(90)), duration: nil)
        let decision = await sorter.decide(d, packs: store.summaries())

        if let pid = decision.packID, store.pack(pid) != nil, let c = store.add(d, to: pid) {
            if store.isActive(pid) {
                store.markActive(pid)
                showAdded(c, packID: pid)
            } else {
                askToConfirm(c, packID: pid, decision: decision)
            }
            refineNameIfNeeded(pid)
            return pid
        } else {
            let p = store.createPack(name: decision.name, emoji: decision.emoji, autoNamed: true)
            guard let c = store.add(d, to: p.id) else { return nil }
            store.markActive(p.id)
            showNewPack(c, packID: p.id)
            return p.id
        }
    }

    /// A pack the capture clearly belongs to, from strong evidence only (a sender, a repo, a linked
    /// folder or page, or where you filed things from here before).
    private func route(_ d: CaptureDraft) async -> RouteSuggestion? {
        guard PackRouter.enabled else { return nil }
        var sig = RouteSignals(emails: PackRouter.emails(in: d.text, limit: 4), url: d.url)
        if d.url?.hasPrefix("file://") == true { sig.documentPath = d.url }
        if let front = NSWorkspace.shared.frontmostApplication, front.bundleIdentifier == d.bundleID, d.bundleID != nil {
            let screen = await ScreenSignals.read(app: front, url: d.url, budget: 0.3)
            sig.emails = Array((screen.emails + sig.emails).reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }.prefix(10))
            sig.senderKnown = screen.senderKnown
            sig.documentPath = sig.documentPath ?? screen.documentPath
        }
        guard let s = store.suggestPack(for: sig), s.isStrong else { return nil }
        return s
    }

    /// First capture into an existing pack this session: confirm it. After "Yes", similar captures go in quietly.
    private func askToConfirm(_ c: Capture, packID: UUID, decision: SortDecision, reason: String? = nil) {
        guard let p = store.pack(packID) else { return }
        let others = store.packs.filter { $0.id != packID }.prefix(8).map { o in
            (o.label, { [weak self] in
                self?.store.moveCapture(c.id, to: o.id)
                self?.store.markActive(o.id)
                if c.url != nil { PackRouter.learn(RouteSignals(url: c.url), packID: o.id) }
            })
        }
        var actions = [
            ToastAction(title: "Yes", style: .primary) { [weak self] in self?.store.markActive(packID) },
        ]
        if !others.isEmpty { actions.append(ToastAction(title: "Other", style: .menu(others))) }
        actions.append(ToastAction(title: "New pack") { [weak self] in
            guard let self else { return }
            // You asked for a new pack, so equip it: the next scoops go there too.
            let np = self.store.createPack(name: decision.name, emoji: decision.emoji, autoNamed: true)
            self.store.moveCapture(c.id, to: np.id)
            self.equip(np.id, announce: true)
        })
        actions.append(ToastAction(title: "Discard") { [weak self] in self?.store.removeCapture(c.id, toTrash: false) })

        toast.show(ToastContent(icon: .pack(p), title: c.displayTitle,
                                subtitle: reason ?? sourceLine(c), actions: actions, preview: CapturePreview.of(c, store: store),
                                pack: p, eyebrow: "Add to", expandable: true), duration: 10)
    }

    private func showAdded(_ c: Capture, packID: UUID) {
        lastAdded = (c.id, packID)
        guard let p = store.pack(packID) else { return }
        let others = store.packs.filter { $0.id != packID }.prefix(8).map { o in
            (o.label, { [weak self] () -> Void in self?.store.moveCapture(c.id, to: o.id) })
        }
        var actions = [ToastAction(title: "Undo") { [weak self] in self?.store.removeCapture(c.id, toTrash: false) }]
        if !others.isEmpty { actions.append(ToastAction(title: "Move", style: .menu(others))) }
        toast.show(ToastContent(icon: .pack(p), title: c.displayTitle,
                                subtitle: sourceLine(c), actions: actions, preview: CapturePreview.of(c, store: store),
                                pack: p, eyebrow: "Added to", expandable: true), duration: 4)
    }

    private func showNewPack(_ c: Capture, packID: UUID) {
        lastAdded = (c.id, packID)
        guard let p = store.pack(packID) else { return }
        var actions = [
            ToastAction(title: "Undo") { [weak self] in
                self?.store.removeCapture(c.id, toTrash: false)
                self?.store.discardNewPack(packID)
            },
            ToastAction(title: "Rename") { [weak self] in self?.showLibrary(select: packID, rename: true) },
        ]
        let others = store.packs.filter { $0.id != packID }.prefix(8).map { o in
            (o.label, { [weak self] in
                self?.store.moveCapture(c.id, to: o.id)
                self?.store.discardNewPack(packID)
                self?.store.markActive(o.id)
            })
        }
        if !others.isEmpty { actions.append(ToastAction(title: "Move", style: .menu(others))) }
        toast.show(ToastContent(icon: .pack(p), title: c.displayTitle,
                                subtitle: sourceLine(c), actions: actions, preview: CapturePreview.of(c, store: store),
                                pack: p, eyebrow: "New pack", expandable: true), duration: 5)
    }

    /// "caranddriver.com · Safari · just now"
    private func sourceLine(_ c: Capture) -> String {
        [c.host, c.appName, "just now"].compactMap { $0 }.joined(separator: " · ")
    }

    /// Names an empty "New Pack" from its first capture, and gives auto-named packs
    /// a better name at 3 and 6 captures.
    private func refineNameIfNeeded(_ id: UUID?) {
        guard let id, let p = store.pack(id), p.meta.autoNamed else { return }
        let placeholder = p.name.hasPrefix(PackStore.placeholderName)
        guard (placeholder && p.captures.count == 1) || [3, 6].contains(p.captures.count) else { return }
        let texts = p.captures.map { ($0.title ?? "") + ": " + $0.text }
        Task {
            guard let result = await sorter.name(for: texts),
                  let now = store.pack(id), now.meta.autoNamed,
                  result.name.caseInsensitiveCompare(now.name) != .orderedSame,
                  !store.packs.contains(where: { $0.id != id && $0.name.caseInsensitiveCompare(result.name) == .orderedSame })
            else { return }
            store.rename(id, to: result.name, emoji: .some(result.emoji ?? now.meta.emoji), autoNamed: true)
        }
    }

    /// Files dragged in from Finder (or picked with Add Files…): copied into the pack, with their text.
    func importFiles(_ urls: [URL], into packID: UUID) {
        Task {
            var added: [String] = []
            var skipped: [String] = []
            for url in urls.prefix(50) {
                if let d = await FileImporter.draft(file: url, name: url.lastPathComponent, sourceURL: url, appName: "Finder"),
                   store.add(d, to: packID) != nil {
                    added.append(url.lastPathComponent)
                } else {
                    skipped.append(url.lastPathComponent)
                }
            }
            guard let p = store.pack(packID) else { return }
            if !added.isEmpty {
                toast.show(ToastContent(icon: .pack(p),
                                        title: added.count == 1 ? "Added \(added[0])" : "Added \(added.count) files to \(p.name)",
                                        subtitle: skipped.isEmpty ? "Its text is now part of the pack." : "Skipped: \(skipped.prefix(3).joined(separator: ", "))"),
                           duration: 3)
            } else if !skipped.isEmpty {
                toast.show(ToastContent(icon: .symbol("nosign"), title: "Shapr can't keep those files",
                                        subtitle: "It saves documents, text and images up to 50 MB, never apps or scripts.",
                                        tint: DS.warning), duration: 4)
            }
        }
    }

    /// An empty pack, equipped right away, so the next scoops go into it.
    @discardableResult
    func newPack(inSlot slot: Int?, announce: Bool = true) -> UUID {
        let p = store.createPack(name: PackStore.placeholderName, emoji: nil, autoNamed: true)
        if let slot { store.place(p.id, inSlot: slot) }
        store.equip(p.id)
        if announce {
            toast.show(ToastContent(icon: .symbol("plus.circle.fill"), title: "New pack equipped",
                                    subtitle: "Select text and press ⌥C. Shapr names it from the first capture.",
                                    actions: [ToastAction(title: "Name it") { [weak self] in
                                        self?.showLibrary(select: p.id, rename: true)
                                    }]), duration: 4)
        }
        return p.id
    }

    // MARK: Windows

    private var libraryActions: LibraryActions {
        LibraryActions(
            copyPrompt: { [weak self] id in self?.copyPrompt(id) },
            exportMarkdown: { [weak self] id in self?.exportMarkdown(id) },
            safeShare: { [weak self] id in self?.safeShare(id) },
            equip: { [weak self] id in self?.equip(id, announce: false) },
            revealInFinder: { url in NSWorkspace.shared.activateFileViewerSelecting([url]) },
            openSettings: { [weak self] in self?.showSettings() },
            newPack: { [weak self] in self?.newPack(inSlot: nil, announce: false) },
            saveProgress: { [weak self] id in self?.checkpoints.open(packID: id) },
            copyResume: { [weak self] id, cp in
                guard let self, let p = self.store.pack(id) else { return }
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(ResumePrompt.build(pack: p, checkpoint: cp), forType: .string)
                self.toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "Resume prompt copied",
                                             subtitle: "Paste it into any AI tool to pick up \(p.name)."), duration: 2.5)
            },
            importFiles: { [weak self] urls, id in self?.importFiles(urls, into: id) },
            addSource: { [weak self] kind, id in self?.addSource(kind, to: id) },
            syncSource: { [weak self] packID, sourceID in self?.sync.sync(sourceID, in: packID) },
            removeSource: { [weak self] packID, sourceID, items in self?.sync.remove(sourceID, from: packID, removeItems: items) },
            ask: { [weak self] id in self?.ask.open(scope: id) }
        )
    }

    func showLibrary(select: UUID? = nil, rename: Bool = false) {
        if libraryWindow == nil {
            let view = LibraryView(actions: libraryActions)
                .environmentObject(store)
                .environmentObject(libraryState)
                .environmentObject(shares)
                .environmentObject(sync)
                .frame(minWidth: 820, minHeight: 520)
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1060, height: 700),
                             styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            LibraryWindow.style(w)
            let host = NSHostingView(rootView: view)
            // Let SwiftUI's title and toolbar become the window's own (native unified toolbar).
            host.sceneBridgingOptions = [.title, .toolbars]
            w.contentView = host
            w.isReleasedWhenClosed = false
            w.setFrameAutosaveName("ShaprLibrary")
            if w.frame.origin == .zero { w.center() }
            libraryWindow = w
        }
        store.load()
        if let select {
            libraryState.selection = select
            if rename, let p = store.pack(select) {
                libraryState.renameText = p.name
                libraryState.renaming = select
            }
        }
        NSApp.activate()
        libraryWindow?.makeKeyAndOrderFront(nil)
    }

    /// Opens the library at one capture.
    func showCapture(_ captureID: UUID, in packID: UUID) {
        showLibrary(select: packID)
        libraryState.selectedCapture = captureID
    }

    // MARK: Live sources

    /// Asks where to keep the pack updated from (a folder, repo, Notion page, or a page or thread), then reads it.
    func addSource(_ kind: PackSource.Kind, to packID: UUID) {
        guard let p = store.pack(packID) else { return }
        var src: PackSource?
        NSApp.activate()
        if kind == .folder {
            let panel = NSOpenPanel()
            panel.canChooseDirectories = true
            panel.canChooseFiles = false
            panel.prompt = "Keep Updated"
            panel.message = "Shapr reads the documents and text files in this folder, and keeps \(p.name) up to date as they change."
            guard panel.runModal() == .OK, let url = panel.url else { return }
            src = PackSource(kind: .folder, location: url.path, title: url.lastPathComponent)
        } else {
            let alert = NSAlert()
            switch kind {
            case .github:
                alert.messageText = "Keep \(p.name) updated from a GitHub repo"
                alert.informativeText = "Paste the repo's link. Shapr keeps its README, open issues and pull requests, and recent commits."
            case .notion:
                alert.messageText = "Keep \(p.name) updated from a Notion page"
                alert.informativeText = Keychain.get(SourceSync.notionAccount) == nil
                    ? "Paste the page's link. Shapr needs your Notion token (Settings → Connections) and the page shared with your integration."
                    : "Paste the page's link. In Notion, share the page with your integration (••• → Connections)."
            default:
                alert.messageText = "Keep \(p.name) updated from a page"
                alert.informativeText = "Paste a link. Public pages are checked every 30 minutes. Pages that need your login (Gmail threads, Google Docs) update whenever you open them."
            }
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 360, height: 24))
            field.placeholderString = kind == .github ? "https://github.com/owner/repo" : kind == .notion ? "https://www.notion.so/…" : "https://…"
            if let clip = NSPasteboard.general.string(forType: .string), let guess = PackSource.from(link: clip),
               guess.kind == kind || (kind == .web && [.web, .page].contains(guess.kind)) { field.stringValue = clip }
            alert.accessoryView = field
            alert.addButton(withTitle: "Keep Updated")
            alert.addButton(withTitle: "Cancel")
            alert.window.initialFirstResponder = field
            guard alert.runModal() == .alertFirstButtonReturn, let link = field.stringValue.nonEmpty else { return }
            src = PackSource.from(link: link)
            if src == nil || (kind == .github && src?.kind != .github) || (kind == .notion && src?.kind != .notion) {
                toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "That link doesn't look right",
                                        subtitle: kind == .github ? "Use a link like github.com/owner/repo." :
                                                  kind == .notion ? "Use the page's link from Notion's Share menu." : "Use a full web address.",
                                        tint: DS.warning), duration: 5)
                return
            }
        }
        guard let src else { return }
        let added = sync.add(src, to: packID)
        announce(added, in: p)
    }

    /// The page, repo or Mail thread in front, kept up to date in a pack (from the ⌥⇧Space panel).
    private func keepFrontUpdated(in packID: UUID, app: NSRunningApplication) {
        Task {
            guard let p = store.pack(packID) else { return }
            guard let src = await sync.sourceForFront(app) else {
                toast.show(ToastContent(icon: .symbol("questionmark.circle"), title: "Shapr couldn't tell which page this is",
                                        subtitle: app.bundleIdentifier == "com.apple.mail" ? "Select a message in Mail first." : "Open the page in your browser first.",
                                        tint: DS.warning), duration: 4)
                return
            }
            announce(sync.add(src, to: packID), in: p)
        }
    }

    private func announce(_ s: PackSource, in p: Pack) {
        let detail: String
        switch s.kind {
        case .folder: detail = "Files you add or change there show up in \(p.name)."
        case .github: detail = "README, open issues and pull requests, and recent commits. Checked every 30 minutes."
        case .notion: detail = Keychain.get(SourceSync.notionAccount) == nil ? "Add your Notion token in Settings → Connections so Shapr can read it." : "Checked every 30 minutes."
        case .web: detail = "Checked every 30 minutes."
        case .page: detail = "It updates whenever you have it open in your browser."
        case .mail: detail = "Each message in this thread is added when you open it in Mail."
        }
        toast.show(ToastContent(icon: .symbol("arrow.triangle.2.circlepath"), title: "Keeping \(p.name) updated from \(s.title)",
                                subtitle: detail,
                                actions: [ToastAction(title: "Show") { [weak self] in self?.showLibrary(select: p.id) }],
                                pack: p, eyebrow: "Live source"), duration: 6)
    }

    func showSettings() {
        if settingsWindow == nil {
            let w = NSWindow(contentRect: NSRect(origin: .zero, size: SettingsView.size),
                             styleMask: [.titled, .closable, .fullSizeContentView], backing: .buffered, defer: false)
            w.title = "Shapr Settings"
            w.titlebarAppearsTransparent = true
            w.toolbarStyle = .unified
            w.isReleasedWhenClosed = false
            settingsWindow = w
        }
        settingsWindow?.contentView = NSHostingView(rootView: SettingsView(appleStatus: sorter.appleModelStatus,
                                                                           onCheckUpdates: { [weak self] in self?.updater.check(silent: false) }) {
            [weak self] in self?.settingsWindow?.close()
        })
        settingsWindow?.center()
        NSApp.activate()
        settingsWindow?.makeKeyAndOrderFront(nil)
    }

    private func copyPrompt(_ id: UUID) {
        guard let p = store.pack(id) else { return }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(Exporter.prompt(for: p), forType: .string)
        toast.show(ToastContent(icon: .pack(p), title: "Copied \(p.name) as a prompt",
                                subtitle: "Paste it into Claude, ChatGPT or any app."), duration: 2.5)
    }

    private func exportMarkdown(_ id: UUID) {
        guard let p = store.pack(id) else { return }
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(p.name).md"
        panel.allowedContentTypes = [.init(filenameExtension: "md")!]
        NSApp.activate()
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Exporter.markdown(packName: p.name, captures: p.captures).write(to: url, atomically: true, encoding: .utf8)
    }

    private func safeShare(_ id: UUID) {
        guard let p = store.pack(id) else { return }
        if let w = shareWindows[id] { NSApp.activate(); w.makeKeyAndOrderFront(nil); return }
        let session = ShareSession(pack: p, rules: store.redactionRules(for: id))
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1040, height: 680),
                         styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        w.title = "Share “\(p.name)” Safely"
        w.isReleasedWhenClosed = false
        w.delegate = self
        w.contentView = NSHostingView(rootView: ShareReviewView(
            session: session,
            liveLink: shares.shared[id].flatMap { URL(string: $0.url) },
            onLiveLink: { [weak self, weak w] in self?.shareLive(session, window: w) },
            onCopy: { [weak self] in
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.output, forType: .string)
                self?.store.saveRedactionRules(session.rules(), for: id)
                self?.toast.show(ToastContent(icon: .symbol("hand.raised.fill"), title: "Copied the shared copy",
                                              subtitle: "\(session.hiddenCount) private item\(session.hiddenCount == 1 ? "" : "s") hidden."),
                                 duration: 2.5)
            },
            onSave: { [weak self, weak w] in
                guard let self else { return }
                try? FileManager.default.createDirectory(at: self.store.sharedDir, withIntermediateDirectories: true)
                let panel = NSSavePanel()
                panel.directoryURL = self.store.sharedDir
                panel.nameFieldStringValue = "\(p.name) (shared).md"
                panel.allowedContentTypes = [.init(filenameExtension: "md")!]
                guard let w, panel.runModal() == .OK, let url = panel.url else { return }
                try? session.output.write(to: url, atomically: true, encoding: .utf8)
                self.store.saveRedactionRules(session.rules(), for: id)
                NSWorkspace.shared.activateFileViewerSelecting([url])
                w.close()
            },
            onSaveBundle: { [weak self, weak w] in
                guard let self else { return }
                try? FileManager.default.createDirectory(at: self.store.sharedDir, withIntermediateDirectories: true)
                let panel = NSSavePanel()
                panel.directoryURL = self.store.sharedDir
                panel.nameFieldStringValue = "\(p.name).\(PackBundle.fileExtension)"
                panel.allowedContentTypes = [.init(filenameExtension: PackBundle.fileExtension)!]
                guard let w, panel.runModal() == .OK, let url = panel.url else { return }
                do {
                    try PackBundle.write(name: p.name, emoji: p.meta.emoji, captures: session.sharedCaptures(),
                                         imageFolder: self.store.pack(id)?.folder, to: url)
                    self.store.saveRedactionRules(session.rules(), for: id)
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                    w.close()
                } catch {
                    self.toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't save the pack",
                                                 subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
                }
            }
        ))
        w.center()
        shareWindows[id] = w
        NSApp.activate()
        w.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        guard let w = notification.object as? NSWindow else { return }
        shareWindows = shareWindows.filter { $0.value !== w }
    }
}

/// The library window: content runs under a transparent title bar (sidebar below the traffic lights).
enum LibraryWindow {
    @MainActor
    static func style(_ w: NSWindow) {
        w.title = "Shapr"
        w.toolbarStyle = .unified
        w.titlebarSeparatorStyle = .automatic
        w.backgroundColor = NSColor.dynamic(light: NSColor(hex: 0xF6F7F9), dark: NSColor(hex: 0x17191F))
    }
}
