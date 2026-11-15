import AppKit
import Carbon
import os

let relayLog = Logger(subsystem: "app.shapr.Shapr", category: "relay")

enum RelaySettings {
    private static func flag(_ key: String) -> Bool { UserDefaults.standard.object(forKey: key) as? Bool ?? true }
    /// Offer to continue elsewhere when a free AI runs out of messages.
    static var watchLimits: Bool { get { flag("relay.watchLimits") } set { UserDefaults.standard.set(newValue, forKey: "relay.watchLimits") } }
    /// Let the next AI ask for more with "@shapr …".
    static var askBack: Bool { get { flag("relay.askBack") } set { UserDefaults.standard.set(newValue, forKey: "relay.askBack") } }
    /// Ask the next AI to read back the goal, rules and next step, and check them.
    static var readBack: Bool { get { flag("relay.readBack") } set { UserDefaults.standard.set(newValue, forKey: "relay.readBack") } }
}

/// Moves your work between AI chats with as little lost as possible, using only the screen:
/// - notices when a free AI runs out of messages and offers to continue in another one;
/// - reads the chat, saves progress, opens the other AI and pastes a handoff sized for it;
/// - then watches the new chat: checks its read-back against what you saved, and answers its
///   "@shapr …" requests from your pack, one click each.
/// Nothing is sent without you: the handoff waits in the message box for you to press Return.
@MainActor
final class RelayController {
    private let store: PackStore
    private let toast: ToastController
    private var limitTimer: Timer?
    private var checkingLimits = false
    private var offeredLimit: [String: Date] = [:]
    /// A banner has to be there on two checks in a row before Shapr says anything.
    private var seenLimit: (key: String, notice: String, at: Date)?
    private var watch: Watch?
    private var watchTimer: Timer?
    private var requestQueue: [(String, (title: String, text: String))] = []
    private var showingRequest = false

    struct Watch {
        let app: NSRunningApplication
        let handoff: Handoff
        let packID: UUID?
        let checkpoint: Checkpoint
        var baseline: Int?
        var lastActivity = Date()
        var readBackDone = false
        var handled: Set<String> = []
        var previous: [String] = []
        var polling = false
    }

    var isWatching: Bool { watch != nil }

    init(store: PackStore, toast: ToastController) {
        self.store = store
        self.toast = toast
    }

    func start() {
        limitTimer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkLimits() }
        }
    }

    // MARK: Out of messages

    private static let browsers = ChatReader.browserIDs

    private func checkLimits() {
        guard RelaySettings.watchLimits, CaptureService.isTrusted, !checkingLimits,
              let app = NSWorkspace.shared.frontmostApplication, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let bid = app.bundleIdentifier ?? ""
        guard ChatReader.mightBeChat(bundleID: bid) else { return }
        checkingLimits = true
        let pid = app.processIdentifier
        Task {
            let found: (String, String, String?)? = await Task.detached(priority: .utility) {
                let info = ChatReader.pageInfo(pid: pid)
                guard let service = ChatReader.service(url: info.url, bundleID: bid), ChatReader.isChatPage(info.url),
                      let notice = ChatReader.limitNotice(pid: pid) else { return nil }
                return (service, notice, info.url)
            }.value
            checkingLimits = false
            guard let found else { seenLimit = nil; return }
            let key = found.2 ?? found.0
            if let seen = seenLimit, seen.key == key, seen.notice == found.1, Date().timeIntervalSince(seen.at) < 20 {
                offerRescue(service: found.0, notice: found.1, url: found.2, app: app)
            } else {
                seenLimit = (key, found.1, Date())
            }
        }
    }

    private func offerRescue(service: String, notice: String, url: String?, app: NSRunningApplication) {
        let key = url ?? service
        if let last = offeredLimit[key], Date().timeIntervalSince(last) < 30 * 60 { return }
        offeredLimit[key] = Date()
        relayLog.notice("limit notice in \(service, privacy: .public)")
        let others = ChatReader.services.map(\.name).filter { $0 != service }
        toast.show(ToastContent(icon: .symbol("arrow.triangle.branch"), title: "\(service) hit its message limit",
                                subtitle: "It says “\(notice.truncated(80))” Keep going in another AI with this chat and your rules.",
                                actions: others.enumerated().map { i, name in
                                    ToastAction(title: i == 0 ? "Continue in \(name)" : name, style: i == 0 ? .primary : .normal) { [weak self] in
                                        self?.relay(to: name, from: app)
                                    }
                                },
                                tint: DS.accent), duration: 25)
    }

    // MARK: Continue in another AI

    /// Reads the chat in `app` (the front app by default), saves progress, opens `target` and pastes a handoff.
    func relay(to target: String, from app: NSRunningApplication? = nil) {
        guard CaptureService.isTrusted else { CaptureService.requestTrust(); return }
        guard let app = app ?? NSWorkspace.shared.frontmostApplication else { return }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier
        let appName = app.localizedName ?? "AI"
        let started = Date()
        let working = toast.show(ToastContent(icon: .spinner, title: "Reading this chat…",
                                              subtitle: "Then Shapr saves your progress and opens \(target)."), duration: nil)
        Task {
            let chat: ChatTranscript? = await Task.detached(priority: .userInitiated) {
                let info = ChatReader.pageInfo(pid: pid)
                let service = ChatReader.service(url: info.url, bundleID: bid) ?? appName
                return ChatReader.read(pid: pid, service: service, url: info.url, title: info.title)
            }.value
            toast.dismiss(ifToken: working)
            guard let chat else {
                toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't read this chat",
                                        subtitle: "Open the conversation so its messages are on screen, then try again. Or say “save my progress”, then “pick up where I left off”.",
                                        tint: DS.warning), duration: 7)
                return
            }
            relayLog.notice("read \(chat.turns.count) messages from \(chat.service, privacy: .public) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
            finishRelay(chat, to: target, sourceBundleID: bid)
        }
    }

    private func finishRelay(_ chat: ChatTranscript, to target: String, sourceBundleID: String?) {
        // The pack you equipped is what you're working on. Otherwise this chat gets its own pack (reused the
        // next time the same chat is relayed), so nothing lands in an unrelated pack.
        let named = chat.title ?? "\(chat.service) chat"
        let pack = store.pack(store.equippedPackID)
            ?? store.packs.first { p in store.latestCheckpoint(for: p.id)?.conversation?.url.map { $0 == chat.url } == true }
            ?? store.createPack(name: named, emoji: "💬", autoNamed: true)
        // Rules carry over only from earlier saves of this same conversation.
        let previous = store.latestCheckpoint(for: pack.id).flatMap { $0.conversation?.url != nil && $0.conversation?.url == chat.url ? $0 : nil }
        var cp = ChatDigest.checkpoint(from: chat, previous: previous)
        cp.author = "Shapr"
        cp.created = Date()
        store.saveCheckpoint(cp, for: pack.id)
        let handoff = HandoffBuilder.build(pack: store.pack(pack.id), checkpoint: cp, target: HandoffBuilder.target(for: target),
                                           options: .init(askBack: RelaySettings.askBack, readBack: RelaySettings.readBack,
                                                          includeEvidence: true, includeTabs: false))
        guard let service = ChatReader.service(named: target), let url = URL(string: service.newChatURL) else { return }
        // Same browser you were in; the default browser if you were in a desktop app.
        if let bid = sourceBundleID, Self.browsers.contains(bid), let browser = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            NSWorkspace.shared.open([url], withApplicationAt: browser, configuration: NSWorkspace.OpenConfiguration())
        } else {
            NSWorkspace.shared.open(url)
        }
        let opening = toast.show(ToastContent(icon: .spinner, title: "Opening \(target)…",
                                              subtitle: "Progress saved to \(pack.label): \(chat.turns.count) messages, \(cp.rules?.count ?? 0) rules."), duration: nil)
        pasteWhenReady(handoff, target: target, packID: pack.id, checkpoint: cp, deadline: Date().addingTimeInterval(15), token: opening, attempt: 0)
    }

    /// Waits for the new chat's message box, then pastes. Gives up after the deadline and leaves it on the clipboard.
    private func pasteWhenReady(_ handoff: Handoff, target: String, packID: UUID, checkpoint: Checkpoint, deadline: Date, token: UUID, attempt: Int) {
        let front = NSWorkspace.shared.frontmostApplication
        let ready: Bool = {
            guard let front, Self.browsers.contains(front.bundleIdentifier ?? "") else { return false }
            let pid = front.processIdentifier
            guard ChatReader.quickService(pid: pid, bundleID: front.bundleIdentifier) == target
                    || ChatReader.service(url: ChatReader.pageInfo(pid: pid).url, bundleID: nil) == target else { return false }
            // New chats put the cursor in the message box themselves; only search the page now and then.
            return ChatReader.composerFocused(pid: pid) || (attempt % 4 == 3 && ChatReader.focusComposer(pid: pid))
        }()
        if ready, let front {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                guard let self else { return }
                ChatReader.focusComposer(pid: front.processIdentifier)
                TextInserter.paste(handoff.text, into: front) { [weak self] ok in
                    guard let self else { return }
                    self.toast.dismiss(ifToken: token)
                    if ok {
                        self.pasted(handoff, in: front, target: target, packID: packID, checkpoint: checkpoint)
                    } else {
                        self.leftOnClipboard(handoff, target: target)
                    }
                }
            }
            return
        }
        guard Date() < deadline else {
            toast.dismiss(ifToken: token)
            leftOnClipboard(handoff, target: target)
            if let front, Self.browsers.contains(front.bundleIdentifier ?? "") {
                startWatching(handoff, in: front, packID: packID, checkpoint: checkpoint)
            }
            return
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.pasteWhenReady(handoff, target: target, packID: packID, checkpoint: checkpoint, deadline: deadline, token: token, attempt: attempt + 1)
        }
    }

    private func leftOnClipboard(_ handoff: Handoff, target: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(handoff.text, forType: .string)
        toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "Ready to paste in \(target)",
                                subtitle: "Click the message box and press ⌘V. It's on your clipboard.", tint: DS.warning), duration: 8)
    }

    private func pasted(_ handoff: Handoff, in app: NSRunningApplication, target: String, packID: UUID?, checkpoint: Checkpoint) {
        startWatching(handoff, in: app, packID: packID, checkpoint: checkpoint)
        var extras: [String] = []
        if handoff.readBack { extras.append("check it read everything") }
        if handoff.askBack { extras.append("answer its @shapr requests") }
        toast.show(ToastContent(icon: .symbol("checkmark.circle"), title: "Pasted into \(target). Check it, then press Return.",
                                subtitle: (handoff.chat.map { $0.summary + "." } ?? "About \(handoff.tokens.formatted()) tokens, \(HandoffBuilder.target(for: target).sizeNote).")
                                    + (extras.isEmpty ? "" : " Shapr will " + extras.joined(separator: " and ") + "."),
                                actions: [ToastAction(title: "Stop watching") { [weak self] in self?.stopWatching() }],
                                tint: DS.success), duration: 8)
    }

    // MARK: Watching the new chat

    /// After a handoff is pasted into `app`: check the read-back and answer "@shapr" requests.
    func startWatching(_ handoff: Handoff, in app: NSRunningApplication, packID: UUID?, checkpoint: Checkpoint) {
        guard handoff.askBack || handoff.readBack else { return }
        stopWatching()
        watch = Watch(app: app, handoff: handoff, packID: packID, checkpoint: checkpoint)
        relayLog.notice("watching \(app.localizedName ?? "?", privacy: .public) for read-back and requests")
        watchTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
        poll()
    }

    func stopWatching() {
        watchTimer?.invalidate()
        watchTimer = nil
        watch = nil
        requestQueue.removeAll()
    }

    private func poll() {
        guard var w = watch else { return }
        if w.app.isTerminated || Date().timeIntervalSince(w.lastActivity) > 25 * 60 { stopWatching(); return }
        // Only while you're in that chat.
        guard !w.polling, NSWorkspace.shared.frontmostApplication?.processIdentifier == w.app.processIdentifier else { return }
        w.polling = true
        watch = w
        let pid = w.app.processIdentifier
        let service = w.handoff.targetName
        Task {
            let chat = await Task.detached(priority: .utility) {
                ChatReader.read(pid: pid, service: service, url: nil, title: nil)
            }.value
            guard var w = self.watch, w.app.processIdentifier == pid else { return }
            w.polling = false
            let replies = (chat?.turns ?? []).filter { $0.role == .assistant }.map(\.text)
            // The first read sets where the new conversation starts.
            guard let base = w.baseline else {
                w.baseline = replies.count
                w.previous = replies
                self.watch = w
                return
            }
            let fresh = Array(replies.dropFirst(base))
            let before = Array(w.previous.dropFirst(base))
            w.previous = replies
            self.watch = w
            for (i, text) in fresh.enumerated() {
                // A reply counts once it stops changing (the AI finished writing it).
                guard i < before.count, before[i] == text else { continue }
                self.handleReply(text, isFirst: i == 0)
            }
        }
    }

    private func handleReply(_ text: String, isFirst: Bool) {
        guard var w = watch else { return }
        let key = String(text.prefix(200))
        if isFirst, !w.readBackDone, w.handoff.readBack {
            w.readBackDone = true
            w.lastActivity = Date()
            watch = w
            if let lines = ReadBack.parse(text) {
                showReadBack(ReadBack.check(lines, against: w.checkpoint, reply: text))
            }
        }
        guard w.handoff.askBack else { return }
        for req in HandoffBuilder.requests(in: text) {
            let id = key + "|" + req.lowercased()
            guard var w = watch, !w.handled.contains(id) else { continue }
            w.handled.insert(id)
            w.lastActivity = Date()
            watch = w
            let pack = store.pack(w.packID)
            if let answer = HandoffBuilder.answer(req, handoff: w.handoff, pack: pack, checkpoint: w.checkpoint) {
                requestQueue.append((req, answer))
            } else {
                toast.show(ToastContent(icon: .symbol("questionmark.circle"), title: "\(w.handoff.targetName) asked for “\(req.truncated(40))”",
                                        subtitle: "Shapr has nothing on that in \(pack?.name ?? "your pack") or the earlier chat.",
                                        tint: DS.warning), duration: 6)
            }
        }
        showNextRequest()
    }

    private func showReadBack(_ r: ReadBack.Result) {
        guard let w = watch else { return }
        let name = w.handoff.targetName
        relayLog.notice("read-back: \(r.total - r.missed.count) of \(r.total) carried over")
        if r.allCovered {
            toast.show(ToastContent(icon: .symbol("checkmark.seal"), title: "\(name) got everything",
                                    subtitle: "All \(r.total) things you saved (goal, rules and next step) carried over.",
                                    tint: DS.success, eyebrow: "Read-back"), duration: 5)
            return
        }
        toast.show(ToastContent(icon: .symbol("exclamationmark.bubble"),
                                title: "\(name) missed \(r.missed.count) of \(r.total)",
                                subtitle: r.missed.prefix(2).joined(separator: "\n") + (r.missed.count > 2 ? "\n+ \(r.missed.count - 2) more" : ""),
                                actions: [ToastAction(title: "Send it", style: .primary) { [weak self] in self?.send(ReadBack.followUp(r)) },
                                          ToastAction(title: "Ignore")],
                                tint: DS.warning, eyebrow: "Read-back"), duration: 30)
    }

    private func showNextRequest() {
        guard !showingRequest, !requestQueue.isEmpty, let w = watch else { return }
        let (_, answer) = requestQueue.removeFirst()
        showingRequest = true
        let name = w.handoff.targetName
        toast.show(ToastContent(icon: .symbol("arrow.down.doc"), title: "\(name) asked for \(answer.title)",
                                subtitle: "\(answer.text.count.formatted()) characters from \(store.pack(w.packID)?.name ?? "your pack"). Send it into the chat?",
                                actions: [ToastAction(title: "Send", style: .primary) { [weak self] in
                                              self?.showingRequest = false
                                              self?.send(answer.text)
                                          },
                                          ToastAction(title: "Skip") { [weak self] in
                                              self?.showingRequest = false
                                              self?.showNextRequest()
                                          }],
                                eyebrow: "Asked Shapr"), duration: 45, onTimeout: { [weak self] in
            self?.showingRequest = false
            self?.showNextRequest()
        })
    }

    /// Pastes into the watched chat's message box and sends it, but only if the text really landed there.
    private func send(_ text: String) {
        guard let w = watch else { return }
        let app = w.app
        let pid = app.processIdentifier
        ChatReader.focusComposer(pid: pid)
        TextInserter.paste(text, into: app) { [weak self] ok in
            guard let self else { return }
            guard ok else {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(text, forType: .string)
                self.toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "It's on your clipboard",
                                             subtitle: "Click the message box and press ⌘V.", tint: DS.warning), duration: 6)
                return
            }
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
                let probe = String(text.prefix(40)).singleLine
                let landed = ChatReader.composerText(pid: pid).map { $0.singleLine.contains(probe) } ?? false
                if landed {
                    let src = CGEventSource(stateID: .combinedSessionState)
                    let down = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: true)
                    let up = CGEvent(keyboardEventSource: src, virtualKey: CGKeyCode(kVK_Return), keyDown: false)
                    down?.post(tap: .cghidEventTap)
                    up?.post(tap: .cghidEventTap)
                } else {
                    self?.toast.show(ToastContent(icon: .symbol("return"), title: "Pasted. Press Return to send it.",
                                                  subtitle: "Shapr couldn't confirm it's in the message box, so it didn't send it for you."), duration: 5)
                }
                self?.showNextRequest()
            }
        }
    }
}
