import AppKit
import FoundationModels
import ShaprCore
import SwiftUI

/// What the Flow UI shows. Rebuilt from the engine after every change; nothing here is a second copy of memory.
@MainActor
final class FlowModel: ObservableObject {
    @Published var state: SessionState = .off
    @Published var apps: [AppPermission] = []
    @Published var summary: TaskSummary?
    @Published var resume: TaskSummary?
    @Published var question: TaskQuestion?
    @Published var settings = FlowEngine.Settings()
    @Published var tasks: [TaskState] = []
    @Published var storedBytes = 0
    @Published var immediateCount = 0
    @Published var recordCount = 0
    @Published var metrics = ""
    @Published var loadProblem: String?
    @Published var localModel = false
    @Published var claudeReady = false
}

/// Shapr Flow inside the app: the session, the permission prompt, the menu-bar popover, and the
/// Lens / Threads / Simulate actions after a circle. Session logic lives in `ShaprCore.FlowEngine`.
@MainActor
final class FlowController {
    let engine: FlowEngine
    let model = FlowModel()
    private let store: PackStore
    private let toast: ToastController
    private lazy var observer: ActivityObserver = {
        let o = ActivityObserver(engine: engine)
        o.onNeedsPermission = { [weak self] app in self?.askPermission(app) }
        o.onActivated = { [weak self] bundleID in
            guard let self, let asked = self.prompt.bundleID, asked != bundleID else { return }
            self.prompt.cancel()
        }
        return o
    }()
    private let prompt = PermissionPromptController()
    private let actionBar = FlowActionBarController()
    private lazy var panel = FlowPanelController(flow: self)
    private var popover: NSPopover?
    private var privacyWindow: NSWindow?
    private var questionToast: UUID?
    private var refreshQueued = false

    /// Hooks into the rest of the app.
    var openResume: (UUID?) -> Void = { _ in }
    var showMenu: () -> Void = {}
    var showLibrary: (UUID?) -> Void = { _ in }
    /// After the model is rebuilt (the menu-bar icon shows the session state).
    var onRefresh: () -> Void = {}

    init(store: PackStore, toast: ToastController) {
        self.store = store
        self.toast = toast
        engine = FlowEngine(directory: FlowStore.defaultDirectory())
        engine.onChange = { [weak self] in self?.scheduleRefresh() }
        engine.onQuestion = { [weak self] q in self?.showQuestion(q) }
        engine.onSuggestion = { [weak self] s in self?.showSuggestion(s) }
        refresh()
    }

    // MARK: Session

    func startSession(offerResume offer: Bool = true) {
        engine.start()
        observer.start()
        refresh()
        if offer, let r = engine.resumeCandidate() { offerResume(r) }
    }

    func pause() {
        engine.pause()
        observer.stop() // nothing runs while paused
        prompt.cancel()
        refresh()
    }

    func resumeSession() {
        engine.resume()
        observer.start()
        refresh()
    }

    func endSession() {
        observer.stop()
        engine.end()
        prompt.cancel()
        refresh()
        toast.show(ToastContent(icon: .symbol("stop.circle"), title: "Session ended",
                                subtitle: engine.lastEpisodes.isEmpty ? "Nothing new was kept." : "Kept \(engine.lastEpisodes.count) task summar\(engine.lastEpisodes.count == 1 ? "y" : "ies") for next time. Temporary observations were cleared."),
                   duration: 4)
    }

    func applicationWillTerminate() {
        observer.stop()
        engine.save(force: true, sync: true)
    }

    // MARK: Model

    private func scheduleRefresh() {
        guard !refreshQueued else { return }
        refreshQueued = true
        DispatchQueue.main.async { [weak self] in
            MainActor.assumeIsolated {
                self?.refreshQueued = false
                self?.refresh()
            }
        }
    }

    func refresh() {
        let m = model
        m.state = engine.state
        m.apps = engine.auth.all
        m.summary = engine.summary()
        m.resume = engine.state == .off || engine.activeTask == nil ? engine.resumeCandidate() : nil
        m.question = engine.kernel.pendingQuestion
        m.settings = engine.settings
        m.tasks = engine.kernel.tasks.sorted { $0.lastActivity > $1.lastActivity }
        m.storedBytes = engine.storedBytes
        m.immediateCount = engine.kernel.immediate.events.count
        m.recordCount = engine.kernel.records.count
        m.loadProblem = engine.loadProblem
        onRefresh()
    }

    /// What's available for Lens (the on-device model, a Claude key). Checked when a surface opens,
    /// not after every observation, since reading the key touches the Keychain.
    func refreshCapabilities() {
        if case .available = SystemLanguageModel.default.availability { model.localModel = true } else { model.localModel = false }
        model.claudeReady = SorterSettings.apiKey != nil
    }

    func refreshMetrics() {
        var s = engine.metrics.report
        if let r = engine.metrics.timing("read") {
            s = String(format: "Window reads: %d, avg %.1f ms (background thread)\n", r.count, r.averageMs) + s
        }
        model.metrics = s
    }

    func updateSettings(_ f: (inout FlowEngine.Settings) -> Void) {
        var s = engine.settings
        f(&s)
        engine.settings = s
        refresh()
    }

    // MARK: Permission prompt

    private func askPermission(_ app: NSRunningApplication) {
        guard let b = app.bundleIdentifier, engine.decision(for: b) == .ask else { return }
        let name = app.localizedName ?? b
        prompt.show(bundleID: b, appName: name, icon: app.icon) { [weak self] choice in
            guard let self else { return }
            if let access = choice {
                self.engine.setAccess(access, bundleID: b, name: name)
            } else {
                self.engine.dismissPrompt(bundleID: b)
            }
            self.refresh()
            self.observer.refresh()
        }
    }

    func setAccess(_ access: AppAccess?, bundleID: String, name: String) {
        if let access { engine.setAccess(access, bundleID: bundleID, name: name) } else { engine.revoke(bundleID: bundleID) }
        refresh()
        if engine.state == .active { observer.refresh() }
    }

    // MARK: Questions, suggestions, resume

    private func showQuestion(_ q: TaskQuestion) {
        questionToast = toast.show(ToastContent(
            icon: .symbol("questionmark.bubble"), title: "Is this part of \(q.taskTitle)?",
            subtitle: FlowText.clip(q.about, 70),
            actions: [ToastAction(title: "Yes", style: .primary) { [weak self] in self?.engine.answer(.yes) },
                      ToastAction(title: "Separate task") { [weak self] in self?.engine.answer(.separateTask) },
                      ToastAction(title: "Ignore") { [weak self] in self?.engine.answer(.ignore) }],
            eyebrow: "Shapr Flow"), duration: 10)
    }

    private func showSuggestion(_ s: Suggestion) {
        toast.show(ToastContent(icon: .symbol("arrow.uturn.backward.circle"), title: s.title, subtitle: s.detail,
                                actions: [ToastAction(title: "Show context", style: .primary) { [weak self] in self?.reviewTask(s.taskID) },
                                          ToastAction(title: "Dismiss") {}]), duration: 9)
    }

    private func offerResume(_ s: TaskSummary) {
        let lines = s.resume.dropFirst().prefix(2).map(\.text).joined(separator: " ")
        toast.show(ToastContent(icon: .symbol("arrow.clockwise.circle"), title: "Continue where you left off?",
                                subtitle: FlowText.clip(s.resume.first?.text ?? s.task.title, 90) + (lines.isEmpty ? "" : " " + FlowText.clip(lines, 120)),
                                actions: [ToastAction(title: "Continue", style: .primary) { [weak self] in self?.continueTask(s.task.id) },
                                          ToastAction(title: "Review context") { [weak self] in self?.reviewTask(s.task.id) },
                                          ToastAction(title: "Dismiss") {}],
                                eyebrow: "Shapr Flow"), duration: 14)
    }

    func continueTask(_ id: UUID) {
        engine.continueTask(id)
        refresh()
        reviewTask(id)
    }

    func reviewTask(_ id: UUID?) {
        closePopover()
        panel.showThreads(taskID: id ?? engine.activeTask?.id)
    }

    /// Turns the task into a checkpoint in a pack (made on request if it has none), then opens the
    /// existing Resume flow so the user reviews exactly what goes to the AI.
    func continueInAI(_ taskID: UUID) {
        guard let task = engine.kernel.task(taskID) else { return }
        let packID = task.packID.flatMap { store.pack($0)?.id }
            ?? store.equippedPackID.flatMap { store.pack($0)?.id }
            ?? store.createPack(name: FlowText.clip(task.title, 40), emoji: "🧵", autoNamed: false).id
        engine.edit { $0.link(taskID: taskID, packID: packID) }
        guard let summary = engine.summary(for: taskID) else { return }
        let cp = Self.checkpoint(from: summary, records: engine.kernel.records(for: taskID))
        if store.saveCheckpoint(cp, for: packID) {
            engine.edit { $0.noteCheckpoint("\(packID.uuidString)/\(cp.id.uuidString)", taskID: taskID) }
        }
        closePopover()
        panel.close()
        openResume(packID)
    }

    /// Flow memory → Shapr's existing checkpoint format. Only stated or observed things go in.
    static func checkpoint(from s: TaskSummary, records: [MemoryRecord]) -> Checkpoint {
        func pts(_ k: MemoryRecord.Kind...) -> [Checkpoint.Point] {
            records.filter { k.contains($0.kind) && $0.isCurrent }.map { r in
                Checkpoint.Point(text: r.provenance.isFact ? r.text : "\(r.text) (\(r.provenance.label))")
            }
        }
        var cp = Checkpoint()
        cp.title = s.task.title
        cp.goal = records.first { $0.kind == .goal && $0.isCurrent }?.text ?? ""
        cp.decisions = pts(.decision)
        cp.tried = pts(.attempt)
        cp.openProblems = pts(.error, .openQuestion)
        cp.nextStep = records.filter { $0.kind == .nextStep && $0.isCurrent }.max { $0.lastSeen < $1.lastSeen }?.text ?? ""
        cp.rules = pts(.instruction)
        cp.tabs = s.task.sources.compactMap { src in
            guard let u = src.location, u.hasPrefix("http"), FlowReader.browsers.contains(src.bundleID) else { return nil }
            return Checkpoint.Tab(url: u, title: src.title, browserBundleID: src.bundleID)
        }
        cp.author = "Shapr Flow"
        cp.engine = "Shapr Flow (from your working memory; no AI)"
        return cp
    }

    // MARK: Deletion

    func deleteTask(_ id: UUID) {
        let files = engine.deleteTask(id)
        removeCheckpoints(files)
        refresh()
    }

    func deleteAll() {
        let files = engine.deleteAll()
        removeCheckpoints(files)
        refresh()
    }

    private func removeCheckpoints(_ refs: [String]) {
        for ref in refs {
            let parts = ref.split(separator: "/")
            guard parts.count == 2, let p = UUID(uuidString: String(parts[0])), let cp = UUID(uuidString: String(parts[1])) else { continue }
            store.deleteCheckpoint(cp, from: p)
        }
    }

    // MARK: Popover and privacy window

    func togglePopover(from button: NSStatusBarButton) {
        if let p = popover, p.isShown { p.performClose(nil); return }
        refresh()
        refreshCapabilities()
        let p = NSPopover()
        p.behavior = .transient
        p.animates = !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
        p.contentViewController = NSHostingController(rootView: FlowHomeView(model: model, flow: self))
        p.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        p.contentViewController?.view.window?.makeKey()
        popover = p
    }

    func closePopover() { popover?.performClose(nil) }

    func showPrivacy() {
        closePopover()
        refresh()
        refreshCapabilities()
        refreshMetrics()
        if let w = privacyWindow { w.makeKeyAndOrderFront(nil); NSApp.activate(); return }
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 640),
                         styleMask: [.titled, .closable, .resizable, .fullSizeContentView], backing: .buffered, defer: false)
        w.title = "Shapr Flow · Privacy & Memory"
        w.titlebarAppearsTransparent = true
        w.isReleasedWhenClosed = false
        w.contentView = NSHostingView(rootView: FlowPrivacyView(model: model, flow: self))
        w.center()
        privacyWindow = w
        w.makeKeyAndOrderFront(nil)
        NSApp.activate()
    }

    // MARK: Circle → L / T / S

    /// Replaces the screenshot toast with the L/T/S bar. `add` keeps the old default: doing nothing saves the shot.
    func offerActions(text: String, draft: CaptureDraft, image: NSImage, png: Data?, rect: CGRect,
                      add: @escaping () -> Void, saveCopy: @escaping () -> Void, consume: @escaping () -> Void,
                      ask: @escaping () -> Void) {
        let evidence = EvidenceRef(kind: .capture, bundleID: draft.bundleID ?? "unknown", appName: draft.appName ?? "Screen",
                                   title: draft.title, location: draft.url, at: Date(), excerpt: FlowText.clip(text, 200))
        actionBar.show(near: rect, taskTitle: engine.activeTask?.title, sessionOn: engine.state == .active,
                       onLens: { [weak self] in consume(); self?.panel.showLens(text: text, image: image, png: png, evidence: evidence, save: saveCopy) },
                       onThreads: { [weak self] mode in self?.threads(text: text, evidence: evidence, mode: mode, save: add) },
                       onSimulate: { [weak self] in consume(); self?.panel.showSimulate(text: text, evidence: evidence) },
                       onAdd: add, onAsk: ask, onTimeout: add)
    }

    enum ThreadsMode { case remember, decision, attempt, newTask, inspect }

    /// T: "This is important to my current task. Remember it." Also keeps the capture in a pack, as before.
    func threads(text: String, evidence: EvidenceRef, mode: ThreadsMode, save: @escaping () -> Void) {
        switch mode {
        case .inspect:
            panel.showThreads(taskID: engine.activeTask?.id)
            return
        case .newTask:
            let title = FlowText.clip(FlowText.firstLine(text), 48)
            engine.remember(text, evidence: evidence, newTaskTitle: title.isEmpty ? "New task" : title)
        case .decision: engine.remember(text, kind: .decision, evidence: evidence)
        case .attempt: engine.remember(text, kind: .attempt, evidence: evidence)
        case .remember: engine.remember(text, evidence: evidence)
        }
        if let t = engine.activeTask, t.packID == nil, let eq = store.equippedPackID {
            engine.edit { $0.link(taskID: t.id, packID: eq) }
        }
        save() // the screenshot itself goes to the pack, exactly like "Add" (the source archive)
        let task = engine.activeTask
        toast.show(ToastContent(icon: .symbol("point.3.connected.trianglepath.dotted"), title: "Remembered for \(task?.title ?? "this task")",
                                subtitle: "Pinned to the task. You can review or remove it any time.",
                                actions: [ToastAction(title: "Review") { [weak self] in self?.reviewTask(task?.id) }],
                                eyebrow: "Threads"), duration: 4)
        refresh()
    }

    // MARK: Demo

    /// Plays the scripted TechniGala session through the live engine (VS Code and Safari for this session, Messages blocked).
    func playDemo() {
        if engine.state != .active { startSession() }
        let r = FlowDemo.play(into: engine, start: Date().addingTimeInterval(-38 * 60))
        refresh()
        toast.show(ToastContent(icon: .symbol("play.circle"), title: "Demo activity played",
                                subtitle: "\(r.accepted) kept · \(r.duplicates) repeats folded · \(r.rejected) refused (blocked app)"), duration: 5)
    }

    // MARK: AI (on this Mac first; Claude only when asked and allowed)

    var cloudAllowed: Bool { engine.settings.processing == .askBeforeCloud && SorterSettings.apiKey != nil }

    func localAnswer(system: String, prompt: String) async -> String? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        do {
            let r = try await LanguageModelSession(instructions: system).respond(to: String(prompt.prefix(7000)))
            return r.content
        } catch {
            return nil
        }
    }

    func cloudStream(system: String, prompt: String, images: [Data]) -> AsyncThrowingStream<String, Error>? {
        guard cloudAllowed, let key = SorterSettings.apiKey else { return nil }
        return ClaudeClient(apiKey: key, model: SorterSettings.model).stream(system: system, prompt: prompt, images: images, effort: "low", maxTokens: 1200)
    }
}

extension PackStore {
    /// Removes one checkpoint file (used when Flow memory it came from is deleted).
    func deleteCheckpoint(_ id: UUID, from packID: UUID) {
        guard let dir = pack(packID)?.folder.appendingPathComponent(".shapr/checkpoints", isDirectory: true),
              let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        let suffix = "-" + id.uuidString.prefix(8) + ".json"
        for f in files where f.lastPathComponent.hasSuffix(suffix) { try? FileManager.default.removeItem(at: f) }
        objectWillChange.send()
    }
}
