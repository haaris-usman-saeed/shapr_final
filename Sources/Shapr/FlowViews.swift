import AppKit
import ShaprCore
import SwiftUI

// MARK: - Small shared pieces

/// How Shapr knows something, never by color alone.
struct ProvenanceChip: View {
    let provenance: Provenance
    var body: some View {
        Text(provenance.label)
            .font(.system(size: 10.5, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1.5)
            .foregroundStyle(provenance.isFact ? DS.text2 : DS.warning)
            .background(Capsule().strokeBorder(provenance.isFact ? DS.line : DS.warning.opacity(0.6), lineWidth: 0.75))
            .accessibilityLabel("Source: \(provenance.label)")
    }
}

struct EvidenceLine: View {
    let ref: EvidenceRef
    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: ref.kind == .page ? "globe" : ref.kind == .capture ? "lasso" : ref.kind == .note ? "text.bubble" : "macwindow")
            Text([ref.appName, ref.title.map { FlowText.clip($0, 50) }, FlowFormat.when(ref.at, now: Date())]
                .compactMap { $0 }.joined(separator: " · "))
                .lineLimit(1).truncationMode(.middle)
        }
        .font(.dsMeta).foregroundStyle(DS.text3)
        .help(ref.excerpt ?? ref.location ?? "")
    }
}

private func appIcon(_ bundleID: String) -> NSImage? {
    NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID).map { NSWorkspace.shared.icon(forFile: $0.path) }
}

// MARK: - Permission prompt

@MainActor
final class PermissionPromptController {
    private let panel = FloatingPanel(size: NSSize(width: 460, height: 200), level: .statusBar)
    private var done: ((AppAccess?) -> Void)?

    func show(appName: String, icon: NSImage?, completion: @escaping (AppAccess?) -> Void) {
        done?(nil) // a newer prompt replaces an unanswered one: that one counts as "not now"
        done = completion
        let view = PermissionPromptView(appName: appName, icon: icon) { [weak self] choice in
            MainActor.assumeIsolated { self?.answer(choice) }
        }
        panel.contentView = FirstMouseHostingView(rootView: view)
        panel.allowsKey = true
        let size = panel.contentView!.fittingSize
        if let vf = NSScreen.underMouse?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - 12, width: size.width, height: size.height), display: true)
        }
        panel.orderFrontRegardless()
        NSAccessibility.post(element: panel, notification: .windowCreated)
    }

    private func answer(_ a: AppAccess?) {
        panel.orderOut(nil)
        let d = done
        done = nil
        d?(a)
    }

    func close() {
        if panel.isVisible { answer(nil) }
    }
}

struct PermissionPromptView: View {
    let appName: String
    let icon: NSImage?
    let choose: (AppAccess?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DS.S.m) {
            HStack(alignment: .top, spacing: DS.S.m) {
                if let icon { Image(nsImage: icon).resizable().frame(width: 40, height: 40).accessibilityHidden(true) }
                VStack(alignment: .leading, spacing: 4) {
                    Text("Allow Shapr to observe \(appName)?").font(.dsHeadline).foregroundStyle(DS.text)
                    Text("Shapr can use permitted activity from this app — window titles, page addresses and error messages — to understand your current task and remember useful context. Nothing from \(appName) has been read.")
                        .font(.dsCallout).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                    Text("macOS lets Shapr use Accessibility in every app. This choice narrows that to the apps you trust.")
                        .font(.dsMeta).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
                IconButton(symbol: "xmark", help: "Not now", size: 22) { choose(nil) }
            }
            HStack(spacing: 6) {
                Button("Don't allow") { choose(.denied) }.buttonStyle(.dsSecondary)
                Spacer(minLength: 4)
                Button("Allow once") { choose(.once) }.buttonStyle(.dsSecondary)
                Button("Always allow") { choose(.always) }.buttonStyle(.dsSecondary)
                Button("Allow for this session") { choose(.session) }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
            }
        }
        .padding(DS.S.l)
        .dsPanel(width: 460)
        .onExitCommand { choose(nil) }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shapr permission request for \(appName)")
    }
}

// MARK: - L / T / S bar after a circle

@MainActor
final class FlowActionBarController {
    private let panel = FloatingPanel(size: NSSize(width: 300, height: 60), level: .statusBar)
    private var timeout: DispatchWorkItem?
    private var onTimeout: (() -> Void)?

    func show(near rect: CGRect, taskTitle: String?, sessionOn: Bool,
              onLens: @escaping () -> Void, onThreads: @escaping (FlowController.ThreadsMode) -> Void,
              onSimulate: @escaping () -> Void, onAdd: @escaping () -> Void, onAsk: @escaping () -> Void, onTimeout: @escaping () -> Void) {
        self.onTimeout = onTimeout
        func wrap(_ f: @escaping () -> Void) -> () -> Void { { [weak self] in MainActor.assumeIsolated { self?.close(); f() } } }
        let view = FlowActionBar(taskTitle: taskTitle, sessionOn: sessionOn,
                                 lens: wrap(onLens), threads: { mode in wrap { onThreads(mode) }() },
                                 simulate: wrap(onSimulate), add: wrap(onAdd), ask: wrap(onAsk),
                                 dismiss: wrap {})
        panel.contentView = FirstMouseHostingView(rootView: view)
        panel.allowsKey = true
        let size = panel.contentView!.fittingSize
        let screen = NSScreen.screens.first { $0.frame.intersects(rect) } ?? NSScreen.main
        let vf = screen?.visibleFrame ?? .zero
        var x = rect.midX - size.width / 2
        var y = rect.minY - size.height - 10
        if y < vf.minY + 8 { y = rect.maxY + 10 }
        x = min(max(x, vf.minX + 8), vf.maxX - size.width - 8)
        y = min(max(y, vf.minY + 8), vf.maxY - size.height - 8)
        panel.setFrame(NSRect(x: x, y: y, width: size.width, height: size.height), display: true)
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        timeout?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated {
                guard let self, self.panel.isVisible else { return }
                let t = self.onTimeout
                self.close()
                t?() // doing nothing keeps the capture, as before
            }
        }
        timeout = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 12, execute: work)
    }

    func close() {
        timeout?.cancel()
        onTimeout = nil
        panel.orderOut(nil)
    }
}

struct FlowActionBar: View {
    let taskTitle: String?
    let sessionOn: Bool
    let lens: () -> Void
    let threads: (FlowController.ThreadsMode) -> Void
    let simulate: () -> Void
    let add: () -> Void
    let ask: () -> Void
    let dismiss: () -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                key("L", "Lens", "Understand", "eye", action: lens)
                key("T", "Threads", "Remember", "point.3.connected.trianglepath.dotted", action: { threads(.remember) })
                    .contextMenu {
                        Button("Remember this") { threads(.remember) }
                        Button("Save as a decision") { threads(.decision) }
                        Button("Save as something I tried") { threads(.attempt) }
                        Button("Start a new task with this") { threads(.newTask) }
                        Button("Inspect task memory") { threads(.inspect) }
                    }
                key("S", "Simulate", "Explore", "arrow.triangle.branch", action: simulate)
                Divider().frame(height: 34)
                VStack(spacing: 4) {
                    Button(action: add) { Image(systemName: "tray.and.arrow.down").frame(width: 26, height: 14) }
                        .buttonStyle(.dsPlain).help("Add to a pack (A)").accessibilityLabel("Add to a pack")
                        .keyboardShortcut("a", modifiers: [])
                    Button(action: ask) { Image(systemName: "questionmark.bubble").frame(width: 26, height: 14) }
                        .buttonStyle(.dsPlain).help("Ask your packs (Q)").accessibilityLabel("Ask your packs")
                        .keyboardShortcut("q", modifiers: [])
                }
            }
            Text(taskTitle.map { "Task: \($0)" } ?? (sessionOn ? "No task yet · Threads starts one" : "Session off · Lens and Simulate still work"))
                .font(.dsMeta).foregroundStyle(DS.text3).lineLimit(1).padding(.horizontal, 4)
        }
        .padding(10)
        .glassSurface(RoundedRectangle(cornerRadius: 20, style: .continuous))
        .padding(1)
        .scaleEffect(shown || reduceMotion ? 1 : 0.96)
        .opacity(shown ? 1 : 0)
        .onAppear { withAnimation(DS.spring(reduceMotion)) { shown = true } }
        .onExitCommand(perform: dismiss)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Shapr actions for what you circled")
    }

    private func key(_ letter: String, _ title: String, _ verb: String, _ symbol: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            VStack(spacing: 3) {
                HStack(spacing: 4) {
                    Image(systemName: symbol).font(.system(size: 13, weight: .medium))
                    Text(title).font(.system(size: 12.5, weight: .semibold))
                }
                HStack(spacing: 3) {
                    Keycap(keys: letter)
                    Text(verb).font(.dsMeta).foregroundStyle(DS.text2)
                }
            }
            .frame(width: 78, height: 44)
        }
        .buttonStyle(.dsSecondary)
        .keyboardShortcut(KeyEquivalent(Character(letter.lowercased())), modifiers: [])
        .accessibilityLabel("\(title): \(verb)")
        .accessibilityHint("Shortcut \(letter)")
    }
}

// MARK: - Lens / Threads / Simulate panel

@MainActor
final class FlowPanelModel: ObservableObject {
    enum Mode { case lens, threads, simulate }
    @Published var mode: Mode = .lens
    // Lens
    @Published var selection = ""
    @Published var package: ContextPackage?
    @Published var answer = ""
    @Published var answerSource = ""
    @Published var working = false
    @Published var problem: String?
    @Published var consent = false
    @Published var sendImage = false
    var png: Data?
    var image: NSImage?
    var save: (() -> Void)?
    var evidence: EvidenceRef?
    // Threads
    @Published var taskID: UUID?
    // Simulate
    @Published var pathA = ""
    @Published var pathB = ""
    @Published var comparison: ScenarioComparison?
    @Published var narrative = ""
}

@MainActor
final class FlowPanelController {
    private unowned let flow: FlowController
    let model = FlowPanelModel()
    private let panel = FloatingPanel(size: NSSize(width: 560, height: 560), level: .floating)
    private var task: Task<Void, Never>?

    init(flow: FlowController) {
        self.flow = flow
        panel.allowsKey = true
        panel.isMovable = true
        panel.isMovableByWindowBackground = true
        panel.contentView = NSHostingView(rootView: FlowPanelView(model: model, flowModel: flow.model, actions: self))
    }

    private func present() {
        let size = NSSize(width: 560, height: 580)
        if !panel.isVisible, let vf = NSScreen.underMouse?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.midY - size.height / 2 + 60, width: size.width, height: size.height), display: true)
        }
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    func close() {
        task?.cancel()
        panel.orderOut(nil)
    }

    // Lens
    func showLens(text: String, image: NSImage?, png: Data?, evidence: EvidenceRef, save: @escaping () -> Void) {
        task?.cancel()
        let m = model
        m.mode = .lens
        m.selection = text
        m.image = image
        m.png = png
        m.save = save
        m.evidence = evidence
        m.answer = ""
        m.problem = nil
        m.consent = false
        m.sendImage = false
        m.package = flow.engine.context(for: text, budget: 3500)
        present()
        explainLocally()
    }

    static let lensSystem = """
    You help someone understand what they selected on screen, using ONLY the numbered context from their own work.
    Write at most 150 words in three short parts: "What it is", "From your work" (cite items like [2]), and "Worth checking" (suggestions, clearly unverified).
    Never claim something was fixed, tried or decided unless a context item says so. Items tagged inferred or unverified are guesses: say so.
    """

    func explainLocally() {
        guard let pkg = model.package else { return }
        let prompt = pkg.rendered() + "\n\nExplain what the user selected."
        model.working = true
        task = Task { [weak self] in
            guard let self else { return }
            let local = await self.flow.localAnswer(system: Self.lensSystem, prompt: prompt)
            guard !Task.isCancelled else { return }
            self.model.working = false
            if let local {
                self.model.answer = local
                self.model.answerSource = "Written on this Mac by Apple Intelligence from the items below."
            } else {
                self.model.answer = Self.deterministic(pkg)
                self.model.answerSource = "On-device AI isn't available, so this is what your memory says — no AI involved."
            }
        }
    }

    /// No model: the facts, grouped, each with where it came from.
    static func deterministic(_ pkg: ContextPackage) -> String {
        let used = pkg.items.filter(\.included)
        guard !used.isEmpty else { return "Shapr has nothing saved that relates to this yet." }
        var out: [String] = []
        for (i, item) in used.enumerated() {
            let r = item.record
            var s = "[\(i + 1)] \(r.kind.heading): \(r.text)"
            if r.occurrences > 1 { s += " (seen \(r.occurrences) times)" }
            if !r.provenance.isFact { s += " — \(r.provenance.label), not confirmed" }
            out.append(s)
        }
        return out.joined(separator: "\n")
    }

    func askClaude() {
        guard var pkg = model.package else { return }
        pkg.items = pkg.items.filter(\.included)
        let images = model.sendImage ? [model.png].compactMap { $0 } : []
        guard let stream = flow.cloudStream(system: Self.lensSystem, prompt: pkg.rendered() + "\n\nExplain what the user selected.", images: images) else {
            model.problem = "Claude isn't allowed in Shapr Flow settings, or no API key is set."
            return
        }
        model.consent = false
        model.answer = ""
        model.answerSource = "From Claude (\(SorterSettings.model)), sent with your approval."
        model.working = true
        task = Task { [weak self] in
            do {
                for try await chunk in stream { self?.model.answer += chunk }
            } catch {
                self?.model.problem = error.localizedDescription
            }
            self?.model.working = false
        }
    }

    func toggle(_ id: UUID) {
        guard let i = model.package?.items.firstIndex(where: { $0.id == id }) else { return }
        model.package?.items[i].included.toggle()
    }

    func rememberAnswer() {
        guard !model.answer.isEmpty else { return }
        flow.engine.remember("Lens on “\(FlowText.clip(model.selection, 60))”: \(FlowText.clip(model.answer, 300))", kind: .note, evidence: model.evidence)
        model.answerSource = "Saved to the task as a note."
        flow.refresh()
    }

    func saveCapture() {
        model.save?()
        model.save = nil
    }

    // Threads
    func showThreads(taskID: UUID?) {
        model.mode = .threads
        model.taskID = taskID ?? flow.engine.activeTask?.id ?? flow.engine.kernel.tasks.max { $0.lastActivity < $1.lastActivity }?.id
        flow.refresh()
        present()
    }

    func edit(_ f: @escaping (MemoryKernel) -> Void) {
        flow.engine.edit(f)
        flow.refresh()
        objectWillChange()
    }

    private func objectWillChange() { model.objectWillChange.send() }

    func continueInAI() { if let id = model.taskID { flow.continueInAI(id) } }
    func deleteTask() {
        guard let id = model.taskID else { return }
        flow.deleteTask(id)
        model.taskID = flow.engine.kernel.tasks.first?.id
    }

    // Simulate
    func showSimulate(text: String, evidence: EvidenceRef) {
        task?.cancel()
        let m = model
        m.mode = .simulate
        m.selection = text
        m.evidence = evidence
        m.comparison = nil
        m.narrative = ""
        m.pathA = "Keep the current approach"
        m.pathB = "Change the approach"
        present()
        compare()
        m.working = true
        task = Task { [weak self] in
            guard let self else { return }
            let ctx = self.flow.engine.context(for: text, budget: 2000).rendered()
            let reply = await self.flow.localAnswer(system: """
                Suggest two genuinely different approaches to the selected item, based only on the context. \
                Reply with exactly two lines: "A: <approach in under 12 words>" and "B: <approach in under 12 words>".
                """, prompt: ctx)
            guard !Task.isCancelled else { return }
            self.model.working = false
            if let reply {
                for line in reply.split(separator: "\n") {
                    let l = line.trimmingCharacters(in: .whitespaces)
                    if l.hasPrefix("A:") { self.model.pathA = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                    if l.hasPrefix("B:") { self.model.pathB = String(l.dropFirst(2)).trimmingCharacters(in: .whitespaces) }
                }
                self.compare()
            }
        }
    }

    /// The comparison itself is deterministic: each path is linked to stored records by their words.
    func compare() {
        model.comparison = flow.engine.compare(selection: model.selection, paths: [model.pathA, model.pathB])
    }
}

struct FlowPanelView: View {
    @ObservedObject var model: FlowPanelModel
    @ObservedObject var flowModel: FlowModel
    let actions: FlowPanelController

    var body: some View {
        VStack(spacing: 0) {
            PanelHeader(title: title, subtitle: flowModel.summary.map { "Task: \($0.task.title)" } ?? "No current task",
                        symbol: symbol) {
                Picker("", selection: $model.mode) {
                    Text("Lens").tag(FlowPanelModel.Mode.lens)
                    Text("Threads").tag(FlowPanelModel.Mode.threads)
                    Text("Simulate").tag(FlowPanelModel.Mode.simulate)
                }
                .pickerStyle(.segmented).labelsHidden().frame(width: 220)
                .accessibilityLabel("Mode")
                IconButton(symbol: "xmark", help: "Close", size: 24) { actions.close() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.m) {
                    switch model.mode {
                    case .lens: LensSection(model: model, flowModel: flowModel, actions: actions)
                    case .threads: ThreadsSection(model: model, flowModel: flowModel, actions: actions)
                    case .simulate: SimulateSection(model: model, actions: actions)
                    }
                }
                .padding(DS.S.l)
            }
        }
        .dsPanel(width: 560)
        .frame(height: 580)
    }

    private var title: String {
        switch model.mode {
        case .lens: return "Lens · Understand"
        case .threads: return "Threads · Task memory"
        case .simulate: return "Simulate · Explore"
        }
    }

    private var symbol: String {
        switch model.mode {
        case .lens: return "eye"
        case .threads: return "point.3.connected.trianglepath.dotted"
        case .simulate: return "arrow.triangle.branch"
        }
    }
}

private struct Quote: View {
    let text: String
    var body: some View {
        Text(FlowText.clip(text, 400))
            .font(.dsCallout).foregroundStyle(DS.text)
            .padding(10).frame(maxWidth: .infinity, alignment: .leading)
            .dsSurface(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
            .textSelection(.enabled)
            .accessibilityLabel("What you circled: \(text)")
    }
}

struct LensSection: View {
    @ObservedObject var model: FlowPanelModel
    @ObservedObject var flowModel: FlowModel
    let actions: FlowPanelController

    var body: some View {
        SectionLabel(title: "What you circled", symbol: "lasso")
        Quote(text: model.selection.isEmpty ? "(no text found in the circle)" : model.selection)

        SectionLabel(title: "Answer", symbol: "sparkles")
        if model.working && model.answer.isEmpty { StatusLine(tone: .working, text: "Thinking on this Mac…") }
        if !model.answer.isEmpty {
            Text(model.answer).font(.dsBody).foregroundStyle(DS.text).textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Text(model.answerSource).font(.dsMeta).foregroundStyle(DS.text3)
        }
        if let p = model.problem { StatusLine(tone: .error, text: p) }

        if let pkg = model.package {
            SectionLabel(title: "Context from your work (\(pkg.items.filter(\.included).count) of \(pkg.items.count) used)", symbol: "tray.full")
            if pkg.items.isEmpty {
                Text("Nothing in your working memory relates to this yet.").font(.dsCallout).foregroundStyle(DS.text2)
            }
            ForEach(pkg.items) { item in
                HStack(alignment: .top, spacing: 8) {
                    Toggle("", isOn: Binding(get: { item.included }, set: { _ in actions.toggle(item.id) }))
                        .toggleStyle(.checkbox).labelsHidden()
                        .accessibilityLabel("Use: \(item.record.text)")
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Text(item.record.kind.heading).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
                            ProvenanceChip(provenance: item.record.provenance)
                            Text(item.reason).font(.dsMeta).foregroundStyle(DS.text3)
                        }
                        Text(item.record.text).font(.dsCallout).foregroundStyle(item.included ? DS.text : DS.text3)
                            .fixedSize(horizontal: false, vertical: true)
                        if let ev = item.record.evidence.last { EvidenceLine(ref: ev) }
                    }
                }
            }
        }

        if model.consent, let pkg = model.package {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel(title: "Send to Claude?", symbol: "icloud.and.arrow.up")
                Text("Provider: Anthropic · \(SorterSettings.model). Exactly this text is sent, nothing else from your session:")
                    .font(.dsCallout).foregroundStyle(DS.text2)
                ScrollView {
                    Text({ var p = pkg; p.items = p.items.filter(\.included); return p.rendered() }())
                        .font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 140).padding(6)
                .dsSurface(RoundedRectangle(cornerRadius: DS.R.control, style: .continuous))
                Toggle("Also send the screenshot of what you circled", isOn: $model.sendImage).font(.dsCallout)
                HStack {
                    Button("Cancel") { model.consent = false }.buttonStyle(.dsSecondary)
                    Spacer()
                    Button("Send to Claude") { actions.askClaude() }.buttonStyle(.dsPrimary)
                }
            }
            .dsCard()
        }

        HStack(spacing: 8) {
            Button("Save capture to pack") { actions.saveCapture() }.buttonStyle(.dsSecondary)
                .disabled(model.save == nil)
            Button("Remember this answer") { actions.rememberAnswer() }.buttonStyle(.dsSecondary)
                .disabled(model.answer.isEmpty || model.working)
            Spacer()
            if flowModel.settings.processing == .askBeforeCloud && flowModel.claudeReady {
                Button("Ask Claude…") { model.consent = true }.buttonStyle(.dsSecondary)
            } else {
                Label("AI on this Mac only", systemImage: "lock.fill").font(.dsMeta).foregroundStyle(DS.text3)
            }
        }
        .padding(.top, 4)
    }
}

struct ThreadsSection: View {
    @ObservedObject var model: FlowPanelModel
    @ObservedObject var flowModel: FlowModel
    let actions: FlowPanelController
    @State private var title = ""
    @State private var goal = ""

    private var task: TaskState? { flowModel.tasks.first { $0.id == model.taskID } }

    var body: some View {
        if flowModel.tasks.isEmpty {
            Text("No tasks yet. Start a session and work, or circle something and press T.").font(.dsCallout).foregroundStyle(DS.text2)
        } else {
            Picker("Task", selection: $model.taskID) {
                ForEach(flowModel.tasks) { t in Text(t.title).tag(Optional(t.id)) }
            }
            .pickerStyle(.menu)
        }
        if let task {
            HStack(spacing: 6) {
                TextField("Task name", text: $title, onCommit: { actions.edit { $0.rename(taskID: task.id, to: title) } })
                    .textFieldStyle(.roundedBorder).font(.dsHeadline)
                ProvenanceChip(provenance: task.titleProvenance)
            }
            .onAppear { title = task.title }
            .onChange(of: task.id) { title = task.title }
            HStack(spacing: 6) {
                TextField("Goal (in your words)", text: $goal, onCommit: {
                    actions.edit { $0.setGoal(goal, taskID: task.id) }
                    goal = ""
                })
                .textFieldStyle(.roundedBorder).font(.dsCallout)
            }
            let summary = TaskSummary.build(task: task, records: actions.recordsFor(task.id))
            ForEach(summary.sections) { section in
                SectionLabel(title: section.heading)
                ForEach(section.records) { r in RecordRow(record: r, actions: actions) }
            }
            if !task.sources.isEmpty {
                SectionLabel(title: "Sources", symbol: "link")
                ForEach(task.sources, id: \.self) { s in
                    HStack(spacing: 6) {
                        Text(FlowText.clip(s.title, 70)).font(.dsCallout).foregroundStyle(DS.text)
                        Spacer()
                        Text(s.appName).font(.dsMeta).foregroundStyle(DS.text3)
                        if let l = s.location, let u = URL(string: l), l.hasPrefix("http") {
                            IconButton(symbol: "arrow.up.right.square", help: "Open", size: 20) { NSWorkspace.shared.open(u) }
                        }
                    }
                }
            }
            HStack {
                Button("Delete task", role: .destructive) { actions.deleteTask() }.buttonStyle(.dsSecondary)
                Spacer()
                Button("Continue in an AI tool…") { actions.continueInAI() }.buttonStyle(.dsPrimary)
            }
            .padding(.top, 6)
        }
    }
}

extension FlowPanelController {
    func recordsFor(_ id: UUID) -> [MemoryRecord] {
        let rs = flow.engine.kernel.records(for: id)
        if !rs.isEmpty { return rs }
        return flow.engine.kernel.episodes.last { $0.taskID == id }?.records ?? []
    }
}

struct RecordRow: View {
    let record: MemoryRecord
    let actions: FlowPanelController
    @State private var open = false

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(alignment: .top, spacing: 6) {
                if record.pinned { Image(systemName: "pin.fill").font(.system(size: 9)).foregroundStyle(DS.text3).accessibilityLabel("Pinned") }
                Text(record.text).font(.dsCallout).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 4)
                if record.occurrences > 1 { Text("×\(record.occurrences)").font(.dsMeta).foregroundStyle(DS.text3) }
                ProvenanceChip(provenance: record.provenance)
                Menu {
                    if record.provenance != .userConfirmed { Button("That's right (confirm)") { actions.edit { $0.confirm(recordID: record.id) } } }
                    Button(record.pinned ? "Unpin" : "Pin (never forget)") { actions.edit { $0.pin(recordID: record.id, !record.pinned) } }
                    Button("Mark as outdated") { actions.edit { $0.supersede(recordID: record.id) } }
                    Divider()
                    Button("Delete", role: .destructive) { actions.edit { $0.deleteRecord(record.id) } }
                } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize()
                    .accessibilityLabel("Actions for this memory")
            }
            if !record.evidence.isEmpty {
                Button(open ? "Hide sources" : "\(record.evidence.count) source\(record.evidence.count == 1 ? "" : "s")") { open.toggle() }
                    .buttonStyle(.link).font(.dsMeta)
                if open { ForEach(record.evidence) { EvidenceLine(ref: $0) } }
            }
        }
        .padding(.vertical, 2)
    }
}

struct SimulateSection: View {
    @ObservedObject var model: FlowPanelModel
    let actions: FlowPanelController

    var body: some View {
        SectionLabel(title: "Starting from", symbol: "lasso")
        Quote(text: model.selection)
        HStack(alignment: .top, spacing: 10) {
            pathField("Path A", $model.pathA)
            pathField("Path B", $model.pathB)
        }
        HStack {
            if model.working { StatusLine(tone: .working, text: "Suggesting two paths on this Mac…") }
            Spacer()
            Button("Compare") { actions.compare() }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
        }
        Text(ScenarioComparison.disclaimer).font(.dsMeta).foregroundStyle(DS.text3)
        if let c = model.comparison {
            HStack(alignment: .top, spacing: 10) {
                ForEach(Array(c.paths.enumerated()), id: \.offset) { _, p in PathCard(path: p) }
            }
            if !c.openForBoth.isEmpty {
                SectionLabel(title: "Open either way", symbol: "questionmark.circle")
                ForEach(c.openForBoth) { l in Text("• " + l.record.text).font(.dsCallout).foregroundStyle(DS.text2) }
            }
        }
    }

    private func pathField(_ label: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
            TextField(label, text: text, axis: .vertical).textFieldStyle(.roundedBorder).lineLimit(2...3)
                .onSubmit { actions.compare() }
        }
    }
}

struct PathCard: View {
    let path: ScenarioPath
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(path.title).font(.dsHeadline).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            group("In line with", "checkmark.circle", path.consistentWith, DS.success)
            group("Possible tension — check", "exclamationmark.triangle", path.possibleTensions, DS.warning)
            group("Tried before", "arrow.counterclockwise", path.triedBefore, DS.text2)
            group("Questions", "questionmark.circle", path.questions, DS.text2)
            ForEach(path.assumptions, id: \.self) { a in
                Label(a, systemImage: "info.circle").font(.dsMeta).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .dsCard()
    }

    @ViewBuilder private func group(_ title: String, _ symbol: String, _ links: [ScenarioLink], _ tint: Color) -> some View {
        if !links.isEmpty {
            Label(title, systemImage: symbol).font(.system(size: 11, weight: .semibold)).foregroundStyle(tint)
            ForEach(links) { l in
                VStack(alignment: .leading, spacing: 1) {
                    Text(l.record.text).font(.dsCallout).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 4) { Text(l.why); ProvenanceChip(provenance: l.record.provenance) }.font(.dsMeta).foregroundStyle(DS.text3)
                }
            }
        }
    }
}

// MARK: - Menu-bar popover

struct FlowHomeView: View {
    @ObservedObject var model: FlowModel
    let flow: FlowController

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("SHAPR").font(.system(size: 12, weight: .bold)).tracking(2).foregroundStyle(DS.text)
                Spacer()
                statusBadge
            }

            switch model.state {
            case .off, .ending:
                if let r = model.resume { resumeCard(r) }
                Button { flow.startSession() } label: {
                    Label("Start working session", systemImage: "play.fill").frame(maxWidth: .infinity)
                }
                .buttonStyle(.dsPrimary).controlSize(.large).keyboardShortcut(.defaultAction)
                Text("Shapr only looks at apps you allow, and asks first.").font(.dsMeta).foregroundStyle(DS.text3)
            case .active, .paused:
                HStack(spacing: 8) {
                    if model.state == .active {
                        Button { flow.pause() } label: { Label("Pause", systemImage: "pause.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.dsSecondary).keyboardShortcut("p", modifiers: [])
                    } else {
                        Button { flow.resumeSession() } label: { Label("Resume", systemImage: "play.fill").frame(maxWidth: .infinity) }
                            .buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                    }
                    Button { flow.endSession() } label: { Label("End", systemImage: "stop.fill").frame(maxWidth: .infinity) }
                        .buttonStyle(.dsSecondary)
                }
                currentTask
            }

            if let q = model.question {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Is “\(FlowText.clip(q.about, 50))” part of \(q.taskTitle)?").font(.dsCallout).foregroundStyle(DS.text)
                    HStack {
                        Button("Yes") { flow.engine.answer(.yes) }.buttonStyle(.dsPrimary)
                        Button("Separate task") { flow.engine.answer(.separateTask) }.buttonStyle(.dsSecondary)
                        Button("Ignore") { flow.engine.answer(.ignore) }.buttonStyle(.dsSecondary)
                    }
                }
                .dsCard(padding: 10)
            }

            if !model.apps.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    SectionLabel(title: "Apps", symbol: "macwindow.on.rectangle")
                    ForEach(model.apps.prefix(6), id: \.bundleID) { p in AppRow(permission: p, flow: flow) }
                }
            }

            HStack(spacing: 6) {
                Image(systemName: model.settings.processing == .onThisMac ? "lock.fill" : "icloud")
                Text("Processing: \(model.settings.processing.label)")
            }
            .font(.dsMeta).foregroundStyle(DS.text2)

            HStack(spacing: 4) {
                Text("Circle anything (\(DoubleTapDetector.Key.current.symbol)):")
                Text("L").bold(); Text("Lens ·"); Text("T").bold(); Text("Threads ·"); Text("S").bold(); Text("Simulate")
            }
            .font(.dsMeta).foregroundStyle(DS.text3)
            .accessibilityElement(children: .combine)

            Divider()
            HStack {
                Button("Privacy & memory…") { flow.showPrivacy() }.buttonStyle(.dsPlain)
                Spacer()
                Button { flow.closePopover(); flow.showMenu() } label: { Label("More", systemImage: "ellipsis.circle") }
                    .buttonStyle(.dsPlain).help("Packs, shortcuts, library and settings")
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    private var statusBadge: some View {
        let (text, color): (String, Color) = {
            switch model.state {
            case .active: return ("Session active", DS.success)
            case .paused: return ("Paused", DS.warning)
            case .ending: return ("Ending…", DS.text3)
            case .off: return ("Session off", DS.text3)
            }
        }()
        return HStack(spacing: 5) {
            Circle().fill(color).frame(width: 7, height: 7).accessibilityHidden(true)
            Text(text).font(.dsMeta).foregroundStyle(DS.text2)
        }
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder private var currentTask: some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Current task", symbol: "scope")
            if let s = model.summary {
                HStack(spacing: 6) {
                    Text(s.task.title).font(.dsHeadline).foregroundStyle(DS.text).lineLimit(2)
                    if !s.task.titleProvenance.isFact { ProvenanceChip(provenance: s.task.titleProvenance) }
                }
                ForEach(s.resume.dropFirst().prefix(3)) { line in
                    Text(line.text).font(.dsCallout).foregroundStyle(DS.text2).lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                HStack {
                    Button("Review") { flow.reviewTask(s.task.id) }.buttonStyle(.dsSecondary)
                    Button("Continue in AI…") { flow.continueInAI(s.task.id) }.buttonStyle(.dsSecondary)
                }
            } else {
                Text(model.state == .paused ? "Paused. Nothing new is observed." : "Work as usual. A task appears when Shapr sees one in an app you allowed.")
                    .font(.dsCallout).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func resumeCard(_ r: TaskSummary) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            SectionLabel(title: "Continue where you left off", symbol: "arrow.clockwise")
            ForEach(r.resume.prefix(4)) { line in
                Text(line.text).font(.dsCallout).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
            }
            HStack {
                Button("Continue") { flow.startSession(); flow.continueTask(r.task.id) }.buttonStyle(.dsPrimary)
                Button("Review context") { flow.reviewTask(r.task.id) }.buttonStyle(.dsSecondary)
            }
        }
        .dsCard(padding: 10)
    }
}

struct AppRow: View {
    let permission: AppPermission
    let flow: FlowController

    var body: some View {
        HStack(spacing: 8) {
            if let icon = appIcon(permission.bundleID) { Image(nsImage: icon).resizable().frame(width: 18, height: 18).accessibilityHidden(true) }
            Text(permission.displayName).font(.dsCallout).foregroundStyle(DS.text).lineLimit(1)
            Spacer()
            Menu {
                ForEach([AppAccess.session, .always, .denied], id: \.self) { a in
                    Button(a == .denied ? "Block" : a.label) { flow.setAccess(a, bundleID: permission.bundleID, name: permission.displayName) }
                }
                Button("Ask me next time") { flow.setAccess(nil, bundleID: permission.bundleID, name: permission.displayName) }
            } label: {
                Text(permission.access == .denied ? "Blocked" : permission.access.label)
                    .font(.dsMeta).foregroundStyle(permission.access == .denied ? DS.danger : DS.text2)
            }
            .menuStyle(.borderlessButton).fixedSize()
            .accessibilityLabel("\(permission.displayName): \(permission.access.label). Change")
        }
    }
}

// MARK: - Privacy & memory window

struct FlowPrivacyView: View {
    @ObservedObject var model: FlowModel
    let flow: FlowController
    @State private var confirmAll = false

    var body: some View {
        Form {
            Section("Observation") {
                LabeledContent("Status") {
                    Text(model.state == .active ? "Observing allowed apps" : model.state == .paused ? "Paused" : "Off")
                }
                Text("Shapr reads only apps you allow, only while a session is on: window titles, page addresses and error lines. It never records keystrokes, watches the clipboard, or takes screenshots on its own. Password managers and sign-in windows are never read.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
                if let p = model.loadProblem { StatusLine(tone: .warning, text: p) }
            }

            Section("Apps") {
                if model.apps.isEmpty { Text("No apps yet. Shapr asks the first time you use one during a session.").foregroundStyle(DS.text2) }
                ForEach(model.apps, id: \.bundleID) { p in
                    HStack {
                        AppRow(permission: p, flow: flow)
                        Button("Delete its data") { _ = flow.engine.deleteData(fromApp: p.bundleID); flow.refresh() }
                            .buttonStyle(.dsPlain).help("Removes everything Shapr Flow kept from \(p.displayName), and what was derived from it")
                    }
                }
            }

            Section("Processing") {
                Picker("AI for Flow", selection: Binding(get: { model.settings.processing }, set: { v in flow.updateSettings { $0.processing = v } })) {
                    ForEach(ProcessingMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(model.settings.processing == .onThisMac
                     ? "Flow memory is built without any AI. Lens and Simulate use Apple Intelligence on this Mac when available, and nothing from your session is sent to an AI service. (Other Shapr features you turn on, like sharing or live sources, use the network as before.)"
                     : "Lens can use Claude, but only when you press Ask Claude, after you've seen exactly what will be sent.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
                if !model.localModel { StatusLine(tone: .info, text: "Apple Intelligence isn't available on this Mac; Lens shows your memory without an AI summary.") }
                Picker("Assistance", selection: Binding(get: { model.settings.assistance }, set: { v in flow.updateSettings { $0.assistance = v } })) {
                    ForEach(AssistanceMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                Text(model.settings.assistance.detail).font(.dsMeta).foregroundStyle(DS.text2)
                Toggle("Let AI tools I've connected (MCP) read the current task's summary",
                       isOn: Binding(get: { model.settings.shareTaskWithAITools }, set: { v in flow.updateSettings { $0.shareTaskWithAITools = v } }))
            }

            Section("Memory") {
                LabeledContent("Temporary (in RAM, expires in 20 min)", value: "\(model.immediateCount) observations")
                LabeledContent("Working memory", value: "\(model.recordCount) items in \(model.tasks.count) tasks")
                LabeledContent("Stored on disk", value: ByteCountFormatter.string(fromByteCount: Int64(model.storedBytes), countStyle: .file))
                Picker("Keep finished sessions for", selection: Binding(get: { model.settings.episodeRetentionDays }, set: { v in flow.updateSettings { $0.episodeRetentionDays = v } })) {
                    Text("7 days").tag(7); Text("30 days").tag(30); Text("90 days").tag(90)
                }
                Text("Pinned items and your packs are never deleted automatically.").font(.dsMeta).foregroundStyle(DS.text2)
                ForEach(model.tasks) { t in
                    HStack {
                        Text(t.title).lineLimit(1)
                        Spacer()
                        Text(t.status.rawValue).font(.dsMeta).foregroundStyle(DS.text3)
                        Button("Delete") { flow.deleteTask(t.id) }.buttonStyle(.dsPlain)
                    }
                }
                HStack {
                    Button("Clear temporary memory") { flow.engine.clearTemporary(); flow.refresh() }
                    if let sid = flow.engine.session.sessionID {
                        Button("Delete this session's data") { _ = flow.engine.deleteSession(sid); flow.refresh() }
                    }
                    Spacer()
                    Button("Delete all Flow memory…", role: .destructive) { confirmAll = true }
                }
            }

            Section("Resource use") {
                Text(model.metrics.isEmpty ? "Nothing measured yet." : model.metrics)
                    .font(.system(size: 11, design: .monospaced)).foregroundStyle(DS.text2).textSelection(.enabled)
                HStack {
                    Button("Refresh") { flow.refreshMetrics() }
                    Spacer()
                    Button("Play demo activity") { flow.playDemo() }
                        .help("Feeds a scripted coding session (VS Code + Safari) through the real engine, for demos")
                }
            }
        }
        .formStyle(.grouped)
        .frame(minWidth: 520, minHeight: 600)
        .confirmationDialog("Delete everything Shapr Flow has collected?", isPresented: $confirmAll) {
            Button("Delete all Flow memory", role: .destructive) { flow.deleteAll() }
        } message: {
            Text("Tasks, working memory, finished sessions and the checkpoints Flow wrote. Your packs and captures stay.")
        }
    }
}
