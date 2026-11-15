import AppKit
import SwiftUI

// MARK: - Model

@MainActor
final class UseModel: ObservableObject {
    enum Tab: String { case brief, answer }
    enum AnswerPhase: Equatable { case idle, writing, done(String), failed(String) }
    enum Destination: String, CaseIterable, Identifiable {
        case here, claude, chatgpt, gemini, copy
        var id: String { rawValue }
        var title: String {
            switch self {
            case .here: return "This text box"
            case .claude: return "Claude"
            case .chatgpt: return "ChatGPT"
            case .gemini: return "Gemini"
            case .copy: return "Copy only"
            }
        }
    }

    @Published var input = ""
    @Published var kind: PackAssist.Kind = .general
    @Published var packID: UUID?
    @Published var excerpts: [PackAssist.Excerpt] = []
    @Published var finding = false
    @Published var includeProgress = true
    @Published var brief = ""
    @Published var briefEdited = false
    @Published var answer = ""
    @Published var answerPhase: AnswerPhase = .idle
    @Published var tab: Tab = .brief
    @Published var target = DropTarget(app: nil, appName: "", destination: .generic, label: "")
    @Published var canInsertHere = false
    @Published var destination: Destination = .copy
    @Published var picked: RouteSuggestion?
    @Published var fallbackID: UUID?
    var signals = RouteSignals()

    var output: String { tab == .answer && !answer.isEmpty ? answer : brief }
}

// MARK: - View

/// "Use 📘 MAT223 with this": what you pointed at, the parts of the pack that matter for it (each can be
/// left out), and what Shapr prepared: a brief for any AI, or an answer. Nothing is inserted until you say so.
struct UseView: View {
    @ObservedObject var model: UseModel
    @ObservedObject var store: PackStore
    var onRebuild: () -> Void = {}
    var onRefind: () -> Void = {}
    var onPickPack: (UUID) -> Void = { _ in }
    var onAnswer: () -> Void = {}
    var onSend: () -> Void = {}
    var onCopy: () -> Void = {}
    var onClose: () -> Void = {}
    @State private var expanded: Set<String> = []
    @State private var editingInput = false
    @State private var showSources = false

    private var pack: Pack? { store.pack(model.packID) }
    private var checkpoint: Checkpoint? { model.packID.flatMap(store.latestCheckpoint(for:)) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Use \(pack?.label ?? "a pack") with this",
                        subtitle: model.target.label.isEmpty ? nil : "From \(model.target.label)",
                        appIcon: model.target.app?.icon, symbol: "sparkle.magnifyingglass") { packMenu }
            if let p = model.picked, let chosen = pack {
                PickedLine(pack: chosen, reason: p.reason, fallback: store.pack(model.fallbackID)) {
                    if let f = model.fallbackID { onPickPack(f) }
                }
            }
            Rectangle().fill(DS.line).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.l) {
                    pointedAt
                    sources
                    result
                }
                .padding(DS.S.l)
            }
            .frame(maxHeight: 560)

            PanelFooter {
                destinationMenu
            } actions: {
                HintButton(title: "Cancel", keys: "esc", action: onClose).keyboardShortcut(.cancelAction)
                HintButton(title: "Copy", keys: "⇧⌘C", action: onCopy)
                    .keyboardShortcut("c", modifiers: [.command, .shift])
                    .disabled(model.output.isEmpty)
                HintButton(title: sendTitle, keys: "⌘↩", primary: true, action: onSend)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.output.isEmpty || (model.tab == .answer && model.answerPhase == .writing))
            }
        }
        .dsPanel(width: 620)
    }

    private var sendTitle: String {
        switch model.destination {
        case .here: return "Insert"
        case .copy: return "Copy and close"
        default: return "Open \(model.destination.title)"
        }
    }

    // What you pointed at, and what kind of help you want with it.
    private var pointedAt: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectionLabel(title: "What you're looking at", symbol: "scope")
                Spacer()
                // One quiet menu instead of four buttons: Shapr picks the kind; change it if it guessed wrong.
                Menu {
                    ForEach(PackAssist.Kind.allCases) { k in
                        Button { model.kind = k; onRebuild() } label: {
                            if model.kind == k { Label(k.title, systemImage: "checkmark") } else { Label(k.title, systemImage: k.symbol) }
                        }
                        .help(help(for: k))
                    }
                } label: {
                    HStack(spacing: 4) {
                        Image(systemName: model.kind.symbol).font(.system(size: 10.5, weight: .semibold))
                        Text(model.kind.title).font(.system(size: 12, weight: .medium))
                        Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.text3)
                    }
                    .foregroundStyle(DS.text)
                    .padding(.horizontal, 9).padding(.vertical, 3.5)
                    .background(Capsule().fill(DS.well))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
            }
            if editingInput || model.input.isEmpty {
                TextField(model.input.isEmpty ? "Ask \(pack?.name ?? "your pack") something…" : "", text: $model.input, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.dsBody)
                    .lineLimit(1...6)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.well))
                    .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.accent.opacity(0.6), lineWidth: 1))
                    .onSubmit { editingInput = false; onRefind() }
            } else {
                Text(model.input)
                    .font(model.kind == .debug ? .system(size: 12, design: .monospaced) : .dsBody)
                    .foregroundStyle(DS.text)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(8)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.well))
                    .overlay(alignment: .topTrailing) {
                        IconButton(symbol: "pencil", help: "Edit", size: 22) { editingInput = true }.padding(4)
                    }
            }
        }
    }

    private func help(for k: PackAssist.Kind) -> String {
        switch k {
        case .question: return "Explain or answer it, citing your material"
        case .reply: return "Draft a reply consistent with what's been decided"
        case .debug: return "A debugging brief with relevant code, constraints and what you already tried"
        case .general: return "Just gather the relevant material"
        }
    }

    private var sources: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Button { showSources.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showSources ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .bold))
                        Text(model.finding ? "Looking through \(pack?.name ?? "the pack")…"
                                           : "Using \(model.excerpts.filter(\.include).count) note\(model.excerpts.filter(\.include).count == 1 ? "" : "s") from \(pack?.name ?? "your pack")")
                            .font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.text2)
                }
                .buttonStyle(.plain)
                .disabled(model.excerpts.isEmpty)
                if model.finding { ProgressView().controlSize(.mini) }
                Spacer()
                if checkpoint != nil {
                    Toggle("Include saved progress", isOn: $model.includeProgress)
                        .toggleStyle(.checkbox).font(.dsMeta)
                        .onChange(of: model.includeProgress) { _, _ in onRebuild() }
                }
            }
            if !model.finding && model.excerpts.isEmpty {
                StatusLine(tone: .info, text: "Nothing in \(pack?.name ?? "this pack") matches this yet. What you're looking at is still in the brief.")
            }
            if showSources { VStack(spacing: 0) {
                ForEach(Array($model.excerpts.enumerated()), id: \.element.id) { i, $e in
                    if i > 0 { Rectangle().fill(DS.line).frame(height: 0.5) }
                    HStack(alignment: .top, spacing: 8) {
                        Toggle("", isOn: $e.include).toggleStyle(.checkbox).labelsHidden()
                            .onChange(of: e.include) { _, _ in onRebuild() }
                            .accessibilityLabel("Use \(e.title)")
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text("[\(i + 1)]").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text3)
                                Text(e.title).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(1)
                                Text(e.source).font(.dsMeta).foregroundStyle(DS.text3).lineLimit(1)
                            }
                            Text(e.text)
                                .font(e.isCode ? .system(size: 11.5, design: .monospaced) : .dsCallout)
                                .foregroundStyle(DS.text2)
                                .lineLimit(expanded.contains(e.id) ? nil : 2)
                                .textSelection(.enabled)
                        }
                        Spacer(minLength: 0)
                        IconButton(symbol: expanded.contains(e.id) ? "chevron.up" : "chevron.down",
                                   help: expanded.contains(e.id) ? "Show less" : "Show all", size: 20) {
                            if expanded.contains(e.id) { expanded.remove(e.id) } else { expanded.insert(e.id) }
                        }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 8)
                    .opacity(e.include ? 1 : 0.55)
                }
            }
            .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(DS.card)) }
        }
    }

    private var result: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 2) {
                Button("For your AI") { model.tab = .brief }.buttonStyle(KindStyle(on: model.tab == .brief))
                Button("Shapr's answer") {
                    model.tab = .answer
                    if model.answerPhase == .idle { onAnswer() }
                }
                .buttonStyle(KindStyle(on: model.tab == .answer))
                Spacer()
                if model.tab == .brief, model.briefEdited {
                    Button("Rebuild") { model.briefEdited = false; onRebuild() }.buttonStyle(DSButtonStyle(kind: .plain, small: true))
                }
            }
            switch model.tab {
            case .brief:
                editor($model.brief).onChange(of: model.brief) { _, _ in model.briefEdited = true }
                Text("Everything the AI needs, ready to paste: what you're looking at, the parts of your pack that matter, and your saved progress. No API key needed.")
                    .font(.dsMeta).foregroundStyle(DS.text3).fixedSize(horizontal: false, vertical: true)
            case .answer:
                switch model.answerPhase {
                case .idle:
                    Button("Write an answer from these sources", action: onAnswer).buttonStyle(.dsPrimary)
                case .writing where model.answer.isEmpty:
                    StatusLine(tone: .working, text: "Writing from \(model.excerpts.filter(\.include).count) source(s)…")
                case .failed(let msg):
                    StatusLine(tone: .error, text: msg)
                    Button("Try again", action: onAnswer).buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                default:
                    editor($model.answer)
                    if case .done(let engine) = model.answerPhase {
                        Text("Written by \(engine) from the sources above. Check it before you use it.").font(.dsMeta).foregroundStyle(DS.text3)
                    }
                }
            }
        }
    }

    private func editor(_ text: Binding<String>) -> some View {
        TextEditor(text: text)
            .font(.system(size: 12.5))
            .foregroundStyle(DS.text)
            .scrollContentBackground(.hidden)
            .padding(8)
            .frame(height: 190)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.well))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
    }

    private var packMenu: some View {
        Menu {
            ForEach(store.packs.filter { !$0.isStyle }) { p in Button(p.label + " · \(p.captures.count)") { onPickPack(p.id) } }
        } label: { PackChip(pack: pack, chevron: true) }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Use a different pack")
    }

    private var destinationMenu: some View {
        Menu {
            ForEach(UseModel.Destination.allCases.filter { $0 != .here || model.canInsertHere }) { d in
                Button(d == .here ? "This text box (\(model.target.label))" : d.title) { model.destination = d }
            }
        } label: {
            HStack(spacing: 4) {
                Text("Send to").foregroundStyle(DS.text3)
                Text(model.destination == .here ? model.target.label : model.destination.title).foregroundStyle(DS.text)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.text3)
            }
            .font(.dsCallout)
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }
}

private struct KindStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .labelStyle(.titleAndIcon)
            .foregroundStyle(on ? DS.text : DS.text2)
            .padding(.horizontal, 8).frame(minHeight: 22)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous).fill(on ? DS.panel : .clear)
                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
    }
}

// MARK: - Controller

/// ⌥⇧U, or from the ⌥⇧Space panel: use the equipped pack with what you're pointing at.
@MainActor
final class UseController {
    private let store: PackStore
    private let toast: ToastController
    let model = UseModel()
    private let panel = FloatingPanel(size: NSSize(width: 620, height: 600), level: .floating)
    private var findTask: Task<Void, Never>?
    private var answerTask: Task<Void, Never>?
    private var routeTask: Task<Void, Never>?

    init(store: PackStore, toast: ToastController) {
        self.store = store
        self.toast = toast
        panel.hasShadow = true
        panel.contentView = FirstMouseHostingView(rootView: UseView(
            model: model, store: store,
            onRebuild: { [weak self] in MainActor.assumeIsolated { self?.rebuild() } },
            onRefind: { [weak self] in MainActor.assumeIsolated { self?.find() } },
            onPickPack: { [weak self] id in MainActor.assumeIsolated { self?.pick(id) } },
            onAnswer: { [weak self] in MainActor.assumeIsolated { self?.writeAnswer() } },
            onSend: { [weak self] in MainActor.assumeIsolated { self?.send() } },
            onCopy: { [weak self] in MainActor.assumeIsolated { self?.copy() } },
            onClose: { [weak self] in MainActor.assumeIsolated { self?.close() } }
        ))
    }

    var isVisible: Bool { panel.isVisible }

    /// `input` is what you pointed at; nil reads the selection, then the text under the pointer.
    func open(input: String? = nil, context: PointerContext.Snapshot? = nil) {
        guard let pack = store.packToUse(nil).pack else {
            toast.show(ToastContent(icon: .symbol("tray"), title: "No packs yet",
                                    subtitle: "Select text in any app and press ⌥C to start one.", tint: DS.warning), duration: 4)
            return
        }
        let ctx = context ?? PointerContext.now()
        let text = input ?? ctx.selection ?? PointerContext.textUnderPointer() ?? ""
        model.target = DropDetector.detect()
        model.canInsertHere = ctx.inTextBox && ctx.selection == nil
        model.destination = model.canInsertHere ? .here : (model.target.destination == .aiChat ? .copy : .copy)
        model.packID = pack.id
        model.fallbackID = pack.id
        model.picked = nil
        model.signals = RouteSignals()
        model.input = String(text.prefix(8000))
        model.kind = PackAssist.kind(of: text, app: model.target.appName, host: model.target.url.flatMap { URL(string: $0)?.host })
        model.includeProgress = true
        model.briefEdited = false
        model.answer = ""
        model.answerPhase = .idle
        model.tab = .brief
        model.excerpts = []
        rebuild()
        show()
        find()
        // Then check who or what this is about; switch packs if another one clearly fits.
        let target = model.target
        routeTask?.cancel()
        routeTask = Task {
            let signals = await ScreenSignals.read(app: target.app, url: target.url)
            guard !Task.isCancelled else { return }
            model.signals = signals
            let choice = store.packToUse(store.suggestPack(for: signals))
            if let p = choice.pack, p.id != model.packID, choice.picked != nil {
                model.packID = p.id
                model.picked = choice.picked
                find()
            }
        }
    }

    private func pick(_ id: UUID) {
        if !model.signals.isEmpty { PackRouter.learn(model.signals, packID: id) }
        model.picked = nil
        model.packID = id
        find()
    }

    private func show() {
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        if let vf = NSScreen.underMouse?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - vf.height * 0.08,
                                  width: size.width, height: size.height), display: true)
        }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    /// Finds the excerpts off the main thread (embeddings take a moment on big packs).
    private func find() {
        guard let pack = store.pack(model.packID) else { return }
        let query = model.input
        let kind = model.kind
        findTask?.cancel()
        model.finding = true
        findTask = Task {
            let found = await Task.detached(priority: .userInitiated) {
                PackAssist.excerpts(for: query, in: pack, kind: kind)
            }.value
            guard !Task.isCancelled else { return }
            model.excerpts = found
            model.finding = false
            model.briefEdited = false
            model.answerPhase = .idle
            model.answer = ""
            rebuild()
        }
    }

    private func rebuild() {
        guard let pack = store.pack(model.packID), !model.briefEdited else { return }
        let cp = model.includeProgress ? store.latestCheckpoint(for: pack.id) : nil
        let style = model.kind == .reply ? store.pack(StyleSettings.defaultStyle(store)).map {
            StyleSamples.pick(from: $0, for: model.target.destination, limit: 2100)
        } ?? [] : []
        model.brief = PackAssist.brief(kind: model.kind, input: model.input, packName: pack.name, excerpts: model.excerpts,
                                       checkpoint: cp, style: style)
        model.briefEdited = false
    }

    private func writeAnswer() {
        answerTask?.cancel()
        model.answer = ""
        model.answerPhase = .writing
        model.tab = .answer
        let brief = model.brief
        answerTask = Task {
            do {
                let engine = try await PackAssist.answer(brief: brief) { [weak self] text in
                    MainActor.assumeIsolated { self?.model.answer = text }
                }
                guard !Task.isCancelled else { return }
                model.answerPhase = .done(engine)
            } catch {
                guard !Task.isCancelled else { return }
                model.answerPhase = .failed(error.localizedDescription)
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.output, forType: .string)
        close()
        toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "Copied", subtitle: "Paste it into any AI with ⌘V."), duration: 2)
    }

    private func send() {
        let text = model.output
        guard !text.isEmpty else { return }
        switch model.destination {
        case .copy:
            copy()
        case .here:
            let label = model.target.label
            close()
            TextInserter.paste(text, into: model.target.app) { [weak self] ok in
                if ok { UserDefaults.standard.set(true, forKey: Onboarding.droppedKey); return }
                self?.toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't get back to \(label)",
                                              subtitle: "It's on your clipboard. Click where it goes and press ⌘V.",
                                              tint: DS.warning), duration: 6)
            }
        case .claude, .chatgpt, .gemini:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
            let (bundle, web): (String, String) = switch model.destination {
            case .claude: ("com.anthropic.claudefordesktop", "https://claude.ai/new")
            case .chatgpt: ("com.openai.chat", "https://chatgpt.com/")
            default: ("", "https://gemini.google.com/app")
            }
            close()
            if !bundle.isEmpty, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundle) {
                NSWorkspace.shared.openApplication(at: app, configuration: NSWorkspace.OpenConfiguration())
            } else if let u = URL(string: web) {
                NSWorkspace.shared.open(u)
            }
            UserDefaults.standard.set(true, forKey: Onboarding.droppedKey)
            toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "Ready to paste in \(model.destination.title)",
                                    subtitle: "It's on your clipboard: click the message box and press ⌘V."), duration: 6)
        }
    }

    func close() {
        findTask?.cancel()
        answerTask?.cancel()
        routeTask?.cancel()
        panel.allowsKey = false
        panel.orderOut(nil)
    }
}
