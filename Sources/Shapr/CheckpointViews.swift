import AppKit
import SwiftUI

// MARK: - Save progress panel

@MainActor
final class CheckpointModel: ObservableObject {
    enum Phase: Equatable { case writing, ready, failed(String) }
    @Published var packID: UUID?
    @Published var cp = Checkpoint()
    @Published var previous: Checkpoint?
    @Published var phase: Phase = .writing
    /// The AI chat you were in when you pressed ⌥⇧P, read word for word.
    @Published var transcript: ChatTranscript?
    /// "ChatGPT" while that chat is being read.
    @Published var readingChat: String?
}

/// Save progress (Linear-style): task title first, then goal and next step, then what was decided,
/// tried and still open. Everything is editable before you save.
struct CheckpointView: View {
    @ObservedObject var model: CheckpointModel
    @ObservedObject var store: PackStore
    var onSave: () -> Void = {}
    var onRewrite: () -> Void = {}
    var onClose: () -> Void = {}

    private var pack: Pack? { store.pack(model.packID) }
    private var versions: [Checkpoint] { model.packID.map(store.checkpoints(for:)) ?? [] }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Save progress",
                        subtitle: pack.map { "Checkpoint v\(versions.count + 1) for \($0.label)" },
                        symbol: "flag") {
                if !versions.isEmpty {
                    Menu {
                        Section("Start from a saved version") {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                                Button("v\(versions.count - i) · " + v.created.formatted(date: .abbreviated, time: .shortened)
                                       + (v.title.map { " · \($0)" } ?? "")) {
                                    var copy = v
                                    copy.id = UUID()
                                    copy.tabs = model.cp.tabs
                                    model.cp = copy
                                }
                            }
                        }
                    } label: {
                        Label("History", systemImage: "clock.arrow.circlepath")
                    }
                    .menuStyle(.button)
                    .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                    .fixedSize()
                }
            }
            Rectangle().fill(DS.line).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: DS.S.l) {
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Name this task", text: Binding(get: { model.cp.title ?? "" }, set: { model.cp.title = $0 }))
                            .textFieldStyle(.plain)
                            .font(.system(size: 18, weight: .semibold))
                            .foregroundStyle(DS.text)
                        Text(provenance).font(.dsMeta).foregroundStyle(DS.text2)
                    }

                    KeyField(title: "Goal", symbol: "scope", text: $model.cp.goal,
                             placeholder: "What you're trying to achieve", emphasized: false)
                    KeyField(title: "Next step", symbol: "arrow.right.circle", text: $model.cp.nextStep,
                             placeholder: "The one thing to do next", emphasized: true)

                    Rectangle().fill(DS.line).frame(height: 0.5)

                    if !(model.cp.rules ?? []).isEmpty || model.transcript != nil {
                        PointsSection(title: "Your rules, word for word", symbol: "quote.opening",
                                      points: Binding(get: { model.cp.rules ?? [] }, set: { model.cp.rules = $0 }), pack: pack)
                    }
                    PointsSection(title: "Decisions", symbol: "checkmark.seal", points: $model.cp.decisions, pack: pack)
                    PointsSection(title: "Already tried", symbol: "arrow.uturn.backward", points: $model.cp.tried, pack: pack)
                    PointsSection(title: "Open questions", symbol: "questionmark.circle", points: $model.cp.openProblems, pack: pack)
                    if !model.cp.tabs.isEmpty { TabsSection(tabs: $model.cp.tabs) }
                }
                .padding(DS.S.l)
                .redacted(reason: model.phase == .writing ? .placeholder : [])
                .disabled(model.phase == .writing)
            }
            .frame(maxHeight: 520)

            PanelFooter {
                switch model.phase {
                case .writing: StatusLine(tone: .working, text: model.readingChat.map { "Reading your \($0) chat…" } ?? "Reading \(pack?.name ?? "the pack")…")
                case .failed(let msg): StatusLine(tone: .error, text: msg)
                case .ready: StatusLine(tone: .info, text: "Resume anywhere: hold ⌥V and say “pick up where I left off”.")
                }
            } actions: {
                HintButton(title: "Cancel", keys: "esc", action: onClose).keyboardShortcut(.cancelAction)
                HintButton(title: "Rewrite", keys: "⌘R", action: onRewrite)
                    .keyboardShortcut("r", modifiers: .command)
                    .disabled(model.phase == .writing)
                HintButton(title: "Save checkpoint", keys: "⌘↩", primary: true, action: onSave)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.phase == .writing || model.cp.isEmpty)
            }
        }
        .dsPanel(width: 600)
    }

    private var provenance: String {
        var parts: [String] = []
        if let p = model.previous { parts.append("Updates the checkpoint from \(p.created.formatted(.relative(presentation: .named)))") }
        else { parts.append("First checkpoint for this pack") }
        if let t = model.transcript { parts.append("read \(t.turns.count) message\(t.turns.count == 1 ? "" : "s") from \(t.service)") }
        if let e = model.cp.engine { parts.append("drafted by \(e)") }
        return parts.joined(separator: " · ")
    }
}

/// Goal and Next step: the two things you need first when you come back.
private struct KeyField: View {
    let title: String
    let symbol: String
    @Binding var text: String
    let placeholder: String
    let emphasized: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: symbol).font(.system(size: 11, weight: .semibold))
                Text(title).font(.system(size: 11.5, weight: .semibold))
            }
            .foregroundStyle(emphasized ? DS.accent : DS.text2)
            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 13, weight: emphasized ? .medium : .regular))
                .foregroundStyle(DS.text)
                .lineLimit(1...5)
        }
        .padding(DS.S.m)
        .frame(maxWidth: .infinity, alignment: .topLeading)
        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(emphasized ? DS.accentSoft : DS.well))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
            .strokeBorder(emphasized ? DS.accent.opacity(0.35) : DS.line, lineWidth: 0.5))
    }
}

private struct PointsSection: View {
    let title: String
    let symbol: String
    @Binding var points: [Checkpoint.Point]
    let pack: Pack?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                SectionLabel(title: title, symbol: symbol)
                if !points.isEmpty { Text("\(points.count)").font(.dsMeta).foregroundStyle(DS.text3) }
                Spacer()
                IconButton(symbol: "plus", help: "Add to \(title.lowercased())", size: 22) {
                    points.append(Checkpoint.Point(text: ""))
                }
            }
            if points.isEmpty {
                Text("Nothing yet").font(.dsCallout).foregroundStyle(DS.text3).padding(.leading, 2)
            }
            ForEach($points) { $p in
                HStack(alignment: .top, spacing: 8) {
                    Circle().fill(DS.text3).frame(width: 4, height: 4).padding(.top, 9)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("", text: $p.text, axis: .vertical)
                            .textFieldStyle(.plain)
                            .font(.dsBody)
                            .foregroundStyle(DS.text)
                            .lineLimit(1...4)
                            .padding(.vertical, 3)
                        let sources = p.sources.compactMap { id in pack?.captures.first { $0.id == id } }
                        if !sources.isEmpty {
                            HStack(spacing: 4) {
                                ForEach(sources.prefix(3)) { c in
                                    Label(c.displayTitle.truncated(28), systemImage: "link")
                                        .font(.system(size: 11))
                                        .foregroundStyle(DS.text2)
                                        .padding(.horizontal, 6).padding(.vertical, 1.5)
                                        .background(Capsule().fill(DS.well))
                                        .overlay(Capsule().strokeBorder(DS.line, lineWidth: 0.5))
                                        .help("From \(c.sourceSummary)")
                                }
                            }
                        }
                    }
                    IconButton(symbol: "xmark", help: "Remove", size: 20) { points.removeAll { $0.id == p.id } }
                }
            }
        }
    }
}

private struct TabsSection: View {
    @Binding var tabs: [Checkpoint.Tab]

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(title: "Pages to reopen when you resume", symbol: "safari")
                Spacer()
                Button(tabs.allSatisfy(\.keep) ? "Select none" : "Select all") {
                    let all = !tabs.allSatisfy(\.keep)
                    for i in tabs.indices { tabs[i].keep = all }
                }
                .buttonStyle(DSButtonStyle(kind: .plain, small: true))
            }
            ForEach($tabs) { $t in
                Toggle(isOn: $t.keep) {
                    HStack(spacing: 6) {
                        Text(t.title?.nonEmpty ?? t.url).foregroundStyle(DS.text).lineLimit(1)
                        Text(Capture.host(of: t.url) ?? "").foregroundStyle(DS.text3).lineLimit(1)
                    }
                    .font(.dsCallout)
                }
                .toggleStyle(.checkbox)
            }
        }
    }
}

// MARK: - Resume panel

@MainActor
final class ResumeModel: ObservableObject {
    @Published var target = DropTarget(app: nil, appName: "", destination: .generic, label: "")
    @Published var packID: UUID?
    @Published var checkpointID: UUID?
    @Published var prompt = ""
    @Published var includeEvidence = true
    @Published var includeTabs = true
    @Published var showPrompt = false
    /// Where it's going: the app you're in by default, or one you pick (changes the formatting).
    @Published var destinationLabel = ""
    @Published var forCode = false
    /// What changed since the checkpoint; shown before anything is handed over.
    @Published var stale = Checkpoint.Staleness()
    @Published var staleDismissed = false
    /// Let the next AI ask Shapr for more ("@shapr S3"), and check its read-back.
    @Published var askBack = RelaySettings.askBack
    @Published var readBack = RelaySettings.readBack
    @Published var handoff: Handoff?
    @Published var promptEdited = false
}

/// Continue in…: pick where you're going, see exactly what will be inserted, then insert.
struct ResumeView: View {
    @ObservedObject var model: ResumeModel
    @ObservedObject var store: PackStore
    var onRebuild: () -> Void = {}
    var onPickPack: (UUID) -> Void = { _ in }
    var onPickCheckpoint: (UUID) -> Void = { _ in }
    var onReopenTabs: () -> Void = {}
    var onCopy: () -> Void = {}
    var onInsert: () -> Void = {}
    var onClose: () -> Void = {}
    var onUpdateProgress: () -> Void = {}
    @State private var showSources = false

    private var pack: Pack? { store.pack(model.packID) }
    private var versions: [Checkpoint] { model.packID.map(store.checkpoints(for:)) ?? [] }
    private var current: Checkpoint? { versions.first { $0.id == model.checkpointID } ?? versions.first }
    private var destination: String { model.destinationLabel.isEmpty ? model.target.label : model.destinationLabel }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            PanelHeader(title: "Continue in \(destination)",
                        subtitle: model.handoff?.chat.map { $0.summary } ?? "Pastes a handoff where you're typing, sized for it",
                        appIcon: destination == model.target.label ? model.target.app?.icon : nil,
                        symbol: "arrow.uturn.right") { EmptyView() }
            Rectangle().fill(DS.line).frame(height: 0.5)

            VStack(alignment: .leading, spacing: 14) {
                // From this pack's saved progress, to that app: one line.
                HStack(spacing: 8) {
                    packMenu
                    if let cp = current, versions.count > 1 {
                        Text("v\(versions.count - (versions.firstIndex { $0.id == cp.id } ?? 0)) of \(versions.count)")
                            .font(.dsMeta).foregroundStyle(DS.text3)
                    }
                    Image(systemName: "arrow.right").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text3)
                        .accessibilityLabel("to")
                    destinationMenu
                    if model.forCode { Text("formatted for code tools").font(.dsMeta).foregroundStyle(DS.text3) }
                }

                if model.stale.isStale && !model.staleDismissed { staleWarning }
                if let cp = current { summary(cp) }

                VStack(alignment: .leading, spacing: 6) {
                    Button { model.showPrompt.toggle() } label: {
                        HStack(spacing: 5) {
                            Image(systemName: model.showPrompt ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                            Text("What will be pasted").font(.system(size: 11.5, weight: .semibold))
                            Text("· " + sizeLine).font(.dsMeta).foregroundStyle(fits ? DS.text3 : DS.warning)
                        }
                        .foregroundStyle(DS.text2)
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(model.showPrompt ? "Hide the prompt" : "Show the prompt")
                    if model.showPrompt {
                        TextEditor(text: $model.prompt)
                            .font(.system(size: 12))
                            .foregroundStyle(DS.text)
                            .scrollContentBackground(.hidden)
                            .padding(8)
                            .frame(height: 170)
                            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.well))
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
                    }
                    // The options sit with the text they change, out of the way until you open it.
                    Grid(alignment: .leading, horizontalSpacing: DS.S.l, verticalSpacing: 6) {
                        GridRow {
                            Toggle("Include key evidence", isOn: $model.includeEvidence)
                            Toggle("Let it ask Shapr for more", isOn: $model.askBack)
                                .help("The AI can write “@shapr S3” or “@shapr the error from earlier”, and Shapr offers to send it.")
                        }
                        GridRow {
                            Toggle("Include pages to reopen", isOn: $model.includeTabs)
                            Toggle("Check it read everything", isOn: $model.readBack)
                                .help("The AI starts its reply with your goal, rules and next step; Shapr checks nothing was lost.")
                        }
                    }
                    .toggleStyle(.checkbox)
                    .font(.dsCallout)
                    .frame(height: model.showPrompt ? nil : 0)
                    .clipped()
                    .opacity(model.showPrompt ? 1 : 0)
                    .accessibilityHidden(!model.showPrompt)
                    .onChange(of: model.includeEvidence) { _, _ in onRebuild() }
                    .onChange(of: model.includeTabs) { _, _ in onRebuild() }
                    .onChange(of: model.askBack) { _, v in RelaySettings.askBack = v; onRebuild() }
                    .onChange(of: model.readBack) { _, v in RelaySettings.readBack = v; onRebuild() }
                }
            }
            .padding(DS.S.l)

            PanelFooter {
                let tabCount = current?.tabs.filter(\.keep).count ?? 0
                if tabCount > 0 {
                    HintButton(title: "Reopen \(tabCount) page\(tabCount == 1 ? "" : "s")", keys: "⌘O", action: onReopenTabs)
                        .keyboardShortcut("o", modifiers: .command)
                }
            } actions: {
                HintButton(title: "Cancel", keys: "esc", action: onClose).keyboardShortcut(.cancelAction)
                HintButton(title: "Copy", keys: "⇧⌘C", action: onCopy).keyboardShortcut("c", modifiers: [.command, .shift])
                HintButton(title: "Insert", keys: "⌘↩", primary: true, action: onInsert)
                    .keyboardShortcut(.return, modifiers: .command)
                    .disabled(model.prompt.isEmpty)
            }
        }
        .dsPanel(width: 560)
    }

    private var packMenu: some View {
        Menu {
            Section("Pack") {
                ForEach(store.packs.filter { !store.checkpoints(for: $0.id).isEmpty }) { p in
                    Button(p.label) { onPickPack(p.id) }
                }
            }
            Section("Version") {
                ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                    Button("v\(versions.count - i)" + (i == 0 ? " · latest" : "") + " · " + v.created.formatted(date: .abbreviated, time: .shortened)) {
                        onPickCheckpoint(v.id)
                    }
                }
            }
        } label: { PackChip(pack: pack, chevron: true) }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Pack and checkpoint version")
    }

    private var destinationMenu: some View {
        Menu {
            Button("This app (\(model.target.label))") { pick(model.target.label, model.target.destination == .code) }
            Divider()
            ForEach([("Claude", false), ("ChatGPT", false), ("Gemini", false), ("Cursor", true), ("Claude Code", true), ("Terminal", true)],
                    id: \.0) { name, code in
                Button(name + (code ? " (code formatting)" : "")) { pick(name, code) }
            }
        } label: {
            HStack(spacing: 5) {
                Text(destination).font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 8, weight: .semibold)).foregroundStyle(DS.text3)
            }
            .foregroundStyle(DS.text)
            .padding(.horizontal, 8).padding(.vertical, 3.5)
            .background(Capsule().fill(DS.well))
            .overlay(Capsule().strokeBorder(DS.line, lineWidth: 0.5))
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("Destination: \(destination)")
    }

    private var fits: Bool { model.handoff.map { model.prompt.count <= $0.budget } ?? true }

    /// "≈2,900 tokens · sized for free ChatGPT".
    private var sizeLine: String {
        guard let h = model.handoff else { return "\(model.prompt.count) characters, editable" }
        let tokens = ((model.prompt.count + 3) / 4).formatted()
        let target = HandoffBuilder.target(for: h.targetName, code: model.forCode)
        return fits ? "≈\(tokens) tokens · \(target.sizeNote)" : "≈\(tokens) tokens · longer than \(target.sizeNote.replacingOccurrences(of: "sized for ", with: "")) handles well"
    }

    private func pick(_ label: String, _ code: Bool) {
        model.destinationLabel = label
        model.forCode = code
        onRebuild()
    }

    /// "Since you saved this: 3 new captures · notes.pdf changed". Shown before anything is handed over.
    private var staleWarning: some View {
        var lines: [String] = []
        if model.stale.newCaptures > 0 { lines.append("\(model.stale.newCaptures) new capture\(model.stale.newCaptures == 1 ? "" : "s") in \(pack?.name ?? "the pack")") }
        if !model.stale.changedFiles.isEmpty { lines.append(model.stale.changedFiles.prefix(3).joined(separator: ", ") + " changed") }
        if model.stale.removedSources > 0 { lines.append("\(model.stale.removedSources) source\(model.stale.removedSources == 1 ? " was" : "s were") removed") }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "clock.badge.exclamationmark").foregroundStyle(DS.warning).font(.system(size: 15))
            VStack(alignment: .leading, spacing: 6) {
                Text("Since you saved this: " + lines.joined(separator: " · ")).font(.dsCallout).foregroundStyle(DS.text)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 6) {
                    Button("Update progress first", action: onUpdateProgress).buttonStyle(DSButtonStyle(kind: .primary, small: true))
                    Button("Continue anyway") { model.staleDismissed = true }.buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                }
            }
        }
        .padding(DS.S.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(DS.warning.opacity(0.10)))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).strokeBorder(DS.warning.opacity(0.4), lineWidth: 0.5))
    }

    private func summary(_ cp: Checkpoint) -> some View {
        let cited = (cp.decisions + cp.tried + cp.openProblems).flatMap(\.sources)
        let sources = cited.reduce(into: [UUID]()) { if !$0.contains($1) { $0.append($1) } }
            .compactMap { id in pack?.captures.first { $0.id == id } }
        return VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(cp.title?.nonEmpty ?? pack?.name ?? "").font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                Text("Saved \(cp.created.formatted(.relative(presentation: .named)))"
                     + (cp.author.map { $0 == "Shapr" ? "" : " by \($0)" } ?? "") + counts(cp))
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            if let g = cp.goal.nonEmpty { fact("Working toward", g) }
            if !cp.decisions.isEmpty {
                fact("Already decided", cp.decisions.prefix(3).map(\.text).joined(separator: "\n")
                     + (cp.decisions.count > 3 ? "\n+ \(cp.decisions.count - 3) more" : ""))
            }
            if let n = cp.nextStep.nonEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Next").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.accent)
                    Text(n).font(.dsCallout).fontWeight(.medium).foregroundStyle(DS.text)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.accentSoft))
            }
            if !sources.isEmpty {
                Button { showSources.toggle() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: showSources ? "chevron.down" : "chevron.right").font(.system(size: 9, weight: .semibold))
                        Text("Sources · \(sources.count)").font(.system(size: 11.5, weight: .semibold))
                    }
                    .foregroundStyle(DS.text2)
                }
                .buttonStyle(.plain)
                if showSources {
                    ForEach(sources) { c in
                        HStack(spacing: 6) {
                            SourceBadge(capture: c, size: 16)
                            Text(c.displayTitle).font(.dsCallout).foregroundStyle(DS.text).lineLimit(1)
                            Text(c.sourceSummary).font(.dsMeta).foregroundStyle(DS.text3).lineLimit(1)
                        }
                    }
                }
            }
        }
        .padding(DS.S.m)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(DS.well))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
    }

    private func counts(_ cp: Checkpoint) -> String {
        var parts: [String] = []
        if !cp.decisions.isEmpty { parts.append("\(cp.decisions.count) decided") }
        if !cp.tried.isEmpty { parts.append("\(cp.tried.count) tried") }
        if !cp.openProblems.isEmpty { parts.append("\(cp.openProblems.count) open") }
        return parts.isEmpty ? "" : " · " + parts.joined(separator: " · ")
    }

    private func fact(_ label: String, _ text: String) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(label).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
            Text(text).font(.dsCallout).foregroundStyle(DS.text).fixedSize(horizontal: false, vertical: true)
        }
    }
}

// MARK: - Library card: "Where you left off"

struct CheckpointCard: View {
    @EnvironmentObject var store: PackStore
    let pack: Pack
    var onSave: () -> Void = {}
    var onCopyResume: (Checkpoint) -> Void = { _ in }
    @State private var viewing: Checkpoint?

    var body: some View {
        let versions = store.checkpoints(for: pack.id)
        if let cp = versions.first {
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 6) {
                    SectionLabel(title: "Where you left off", symbol: "flag")
                    Text("· saved \(cp.created.formatted(.relative(presentation: .named)))").font(.dsMeta).foregroundStyle(DS.text3)
                    Spacer()
                    if versions.count > 1 {
                        Menu {
                            ForEach(Array(versions.enumerated()), id: \.element.id) { i, v in
                                Button("v\(versions.count - i) · " + v.created.formatted(date: .abbreviated, time: .shortened)
                                       + (v.title.map { " · \($0)" } ?? "")) { viewing = v }
                            }
                        } label: {
                            Label("History", systemImage: "clock.arrow.circlepath")
                        }
                        .menuStyle(.button)
                        .buttonStyle(DSButtonStyle(kind: .plain, small: true))
                        .fixedSize()
                    }
                }
                VStack(alignment: .leading, spacing: 4) {
                    if let t = cp.title?.nonEmpty { Text(t).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text) }
                    if let g = cp.goal.nonEmpty { Text(g).font(.dsBody).foregroundStyle(DS.text2) }
                }
                if let n = cp.nextStep.nonEmpty {
                    Label { Text(n).fontWeight(.medium).foregroundStyle(DS.text) } icon: {
                        Image(systemName: "arrow.right.circle").foregroundStyle(DS.accent)
                    }
                    .font(.dsCallout)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.accentSoft))
                }
                HStack(spacing: 6) {
                    Button { onCopyResume(cp) } label: { Label("Copy resume prompt", systemImage: "doc.on.clipboard") }
                    if !cp.tabs.filter(\.keep).isEmpty {
                        Button { BrowserTabs.reopen(cp.tabs) } label: { Label("Reopen pages", systemImage: "safari") }
                    }
                    Button { viewing = cp } label: { Label("View", systemImage: "eye") }
                    Spacer()
                    Text(counts(cp)).font(.dsMeta).foregroundStyle(DS.text3)
                    Button { onSave() } label: { Label("Update", systemImage: "flag") }
                }
                .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
            }
            .dsCard(padding: 14)
            .sheet(item: $viewing) { v in
                VStack(alignment: .leading, spacing: 12) {
                    Text(v.title?.nonEmpty ?? "Checkpoint").font(.dsTitle)
                    Text(v.created.formatted(date: .abbreviated, time: .shortened)
                         + (v.author.map { $0 == "Shapr" ? "" : " · saved by \($0)" } ?? ""))
                        .font(.dsMeta).foregroundStyle(DS.text2)
                    ScrollView {
                        Text(v.markdown).font(.dsBody).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
                    }
                    HStack {
                        Button("Copy resume prompt") { onCopyResume(v); viewing = nil }.buttonStyle(.dsSecondary)
                        Spacer()
                        Button("Done") { viewing = nil }.buttonStyle(.dsPrimary).keyboardShortcut(.defaultAction)
                    }
                }
                .padding(20)
                .frame(width: 560, height: 460)
                .background(DS.panel)
            }
        }
    }

    private func counts(_ cp: Checkpoint) -> String {
        var parts: [String] = []
        if !cp.decisions.isEmpty { parts.append("\(cp.decisions.count) decided") }
        if !cp.tried.isEmpty { parts.append("\(cp.tried.count) tried") }
        if !cp.openProblems.isEmpty { parts.append("\(cp.openProblems.count) open") }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Controllers

/// ⌥⇧P (or "Save progress" in the library): write a checkpoint for a pack, review, save.
@MainActor
final class CheckpointController {
    private let store: PackStore
    private let toast: ToastController
    private let model = CheckpointModel()
    private let panel = FloatingPanel(size: NSSize(width: 640, height: 640), level: .floating)
    private var task: Task<Void, Never>?

    init(store: PackStore, toast: ToastController) {
        self.store = store
        self.toast = toast
        panel.hasShadow = true
        panel.contentView = FirstMouseHostingView(rootView: CheckpointView(
            model: model, store: store,
            onSave: { [weak self] in MainActor.assumeIsolated { self?.save() } },
            onRewrite: { [weak self] in MainActor.assumeIsolated { self?.write(readingFrom: nil) } },
            onClose: { [weak self] in MainActor.assumeIsolated { self?.close() } }
        ))
    }

    func open(packID: UUID? = nil) {
        // In an AI chat? Then the chat itself is what you were working on: read it, word for word.
        var chat: (pid: pid_t, service: String, url: String?, title: String?)?
        if CaptureService.isTrusted, let front = NSWorkspace.shared.frontmostApplication, ChatReader.mightBeChat(bundleID: front.bundleIdentifier) {
            let info = ChatReader.pageInfo(pid: front.processIdentifier)
            if let service = ChatReader.service(url: info.url, bundleID: front.bundleIdentifier) {
                chat = (front.processIdentifier, service, info.url, info.title)
            }
        }
        var pack = store.pack(packID) ?? store.pack(store.equippedPackID) ?? store.pack(store.activePackID) ?? store.packs.first
        if pack == nil, let chat {
            pack = store.createPack(name: ChatReader.cleanTitle(chat.title, service: chat.service) ?? "\(chat.service) chat", emoji: "💬", autoNamed: true)
        }
        guard let pack else {
            toast.show(ToastContent(icon: .symbol("tray"), title: "No packs yet",
                                    subtitle: "Open the AI chat you're working in and say “save my progress” there, or scoop your notes into a pack first.", tint: DS.warning), duration: 4)
            return
        }
        guard !pack.captures.isEmpty || chat != nil else {
            toast.show(ToastContent(icon: .symbol("tray"), title: "\(pack.name) is empty",
                                    subtitle: "Say “save my progress” inside the AI chat you're working in, or save your notes first.", tint: DS.warning), duration: 4)
            return
        }
        model.packID = pack.id
        model.previous = store.latestCheckpoint(for: pack.id)
        model.transcript = nil
        model.readingChat = chat?.service
        var fresh = Checkpoint()
        fresh.tabs = BrowserTabs.preselect(BrowserTabs.current(), for: pack)
        model.cp = fresh
        let size = panel.contentView!.fittingSize
        if let vf = NSScreen.underMouse?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - vf.height * 0.06,
                                  width: size.width, height: size.height), display: true)
        }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
        NSApp.activate()
        write(readingFrom: chat)
    }

    private func write(readingFrom chat: (pid: pid_t, service: String, url: String?, title: String?)? = nil) {
        guard let pack = store.pack(model.packID) else { return }
        task?.cancel()
        model.phase = .writing
        let previous = model.previous
        task = Task { [weak self] in
            var transcript = self?.model.transcript
            if let chat, transcript == nil {
                transcript = await Task.detached(priority: .userInitiated) {
                    ChatReader.read(pid: chat.pid, service: chat.service, url: chat.url, title: chat.title)
                }.value
                guard let self, !Task.isCancelled else { return }
                self.model.transcript = transcript
                self.model.readingChat = nil
                if transcript == nil, pack.captures.isEmpty {
                    self.model.phase = .failed("Couldn't read the chat. Open the conversation so its messages are on screen, then say “save my progress” again.")
                    return
                }
            }
            // Rules carry over only from earlier saves of the same conversation (or when there's no chat).
            let prev = transcript == nil || previous?.conversation?.url == transcript?.url ? previous : previous.map { p -> Checkpoint in
                var p = p; p.rules = nil; return p
            }
            do {
                var cp = try await CheckpointWriter.write(pack: pack, previous: prev, transcript: transcript)
                guard let self, !Task.isCancelled else { return }
                cp.tabs = self.model.cp.tabs
                self.model.cp = cp
                self.model.phase = .ready
            } catch {
                guard let self, !Task.isCancelled else { return }
                // Start from the previous checkpoint so the user can still edit and save by hand.
                if let previous { var cp = previous; cp.id = UUID(); cp.tabs = self.model.cp.tabs; self.model.cp = cp }
                self.model.phase = .failed(error.localizedDescription)
            }
        }
    }

    private func save() {
        guard let id = model.packID else { return }
        var cp = model.cp
        cp.id = UUID()
        cp.created = Date()
        cp.author = "Shapr"
        for list in [\Checkpoint.decisions, \.tried, \.openProblems] {
            cp[keyPath: list] = cp[keyPath: list].filter { $0.text.nonEmpty != nil }
        }
        cp.rules = cp.rules?.filter { $0.text.nonEmpty != nil }
        if cp.conversation == nil { cp.conversation = model.transcript }
        guard store.saveCheckpoint(cp, for: id) else { return }
        close()
        toast.show(ToastContent(icon: .symbol("flag.checkered"), title: "Progress saved",
                                subtitle: "In any AI tool, hold ⌥V and say “pick up where I left off”.", tint: DS.accent), duration: 3.5)
    }

    private func close() {
        task?.cancel()
        panel.allowsKey = false
        panel.orderOut(nil)
    }
}

/// ⌥⇧R: in any AI chat or coding tool, insert a continuation prompt built from the latest checkpoint.
@MainActor
final class ResumeController {
    private let store: PackStore
    private let toast: ToastController
    private let model = ResumeModel()
    private let panel = FloatingPanel(size: NSSize(width: 640, height: 520), level: .floating)
    var onNeedsCheckpoint: (UUID) -> Void = { _ in }
    /// After the handoff lands: start watching that chat for its read-back and "@shapr" requests.
    var onInserted: (Handoff, NSRunningApplication, UUID?, Checkpoint) -> Void = { _, _, _, _ in }

    init(store: PackStore, toast: ToastController) {
        self.store = store
        self.toast = toast
        panel.hasShadow = true
        panel.contentView = FirstMouseHostingView(rootView: ResumeView(
            model: model, store: store,
            onRebuild: { [weak self] in MainActor.assumeIsolated { self?.rebuild() } },
            onPickPack: { [weak self] id in MainActor.assumeIsolated { self?.pick(pack: id) } },
            onPickCheckpoint: { [weak self] id in MainActor.assumeIsolated { self?.model.checkpointID = id; self?.rebuild() } },
            onReopenTabs: { [weak self] in MainActor.assumeIsolated { self?.reopen() } },
            onCopy: { [weak self] in MainActor.assumeIsolated { self?.copy() } },
            onInsert: { [weak self] in MainActor.assumeIsolated { self?.insert() } },
            onClose: { [weak self] in MainActor.assumeIsolated { self?.close() } },
            onUpdateProgress: { [weak self] in MainActor.assumeIsolated {
                guard let self, let id = self.model.packID else { return }
                self.close()
                self.onNeedsCheckpoint(id)
            } }
        ))
    }

    /// `preferring`: a pack to resume first (Shapr Flow passes the task's pack).
    func open(preferring preferred: UUID? = nil) {
        if panel.isVisible, preferred == nil { panel.makeKeyAndOrderFront(nil); return }
        let candidates = [preferred, store.equippedPackID, store.activePackID].compactMap { $0 }
            + store.packs.map(\.id)
        guard let packID = candidates.first(where: { store.latestCheckpoint(for: $0) != nil }) else {
            let fallback = store.pack(store.equippedPackID) ?? store.packs.first
            toast.show(ToastContent(icon: .symbol("flag.checkered"), title: "No checkpoint yet",
                                    subtitle: "Save progress on a pack first, then resume it anywhere.",
                                    actions: fallback.map { p in [ToastAction(title: "Save progress", style: .primary) { [weak self] in
                                        self?.onNeedsCheckpoint(p.id)
                                    }] } ?? [], tint: DS.warning), duration: 5)
            return
        }
        model.target = DropDetector.detect()
        model.includeEvidence = true
        model.includeTabs = true
        model.showPrompt = true
        model.askBack = RelaySettings.askBack
        model.readBack = RelaySettings.readBack
        model.destinationLabel = model.target.label
        model.forCode = model.target.destination == .code
        pick(pack: packID)
        let size = panel.contentView!.fittingSize
        if let vf = NSScreen.underMouse?.visibleFrame {
            panel.setFrame(NSRect(x: vf.midX - size.width / 2, y: vf.maxY - size.height - vf.height * 0.1,
                                  width: size.width, height: size.height), display: true)
        }
        panel.allowsKey = true
        panel.makeKeyAndOrderFront(nil)
        panel.orderFrontRegardless()
    }

    private func pick(pack id: UUID) {
        model.packID = id
        model.checkpointID = store.latestCheckpoint(for: id)?.id
        rebuild()
    }

    private var checkpoint: Checkpoint? {
        guard let id = model.packID else { return nil }
        let all = store.checkpoints(for: id)
        return all.first { $0.id == model.checkpointID } ?? all.first
    }

    private func rebuild() {
        guard let pack = store.pack(model.packID), let cp = checkpoint else { return }
        let stale = cp.staleness(in: pack)
        if stale != model.stale { model.stale = stale; model.staleDismissed = false }
        let name = model.destinationLabel.isEmpty ? model.target.label : model.destinationLabel
        let handoff = HandoffBuilder.build(pack: pack, checkpoint: cp, target: HandoffBuilder.target(for: name, code: model.forCode),
                                           options: .init(askBack: model.askBack, readBack: model.readBack,
                                                          includeEvidence: model.includeEvidence, includeTabs: model.includeTabs))
        model.handoff = handoff
        model.prompt = handoff.text
    }

    private func reopen() {
        if let cp = checkpoint { BrowserTabs.reopen(cp.tabs) }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(model.prompt, forType: .string)
        close()
        toast.show(ToastContent(icon: .symbol("doc.on.clipboard"), title: "Resume prompt copied",
                                subtitle: "Paste it into any AI tool."), duration: 2)
    }

    private func insert() {
        let text = model.prompt
        let label = model.target.label
        let app = model.target.app
        let handoff = model.handoff
        let packID = model.packID
        let cp = checkpoint
        close()
        TextInserter.paste(text, into: app) { [weak self] ok in
            if ok, let self, let app, var handoff, let cp {
                handoff.text = text
                self.onInserted(handoff, app, packID, cp)
            }
            guard !ok else { return }
            self?.toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't get back to \(label)",
                                          subtitle: "The resume prompt is on the clipboard. Click where it goes and press ⌘V.",
                                          tint: DS.warning), duration: 6)
        }
    }

    private func close() {
        panel.allowsKey = false
        panel.orderOut(nil)
    }
}
