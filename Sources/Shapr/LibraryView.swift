import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers

/// What the library can ask the app to do (kept as closures so views stay simple and previewable).
struct LibraryActions {
    var copyPrompt: (UUID) -> Void = { _ in }
    var exportMarkdown: (UUID) -> Void = { _ in }
    var safeShare: (UUID) -> Void = { _ in }
    var equip: (UUID?) -> Void = { _ in }
    var revealInFinder: (URL) -> Void = { _ in }
    var openSettings: () -> Void = {}
    var newPack: () -> UUID? = { nil }
    var saveProgress: (UUID) -> Void = { _ in }
    var copyResume: (UUID, Checkpoint) -> Void = { _, _ in }
    var importFiles: ([URL], UUID) -> Void = { _, _ in }
    var addSource: (PackSource.Kind, UUID) -> Void = { _, _ in }
    var syncSource: (UUID, UUID) -> Void = { _, _ in }
    var removeSource: (UUID, UUID, Bool) -> Void = { _, _, _ in }
    var ask: (UUID) -> Void = { _ in }
}

@MainActor
final class LibraryState: ObservableObject {
    enum Layout: String { case grid, list, graph }
    enum KindFilter: String, CaseIterable, Identifiable {
        case all, text, images, files
        var id: String { rawValue }
        var title: String {
            switch self {
            case .all: return "All"
            case .text: return "Text"
            case .images: return "Screenshots"
            case .files: return "Files"
            }
        }
        func matches(_ c: Capture) -> Bool {
            switch self {
            case .all: return true
            case .text: return c.image == nil && c.file == nil
            case .images: return c.image != nil
            case .files: return c.file != nil
            }
        }
    }

    @Published var selection: UUID? { didSet { if selection != oldValue { filter = .all } } }
    @Published var renaming: UUID?
    @Published var renameText = ""
    @Published var confirmDelete: UUID?
    @Published var query = ""
    /// The capture shown in the preview panel.
    @Published var selectedCapture: UUID?
    @Published var axTrusted = AXIsProcessTrusted()
    @Published var screenTrusted = ScreenCapture.hasPermission
    @Published var micAllowed = VoiceSettings.micStatus == .authorized
    @Published var filter: KindFilter = .all
    @Published var layout: Layout = Layout(rawValue: UserDefaults.standard.string(forKey: "libraryLayout") ?? "") ?? .grid {
        didSet { UserDefaults.standard.set(layout.rawValue, forKey: "libraryLayout") }
    }
}

/// The library window: packs and search in a stable sidebar, the selected pack's captures as cards,
/// and a preview panel for the selected capture.
struct LibraryView: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let actions: LibraryActions
    @FocusState private var searchFocused: Bool

    static let sidebarWidth: CGFloat = 236
    static let inspectorWidth: CGFloat = 340

    /// A native split window (CodeEdit's layout): packs in a glass sidebar with search, the pack in the
    /// middle with its title and actions in the toolbar, and the selected capture in an inspector.
    var body: some View {
        NavigationSplitView {
            LibrarySidebar(actions: actions)
                .navigationSplitViewColumnWidth(min: 210, ideal: 240, max: 320)
        } detail: {
            detail
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(DS.canvas)
                .inspector(isPresented: inspectorShown) {
                    Group {
                        if let (c, p) = selected { CaptureInspector(capture: c, pack: p) } else { Color.clear }
                    }
                    .inspectorColumnWidth(min: 280, ideal: Self.inspectorWidth, max: 480)
                }
        }
        .searchable(text: $state.query, placement: .sidebar, prompt: "Search all packs")
        .searchFocused($searchFocused)
        .foregroundStyle(DS.text)
        .background {
            // ⌘F jumps to search.
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
        .alert("Rename pack", isPresented: Binding(get: { state.renaming != nil }, set: { if !$0 { state.renaming = nil } })) {
            TextField("Name", text: $state.renameText)
            Button("Rename") {
                if let id = state.renaming { store.rename(id, to: state.renameText) }
                state.renaming = nil
            }
            Button("Cancel", role: .cancel) { state.renaming = nil }
        }
        .confirmationDialog("Move this pack to the Trash?",
                            isPresented: Binding(get: { state.confirmDelete != nil }, set: { if !$0 { state.confirmDelete = nil } })) {
            Button("Move to Trash", role: .destructive) {
                if let id = state.confirmDelete { store.deletePack(id) }
                state.confirmDelete = nil
                state.selection = nil
            }
        } message: {
            Text("Its folder goes to the Finder Trash, so you can still restore it.")
        }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            let t = AXIsProcessTrusted()
            if t != state.axTrusted { state.axTrusted = t }
            let s = ScreenCapture.hasPermission
            if s != state.screenTrusted { state.screenTrusted = s }
            let m = VoiceSettings.micStatus == .authorized
            if m != state.micAllowed { state.micAllowed = m }
        }
    }

    private var inspectorShown: Binding<Bool> {
        Binding(get: { selected != nil }, set: { if !$0 { state.selectedCapture = nil } })
    }

    /// The capture in the preview panel, wherever it lives (search spans every pack).
    private var selected: (Capture, Pack)? {
        guard let id = state.selectedCapture else { return nil }
        for p in store.packs { if let c = p.captures.first(where: { $0.id == id }) { return (c, p) } }
        return nil
    }

    @ViewBuilder
    private var detail: some View {
        if let q = state.query.nonEmpty {
            SearchResultsView(query: q).navigationTitle("Search").navigationSubtitle("“\(q)” in all packs")
        } else if let id = state.selection, let pack = store.pack(id) {
            PackDetailView(pack: pack, actions: actions)
        } else {
            WelcomeView(actions: actions).navigationTitle("Shapr")
        }
    }
}

// MARK: - Sidebar

private struct LibrarySidebar: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    @EnvironmentObject var shares: SharedPacks
    let actions: LibraryActions
    @State private var showShortcuts = false

    var body: some View {
        let onWheel = store.wheelSlots.enumerated().compactMap { i, id in store.pack(id).map { (i, $0) } }
        let others = store.packs.filter { p in !store.wheelSlots.contains(p.id) }
        List(selection: Binding(get: { state.query.isEmpty ? state.selection : nil },
                                set: { if let id = $0 { state.selection = id; state.query = "" } })) {
            Section {
                if onWheel.isEmpty {
                    Text("Hold ⌥S to put packs on your wheel.").font(.dsMeta).foregroundStyle(DS.text3)
                }
                ForEach(onWheel, id: \.1.id) { i, p in row(p, slot: i).tag(p.id) }
            } header: {
                sectionHeader("On your wheel", showsAdd: true)
            }
            if !others.isEmpty {
                Section {
                    ForEach(others) { p in row(p, slot: nil).tag(p.id) }
                } header: {
                    sectionHeader("More packs")
                }
            }
        }
        .listStyle(.sidebar)
        .safeAreaInset(edge: .bottom, spacing: 0) {
            VStack(spacing: 0) {
                Divider()
                footer
            }
        }
    }

    private func sectionHeader(_ title: String, showsAdd: Bool = false) -> some View {
        HStack {
            Text(title).font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text3)
            Spacer()
            if showsAdd {
                IconButton(symbol: "plus", help: "New pack (it's equipped, so your next scoops go into it)", size: 20) {
                    if let id = actions.newPack() {
                        state.selection = id
                        state.renameText = ""
                        state.renaming = id
                    }
                }
            }
        }
        .accessibilityAddTraits(.isHeader)
    }

    private func row(_ p: Pack, slot: Int?) -> some View {
        PackRow(pack: p, slot: slot, equipped: store.equippedPackID == p.id,
                selected: state.selection == p.id && state.query.isEmpty,
                live: shares.shared[p.id] != nil ? .shared : (shares.subscribed[p.id] != nil ? .joined : nil))
            .dropDestination(for: String.self) { items, _ in
                for s in items { if let id = UUID(uuidString: s) { store.moveCapture(id, to: p.id) } }
                return true
            }
            .contextMenu { PackMenu(pack: p, actions: actions) }
    }

    private var footer: some View {
        let equipped = store.pack(store.equippedPackID)
        // One quiet line: where new captures go, then shortcuts and settings.
        return HStack(spacing: 6) {
            Button { actions.equip(nil) } label: {
                HStack(spacing: 6) {
                    Image(systemName: equipped == nil ? "sparkles" : "scope")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.accent)
                    Text(equipped.map { "\($0.label) equipped" } ?? "Auto-sort")
                        .font(.system(size: 12, weight: .medium)).foregroundStyle(DS.text).lineLimit(1).truncationMode(.middle)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(equipped == nil)
            .help(equipped == nil ? "Shapr picks a pack for each capture" : "New captures go to \(equipped?.name ?? ""). Click to go back to auto-sort.")
            Spacer(minLength: 0)
            IconButton(symbol: "keyboard", help: "Shortcuts") { showShortcuts.toggle() }
                .popover(isPresented: $showShortcuts, arrowEdge: .top) { ShortcutsList().padding(16).frame(width: 300) }
            IconButton(symbol: "gearshape", help: "Settings") { actions.openSettings() }
        }
        .padding(.horizontal, DS.S.m)
        .padding(.vertical, DS.S.s)
    }
}

private struct PackRow: View {
    enum Live { case shared, joined }
    let pack: Pack
    let slot: Int?
    let equipped: Bool
    let selected: Bool
    var live: Live? = nil
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 8) {
            Text(slot.map { "\($0 + 1)" } ?? "")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(DS.text3)
                .frame(width: 8)
            PackIcon(pack: pack, size: 22)
            Text(pack.name)
                .font(.system(size: 13))
                .lineLimit(1)
                .truncationMode(.tail)
            Spacer(minLength: 4)
            if let live {
                Image(systemName: live == .shared ? "link" : "arrow.triangle.2.circlepath")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(DS.text3)
                    .help(live == .shared ? "Shared with a live link" : "Added from a shared link; stays up to date")
            }
            if equipped {
                Image(systemName: "scope")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DS.accent)
                    .help("Equipped: new captures go here")
            }
            Text("\(pack.captures.count)")
                .font(.system(size: 11).monospacedDigit())
                .foregroundStyle(DS.text3)
        }
        .frame(height: 26)
        .contentShape(Rectangle())
        .help(pack.name)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(pack.name), \(pack.captures.count) captures\(equipped ? ", equipped" : "")"
                            + (live == .shared ? ", shared" : live == .joined ? ", joined" : "")
                            + (slot.map { ", wheel slot \($0 + 1)" } ?? ""))
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }
}

/// Everything you can do to a pack, shared by the sidebar's right-click menu and the pack's ⋯ menu.
private struct PackMenu: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let pack: Pack
    let actions: LibraryActions

    var body: some View {
        Button(store.equippedPackID == pack.id ? "Unequip (Auto-sort)" : "Equip") {
            actions.equip(store.equippedPackID == pack.id ? nil : pack.id)
        }
        Menu("Put on Wheel Slot") {
            ForEach(0..<6, id: \.self) { i in
                Button("Slot \(i + 1)" + (store.pack(store.wheelSlots[i]).map { " (\($0.name))" } ?? "")) {
                    store.place(pack.id, inSlot: i)
                }
            }
        }
        Button("Ask This Pack…") { actions.ask(pack.id) }
        Divider()
        Menu("Keep Updated From") {
            Button("A Folder…") { actions.addSource(.folder, pack.id) }
            Button("A GitHub Repo…") { actions.addSource(.github, pack.id) }
            Button("A Notion Page…") { actions.addSource(.notion, pack.id) }
            Button("A Web Page or Email Thread…") { actions.addSource(.web, pack.id) }
        }
        Button("Add Files…") {
            let panel = NSOpenPanel()
            panel.allowsMultipleSelection = true
            panel.canChooseDirectories = false
            panel.allowedContentTypes = (FileTypes.documents.union(FileTypes.text).union(FileTypes.images))
                .compactMap { UTType(filenameExtension: $0) }
            if panel.runModal() == .OK { actions.importFiles(panel.urls, pack.id) }
        }
        Button("Copy for Claude") { actions.copyPrompt(pack.id) }
        Button("Save Progress…") { actions.saveProgress(pack.id) }
        Button("Share Safely…") { actions.safeShare(pack.id) }
        Button("Export Markdown…") { actions.exportMarkdown(pack.id) }
        Divider()
        Button(pack.isStyle ? "Use for Facts Instead" : "Use as My Writing Style") {
            store.setRole(pack.id, pack.isStyle ? .facts : .style)
        }
        Button("Rename…") { state.renameText = pack.name; state.renaming = pack.id }
        Button("Show in Finder") { actions.revealInFinder(pack.folder) }
        Menu("Merge Into") {
            ForEach(store.packs.filter { $0.id != pack.id }) { other in
                Button(other.label) { store.merge(pack.id, into: other.id); state.selection = other.id }
            }
        }
        Divider()
        Button("Move to Trash…", role: .destructive) { state.confirmDelete = pack.id }
    }
}

/// Every shortcut, in one place.
struct ShortcutsList: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Shortcuts").font(.dsHeadline)
            ForEach(Self.items, id: \.0) { label, keys in
                HStack {
                    Text(label).font(.dsCallout).foregroundStyle(DS.text2)
                    Spacer()
                    Keycap(keys: keys)
                }
            }
        }
    }

    static var items: [(String, String)] {
        var items: [(String, String)] = [
         ("Talk to Shapr: hold, say anything", "⌥V"),
         ("Scoop the highlighted text", "⌥C"),
         ("Circle anything on screen", DoubleTapDetector.Key.current.symbol),
         ("Wheel: hold, point, let go", "⌥S")]
        guard ShortcutSettings.classic else { return items }
        items += [("Everything, beside the pointer", "⌥⇧Space"),
                  ("Use this with my pack", "⌥⇧U"),
                  ("Drag around a screen area", "⌥⇧X"),
                  ("Draft where you're typing", "⌥⇧D"),
                  ("Fill the form you're in", "⌥⇧F"),
                  ("Ask your packs", "⌥⇧A"),
                  ("Save progress", "⌥⇧P"),
                  ("Continue in another app", "⌥⇧R")]
        return items
    }
}

// MARK: - Pack detail

struct PackDetailView: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let pack: Pack
    let actions: LibraryActions
    @State private var gridWidth: CGFloat = 700
    @FocusState private var gridFocused: Bool

    private static let tileMin: CGFloat = 220
    private static let spacing: CGFloat = 14

    private var shown: [Capture] { pack.captures.reversed().filter(state.filter.matches) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if !pack.captures.isEmpty || pack.isStyle || !store.sources(for: pack.id).isEmpty {
                header
                    .padding(.horizontal, DS.S.xl)
                    .padding(.vertical, DS.S.m)
                Rectangle().fill(DS.line).frame(height: 0.5)
            }
            if state.layout == .graph, !pack.captures.isEmpty {
                PackGraphView(pack: pack).id(pack.id)
            } else {
                captureScroll
            }
        }
        .dropDestination(for: URL.self) { urls, _ in
            let files = urls.filter(\.isFileURL)
            guard !files.isEmpty else { return false }
            actions.importFiles(files, pack.id)
            return true
        }
        .navigationTitle(pack.name)
        .navigationSubtitle(metaLine)
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                ShareStatus(pack: pack, actions: actions)
                let equipped = store.equippedPackID == pack.id
                Button { actions.equip(equipped ? nil : pack.id) } label: {
                    Label(equipped ? "Equipped" : "Equip", systemImage: equipped ? "checkmark.circle.fill" : "scope")
                        .labelStyle(.titleAndIcon)
                }
                .help(equipped ? "New captures go here. Click to go back to auto-sort." : "Send every new capture to this pack")
                Menu { PackMenu(pack: pack, actions: actions) } label: {
                    Label("More", systemImage: "ellipsis")
                }
                .help("Copy for Claude, save progress, share, rename and more")
            }
        }
    }

    /// The captures as cards or rows, newest first, with saved progress on top.
    private var captureScroll: some View {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: DS.S.l) {
                        CheckpointCard(pack: pack, onSave: { actions.saveProgress(pack.id) },
                                       onCopyResume: { cp in actions.copyResume(pack.id, cp) })
                        if pack.captures.isEmpty {
                            EmptyState(symbol: "tray",
                                       title: "Nothing in \(pack.name) yet",
                                       message: "Select text in any app, then press ⌥C. You can also circle something on screen with \(DoubleTapDetector.Key.current.symbol), or drop files here.")
                        } else if shown.isEmpty {
                            EmptyState(symbol: "line.3.horizontal.decrease.circle", title: "No \(state.filter.title.lowercased()) in this pack",
                                       message: "Other kinds of captures are hidden by the filter.") {
                                Button("Show all") { state.filter = .all }.buttonStyle(.dsSecondary)
                            }
                        } else if state.layout == .grid {
                            LazyVGrid(columns: [GridItem(.adaptive(minimum: Self.tileMin, maximum: 320), spacing: Self.spacing, alignment: .top)],
                                      alignment: .leading, spacing: Self.spacing) {
                                ForEach(shown) { c in CaptureTile(capture: c, pack: pack).id(c.id) }
                            }
                            .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { gridWidth = $0 }
                        } else {
                            CaptureList(captures: shown, pack: pack)
                        }
                    }
                    .padding(DS.S.xl)
                    .frame(maxWidth: 1200, alignment: .leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .focusable()
                .focusEffectDisabled()
                .focused($gridFocused)
                .onKeyPress(.leftArrow) { step(-1, proxy); return .handled }
                .onKeyPress(.rightArrow) { step(1, proxy); return .handled }
                .onKeyPress(.upArrow) { step(-columns, proxy); return .handled }
                .onKeyPress(.downArrow) { step(columns, proxy); return .handled }
                .onKeyPress(.escape) {
                    guard state.selectedCapture != nil else { return .ignored }
                    state.selectedCapture = nil
                    return .handled
                }
                .onKeyPress(.return) {
                    guard let c = shown.first(where: { $0.id == state.selectedCapture }) else { return .ignored }
                    CaptureOpener.open(c, store: store)
                    return .handled
                }
            }
    }

    /// "12 captures · 3 sources · updated 2 hours ago · wheel slot 2"
    private var metaLine: String {
        let sources = Set(pack.captures.compactMap(\.host)).count
        var meta = ["\(pack.captures.count) capture\(pack.captures.count == 1 ? "" : "s")"]
        if pack.isStyle { meta.insert("Writing style", at: 0) }
        if sources > 0 { meta.append("\(sources) source\(sources == 1 ? "" : "s")") }
        meta.append("updated " + pack.updated.formatted(.relative(presentation: .named)))
        if let slot = store.wheelSlots.firstIndex(of: pack.id) { meta.append("wheel slot \(slot + 1)") }
        return meta.joined(separator: " · ")
    }

    private var columns: Int {
        state.layout == .list ? 1 : max(1, Int((gridWidth + Self.spacing) / (Self.tileMin + Self.spacing)))
    }

    private func step(_ d: Int, _ proxy: ScrollViewProxy) {
        let list = shown
        guard !list.isEmpty else { return }
        guard let i = list.firstIndex(where: { $0.id == state.selectedCapture }) else {
            state.selectedCapture = (d > 0 ? list.first : list.last)?.id
            return
        }
        let next = list[min(max(i + d, 0), list.count - 1)]
        state.selectedCapture = next.id
        withAnimation(.easeOut(duration: 0.12)) { proxy.scrollTo(next.id) }
    }

    /// What kind of captures to show and how (cards, list or map), then where the pack is kept up to date from.
    private var header: some View {
        let kinds = LibraryState.KindFilter.allCases.filter { k in k == .all || pack.captures.contains(where: k.matches) }
        return VStack(alignment: .leading, spacing: 12) {
            if !pack.captures.isEmpty {
                HStack(spacing: DS.S.s) {
                    if kinds.count > 2, state.layout != .graph { FilterBar(kinds: kinds, selection: $state.filter) }
                    Spacer(minLength: DS.S.s)
                    LayoutToggle(layout: $state.layout)
                }
            }
            if pack.isStyle {
                StatusLine(tone: .info, text: "Drafts sound like what's in here, and never take facts from it. Scoop emails and messages you wrote.")
            }
            SourcesStrip(pack: pack, actions: actions)
        }
    }
}

/// The folders, repos, pages and threads that keep this pack up to date, each with when it last updated.
private struct SourcesStrip: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var sync: SourceSync
    let pack: Pack
    let actions: LibraryActions

    var body: some View {
        let list = store.sources(for: pack.id)
        if !list.isEmpty {
            TimelineView(.periodic(from: .now, by: 60)) { ctx in
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        Label("Live", systemImage: "arrow.triangle.2.circlepath").font(.system(size: 11, weight: .semibold)).foregroundStyle(DS.text2)
                        ForEach(list) { s in chip(s, now: ctx.date) }
                        addMenu
                    }
                    .padding(.vertical, 1)
                }
            }
        }
    }

    private func chip(_ s: PackSource, now: Date) -> some View {
        let st = s.status(now: now)
        return Menu {
            Text("\(s.kindTitle): \(s.kind == .folder ? (s.location as NSString).abbreviatingWithTildeInPath : s.location)")
            Text(st.text)
            Divider()
            if !s.updatesWhenOpen { Button("Update Now") { actions.syncSource(pack.id, s.id) } }
            Button(s.kind == .folder ? "Show in Finder" : "Open") { Self.open(s) }
            Divider()
            Button("Stop Updating, Keep Its Notes") { actions.removeSource(pack.id, s.id, false) }
            Button("Remove It and Its Notes", role: .destructive) { actions.removeSource(pack.id, s.id, true) }
        } label: {
            HStack(spacing: 5) {
                if sync.syncing.contains(s.id) { ProgressView().controlSize(.mini) } else {
                    Image(systemName: st.stale ? "exclamationmark.triangle.fill" : s.symbol)
                        .foregroundStyle(st.stale ? DS.warning : DS.text2)
                }
                Text(s.title).foregroundStyle(DS.text).lineLimit(1).frame(maxWidth: 170, alignment: .leading).fixedSize()
                Text(st.text).foregroundStyle(st.stale ? DS.warning : DS.text3).lineLimit(1).frame(maxWidth: 230, alignment: .leading).fixedSize()
            }
            .font(.dsMeta)
            .padding(.horizontal, 8).padding(.vertical, 4)
            .background(Capsule().fill(DS.well))
            .overlay(Capsule().strokeBorder(st.stale ? DS.warning.opacity(0.5) : DS.line, lineWidth: 0.5))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(st.text)
        .accessibilityLabel("\(s.kindTitle) \(s.title), \(st.text)")
    }

    private var addMenu: some View {
        Menu {
            Button("A Folder…") { actions.addSource(.folder, pack.id) }
            Button("A GitHub Repo…") { actions.addSource(.github, pack.id) }
            Button("A Notion Page…") { actions.addSource(.notion, pack.id) }
            Button("A Web Page or Email Thread…") { actions.addSource(.web, pack.id) }
        } label: {
            Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(DS.text2)
                .frame(width: 22, height: 22).background(Circle().fill(DS.well))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("Keep this pack updated from another source")
        .accessibilityLabel("Add a source")
    }

    @MainActor
    static func open(_ s: PackSource) {
        switch s.kind {
        case .folder: NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.location)])
        case .github: if let u = URL(string: "https://github.com/" + s.location) { NSWorkspace.shared.open(u) }
        case .mail: if let u = NSWorkspace.shared.urlForApplication(withBundleIdentifier: "com.apple.mail") { NSWorkspace.shared.open(u) }
        default: if let u = URL(string: s.location) { NSWorkspace.shared.open(u) }
        }
    }
}

/// "Live link · 3 joined" for packs you share; "Joined · synced 2 min ago" for packs you added from a link.
private struct ShareStatus: View {
    @EnvironmentObject var shares: SharedPacks
    let pack: Pack
    let actions: LibraryActions
    @State private var confirmStop = false

    var body: some View {
        if let s = shares.shared[pack.id] {
            Menu {
                Button("Copy Link") { copy(s.url) }
                Button("Open Pack Page") { URL(string: s.url).map { _ = NSWorkspace.shared.open($0) } }
                Button("Review What's Shared…") { actions.safeShare(pack.id) }
                Divider()
                Button("Stop Sharing…", role: .destructive) { confirmStop = true }
            } label: {
                label(symbol: "link", title: "Live link",
                      detail: [s.joins > 0 ? "\(s.joins) joined" : nil, s.held.isEmpty ? nil : "\(s.held.count) waiting"].compactMap { $0 },
                      warn: !s.held.isEmpty || shares.lastError[pack.id] != nil)
            }
            .menuStyle(.button)
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(shares.lastError[pack.id] ?? (s.held.isEmpty ? "Anyone with the link can see this pack and add it to Shapr"
                                                                : "\(s.held.count) new capture(s) wait for a privacy check before they're shared"))
            .confirmationDialog("Stop sharing \(pack.name)?", isPresented: $confirmStop) {
                Button("Stop Sharing", role: .destructive) { Task { await shares.stopSharing(pack.id) } }
            } message: {
                Text("The link stops working. People who added the pack keep the copy they have, but get no more updates.")
            }
        } else if let sub = shares.subscribed[pack.id] {
            Menu {
                Button("Sync Now") { Task { try? await shares.sync(pack.id) } }
                Button("Open Pack Page") { NSWorkspace.shared.open(ShareServer.pageURL(sub.id)) }
                Divider()
                Button("Stop Syncing") { shares.leave(pack.id) }
            } label: {
                label(symbol: "arrow.triangle.2.circlepath", title: "Joined",
                      detail: [sub.lastSync.map { "synced " + $0.formatted(.relative(presentation: .named)) }].compactMap { $0 },
                      warn: shares.lastError[pack.id] != nil)
            }
            .menuStyle(.button)
            .buttonStyle(DSButtonStyle(kind: .secondary))
            .menuIndicator(.hidden)
            .fixedSize()
            .help(shares.lastError[pack.id] ?? "Added from a shared link. New captures arrive as they're shared.")
        }
    }

    private func label(symbol: String, title: String, detail: [String], warn: Bool) -> some View {
        HStack(spacing: 5) {
            if shares.busy.contains(pack.id) { ProgressView().controlSize(.mini) }
            else { Image(systemName: warn ? "exclamationmark.triangle" : symbol).foregroundStyle(warn ? DS.warning : DS.text2) }
            Text(title)
            if !detail.isEmpty { Text("· " + detail.joined(separator: " · ")).foregroundStyle(DS.text2) }
        }
    }

    private func copy(_ s: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
    }
}

private struct FilterBar: View {
    let kinds: [LibraryState.KindFilter]
    @Binding var selection: LibraryState.KindFilter
    var body: some View {
        HStack(spacing: 2) {
            ForEach(kinds) { k in
                Button(k.title) { selection = k }
                    .buttonStyle(SegmentStyle(on: selection == k))
                    .accessibilityAddTraits(selection == k ? .isSelected : [])
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.well))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
    }
}

private struct LayoutToggle: View {
    @Binding var layout: LibraryState.Layout
    var body: some View {
        HStack(spacing: 2) {
            Button { layout = .grid } label: { Image(systemName: "square.grid.2x2") }
                .buttonStyle(SegmentStyle(on: layout == .grid)).help("Cards").accessibilityLabel("Cards")
            Button { layout = .list } label: { Image(systemName: "list.bullet") }
                .buttonStyle(SegmentStyle(on: layout == .list)).help("List").accessibilityLabel("List")
            Button { layout = .graph } label: { Image(systemName: "point.3.connected.trianglepath.dotted") }
                .buttonStyle(SegmentStyle(on: layout == .graph)).help("Map: what's in the pack and what belongs together")
                .accessibilityLabel("Map")
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous).fill(DS.well))
        .overlay(RoundedRectangle(cornerRadius: 7, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
    }
}

private struct SegmentStyle: ButtonStyle {
    let on: Bool
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 11.5, weight: on ? .semibold : .regular))
            .lineLimit(1)
            .fixedSize()
            .foregroundStyle(on ? DS.text : DS.text2)
            .padding(.horizontal, 8)
            .frame(minHeight: 20)
            .background(RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(on ? DS.panel : .clear)
                .shadow(color: .black.opacity(on ? 0.08 : 0), radius: 1, y: 0.5))
            .contentShape(Rectangle())
    }
}

// MARK: - Cards (Paste / mymind style: content first, then where it came from)

struct CaptureTile: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let capture: Capture
    let pack: Pack
    var showPack = false
    @State private var hovering = false

    var body: some View {
        let selected = state.selectedCapture == capture.id
        VStack(alignment: .leading, spacing: 0) {
            preview
            VStack(alignment: .leading, spacing: 5) {
                if showPack { PackChip(pack: pack) }
                if let t = titleLine {
                    Text(t).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 6) {
                    SourceBadge(capture: capture, size: 16)
                    Text(capture.sourceSummary).font(.dsMeta).foregroundStyle(DS.text2).lineLimit(1)
                    Spacer(minLength: 4)
                    Text(capture.capturedAt.formatted(.relative(presentation: .named)))
                        .font(.dsMeta).foregroundStyle(DS.text3).lineLimit(1)
                }
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
        }
        .background(DS.panel)
        .clipShape(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous)
            .strokeBorder(selected ? DS.accent : (hovering ? DS.text3.opacity(0.5) : DS.line), lineWidth: selected ? 2 : (hovering ? 1 : 0.5)))
        .overlay(alignment: .topTrailing) {
            if hovering { CardActions(capture: capture).padding(6).transition(.opacity) }
        }
        .animation(.easeOut(duration: 0.12), value: hovering)
        .onHover { hovering = $0 }
        .contentShape(Rectangle())
        .onTapGesture(count: 2) { CaptureOpener.open(capture, store: store) }
        .onTapGesture { state.selectedCapture = selected ? nil : capture.id }
        .draggable(capture.id.uuidString)
        .contextMenu { CaptureMenu(capture: capture, pack: pack) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(capture.kindLabel): \(capture.displayTitle), from \(capture.sourceSummary)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(named: "Open source") { CaptureOpener.open(capture, store: store) }
    }

    /// A title only when it adds something the preview doesn't already show.
    private var titleLine: String? {
        if capture.file != nil { return nil }
        if let t = capture.title?.nonEmpty { return t }
        return capture.image != nil ? "Screenshot" : nil
    }

    @ViewBuilder
    private var preview: some View {
        switch CapturePreview.of(capture, store: store) {
        case .image(let img):
            ZStack {
                DS.well
                Image(nsImage: img).resizable().interpolation(.high).aspectRatio(contentMode: .fit).padding(8)
            }
            .frame(height: 150)
            .frame(maxWidth: .infinity)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.line).frame(height: 0.5) }
        case .file(let name, let ext):
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 10) {
                    FileBadge(ext: ext, size: 34)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(name).font(.system(size: 12.5, weight: .semibold)).foregroundStyle(DS.text).lineLimit(2)
                        Text(fileMeta(ext)).font(.dsMeta).foregroundStyle(DS.text2)
                    }
                    Spacer(minLength: 0)
                }
                let excerpt = capture.text.trimmingCharacters(in: .whitespacesAndNewlines)
                if !excerpt.isEmpty, excerpt != name {
                    Text(excerpt)
                        .font(.system(size: 11.5, design: FileTypes.text.contains(ext) ? .monospaced : .default))
                        .foregroundStyle(DS.text2)
                        .lineLimit(4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(12)
            .overlay(alignment: .bottom) { Rectangle().fill(DS.line).frame(height: 0.5) }
        case .quote:
            Text(capture.text.trimmingCharacters(in: .whitespacesAndNewlines))
                .font(capture.looksLikeCode ? .system(size: 11.5, design: .monospaced) : .system(size: 13))
                .foregroundStyle(DS.text)
                .lineSpacing(2)
                .lineLimit(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 12).padding(.top, 12).padding(.bottom, 2)
        }
    }

    private func fileMeta(_ ext: String) -> String {
        let size = store.fileURL(for: capture).flatMap { try? $0.resourceValues(forKeys: [.fileSizeKey]).fileSize }
            .map { ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) }
        return [ext.uppercased(), size].compactMap { $0 }.joined(separator: " · ")
    }
}

/// Copy and Open, shown on hover.
private struct CardActions: View {
    @EnvironmentObject var store: PackStore
    let capture: Capture
    var body: some View {
        HStack(spacing: 0) {
            IconButton(symbol: "doc.on.doc", help: "Copy text", size: 24) { CaptureOpener.copy(capture) }
            if capture.url != nil || capture.file != nil {
                IconButton(symbol: "arrow.up.right", help: "Open source", size: 24) { CaptureOpener.open(capture, store: store) }
            }
        }
        .padding(2)
        .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.panel))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.08), radius: 3, y: 1)
    }
}

/// Dense rows for packs full of text.
private struct CaptureList: View {
    let captures: [Capture]
    let pack: Pack
    var body: some View {
        LazyVStack(spacing: 0) {
            ForEach(Array(captures.enumerated()), id: \.element.id) { i, c in
                if i > 0 { Rectangle().fill(DS.line).frame(height: 0.5).padding(.leading, 54) }
                CaptureRow(capture: c, pack: pack).id(c.id)
            }
        }
        .padding(4)
        .background(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).fill(DS.panel))
        .overlay(RoundedRectangle(cornerRadius: DS.R.card, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
    }
}

private struct CaptureRow: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let capture: Capture
    let pack: Pack
    @State private var hovering = false

    var body: some View {
        let selected = state.selectedCapture == capture.id
        HStack(spacing: 10) {
            thumb.frame(width: 36, height: 36)
            VStack(alignment: .leading, spacing: 2) {
                Text(capture.displayTitle).font(.system(size: 13, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                Text(capture.text.singleLine).font(.system(size: 11.5)).foregroundStyle(DS.text2).lineLimit(1)
            }
            Spacer(minLength: 8)
            Text(capture.sourceSummary).font(.dsMeta).foregroundStyle(DS.text3).lineLimit(1)
                .frame(maxWidth: 190, alignment: .trailing)
            Text(capture.capturedAt.formatted(.relative(presentation: .named))).font(.dsMeta).foregroundStyle(DS.text3)
                .lineLimit(1).frame(width: 84, alignment: .trailing)
        }
        .padding(.horizontal, 8)
        .frame(height: 50)
        .background(RoundedRectangle(cornerRadius: 7, style: .continuous)
            .fill(selected ? DS.accentSoft : (hovering ? DS.hover : .clear)))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
        .onTapGesture(count: 2) { CaptureOpener.open(capture, store: store) }
        .onTapGesture { state.selectedCapture = selected ? nil : capture.id }
        .draggable(capture.id.uuidString)
        .contextMenu { CaptureMenu(capture: capture, pack: pack) }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(capture.kindLabel): \(capture.displayTitle), from \(capture.sourceSummary)")
        .accessibilityAddTraits(selected ? [.isButton, .isSelected] : .isButton)
    }

    @ViewBuilder
    private var thumb: some View {
        switch CapturePreview.of(capture, store: store) {
        case .image(let img):
            ZStack { DS.well; Image(nsImage: img).resizable().aspectRatio(contentMode: .fit).padding(2) }
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                .overlay(RoundedRectangle(cornerRadius: 6, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
        case .file(_, let ext): FileBadge(ext: ext, size: 28)
        case .quote: SourceBadge(capture: capture, size: 30)
        }
    }
}

/// Right-click menu for a capture.
private struct CaptureMenu: View {
    @EnvironmentObject var store: PackStore
    let capture: Capture
    let pack: Pack
    var body: some View {
        Button("Copy Text") { CaptureOpener.copy(capture) }
        if let u = capture.url.flatMap(URL.init(string:)) { Button("Open Source") { NSWorkspace.shared.open(u) } }
        if let f = store.fileURL(for: capture) { Button("Show File in Finder") { NSWorkspace.shared.activateFileViewerSelecting([f]) } }
        Menu("Move To") {
            ForEach(store.packs.filter { $0.id != pack.id }) { p in
                Button(p.label) { store.moveCapture(capture.id, to: p.id) }
            }
        }
        Divider()
        Button("Move to Trash", role: .destructive) { store.removeCapture(capture.id) }
    }
}

@MainActor
enum CaptureOpener {
    static func open(_ c: Capture, store: PackStore) {
        if let f = store.fileURL(for: c) { NSWorkspace.shared.open(f) }
        else if let u = c.url.flatMap(URL.init(string:)) { NSWorkspace.shared.open(u) }
        else if let i = store.imageURL(for: c) { NSWorkspace.shared.open(i) }
    }

    static func copy(_ c: Capture) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(c.text, forType: .string)
    }
}

extension Capture {
    /// Rough check so code reads in a monospaced font.
    var looksLikeCode: Bool {
        let lines = text.split(whereSeparator: \.isNewline)
        guard lines.count >= 2 else { return false }
        let codey = lines.filter { l in
            l.hasPrefix("    ") || l.hasPrefix("\t") || l.hasSuffix(";") || l.hasSuffix("{") || l.hasSuffix("}")
                || l.contains("func ") || l.contains("def ") || l.contains("SELECT ") || l.contains("=>")
        }
        return Double(codey.count) / Double(lines.count) >= 0.4
    }
}

// MARK: - Preview panel

/// Everything about one capture: full content, where it came from, and what you can do with it.
private struct CaptureInspector: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let capture: Capture
    let pack: Pack

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Text(capture.kindLabel).font(.system(size: 11.5, weight: .semibold)).foregroundStyle(DS.text2)
                PackChip(pack: pack)
                Spacer()
                IconButton(symbol: "xmark", help: "Close preview (esc)", size: 24) { state.selectedCapture = nil }
            }
            .padding(.horizontal, DS.S.m)
            .padding(.top, 14)
            .padding(.bottom, 10)
            Rectangle().fill(DS.line).frame(height: 0.5)

            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text(capture.displayTitle).font(.system(size: 15, weight: .semibold)).foregroundStyle(DS.text)
                            .textSelection(.enabled).fixedSize(horizontal: false, vertical: true)
                        if let u = capture.url.flatMap(URL.init(string:)) {
                            Link(destination: u) {
                                Label(capture.host ?? u.absoluteString, systemImage: u.isFileURL ? "doc" : "link")
                                    .font(.dsCallout).lineLimit(1)
                            }
                            .foregroundStyle(DS.accent)
                        }
                    }

                    if let url = store.imageURL(for: capture), let img = NSImage(contentsOf: url) {
                        let h = min(320, max(120, (LibraryView.inspectorWidth - 32) * img.size.height / max(img.size.width, 1)))
                        FittedImage(image: img, height: h)
                            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
                            .onTapGesture { NSWorkspace.shared.open(url) }
                            .help("Open the screenshot")
                    }
                    if let url = store.fileURL(for: capture) {
                        FileRow(url: url, originalName: capture.title)
                    }
                    if capture.image != nil && capture.text.nonEmpty == nil {
                        StatusLine(tone: .info, text: "No text was found in this screenshot. The image is saved.")
                    }
                    if let text = capture.text.nonEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            if capture.image != nil { SectionLabel(title: "Text in the screenshot") }
                            Text(text)
                                .font(capture.looksLikeCode ? .system(size: 12, design: .monospaced) : .dsBody)
                                .foregroundStyle(DS.text)
                                .lineSpacing(3)
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }

                    Grid(alignment: .leading, horizontalSpacing: 12, verticalSpacing: 6) {
                        meta("Captured", capture.capturedAt.formatted(date: .abbreviated, time: .shortened))
                        if let a = capture.appName { meta("From", a) }
                        if let u = capture.url { meta("Link", u) }
                        meta("Words", "\(capture.text.split { $0.isWhitespace || $0.isNewline }.count)")
                    }
                    .padding(.top, 4)
                }
                .padding(DS.S.l)
            }

            Rectangle().fill(DS.line).frame(height: 0.5)
            HStack(spacing: 6) {
                if capture.url != nil || capture.file != nil {
                    Button { CaptureOpener.open(capture, store: store) } label: { Label("Open source", systemImage: "arrow.up.right") }
                        .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                }
                Button { CaptureOpener.copy(capture) } label: { Label("Copy", systemImage: "doc.on.doc") }
                    .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                Menu {
                    ForEach(store.packs.filter { $0.id != pack.id }) { p in
                        Button(p.label) { store.moveCapture(capture.id, to: p.id); state.selectedCapture = nil }
                    }
                } label: {
                    HStack(spacing: 3) { Text("Move"); Image(systemName: "chevron.down").font(.system(size: 8, weight: .semibold)) }
                }
                .menuStyle(.button)
                .buttonStyle(DSButtonStyle(kind: .secondary, small: true))
                .menuIndicator(.hidden)
                .fixedSize()
                Spacer()
                IconButton(symbol: "trash", help: "Move to Trash", size: 24) {
                    state.selectedCapture = nil
                    store.removeCapture(capture.id)
                }
            }
            .padding(10)
        }
        .background(DS.panel)
    }

    private func meta(_ k: String, _ v: String) -> some View {
        GridRow {
            Text(k).font(.dsMeta).foregroundStyle(DS.text3)
            Text(v).font(.dsMeta).foregroundStyle(DS.text2).lineLimit(2).truncationMode(.middle).textSelection(.enabled)
        }
    }
}

/// An attached file: click to open it, right-click to show it in Finder.
private struct FileRow: View {
    let url: URL
    let originalName: String?

    var body: some View {
        let ext = url.pathExtension.lowercased()
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize).map {
            ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file)
        } ?? ""
        Button { NSWorkspace.shared.open(url) } label: {
            HStack(spacing: 10) {
                FileBadge(ext: ext, size: 30)
                VStack(alignment: .leading, spacing: 1) {
                    Text(originalName ?? url.lastPathComponent).font(.system(size: 12.5, weight: .medium)).foregroundStyle(DS.text).lineLimit(1)
                    Text([ext.uppercased(), size].filter { !$0.isEmpty }.joined(separator: " · ")).font(.dsMeta).foregroundStyle(DS.text2)
                }
                Spacer(minLength: 0)
                Image(systemName: "arrow.up.right").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.text3)
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 8, style: .continuous).fill(DS.well))
            .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).strokeBorder(DS.line, lineWidth: 0.5))
        }
        .buttonStyle(.plain)
        .help("Open the file")
        .contextMenu {
            Button("Open") { NSWorkspace.shared.open(url) }
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
    }
}

// MARK: - Search

/// Matches across every pack while you type in the sidebar search field.
private struct SearchResultsView: View {
    @EnvironmentObject var store: PackStore
    @EnvironmentObject var state: LibraryState
    let query: String

    var body: some View {
        let terms = query.lowercased().split(whereSeparator: \.isWhitespace).map(String.init)
        let hits: [(Pack, Capture)] = store.packs.flatMap { p in
            p.captures.reversed().filter { c in
                let hay = [c.title ?? "", c.text, c.url ?? "", c.appName ?? ""].joined(separator: " ").lowercased()
                return terms.allSatisfy(hay.contains)
            }.map { (p, $0) }
        }
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Search").font(.system(size: 20, weight: .semibold))
                    Text(hits.isEmpty ? "No matches for “\(query)”" : "\(hits.count) match\(hits.count == 1 ? "" : "es") for “\(query)” in all packs")
                        .font(.dsMeta).foregroundStyle(DS.text2)
                }
                Spacer()
                Button("Clear search") { state.query = "" }.buttonStyle(DSButtonStyle(kind: .secondary, small: true))
            }
            .padding(.horizontal, DS.S.xl).padding(.top, 22).padding(.bottom, DS.S.m)
            Rectangle().fill(DS.line).frame(height: 0.5)
            ScrollView {
                if hits.isEmpty {
                    EmptyState(symbol: "magnifyingglass", title: "No matches for “\(query)”",
                               message: "Search looks at titles, text, links and app names in every pack. Try fewer or different words.") {
                        Button("Clear search") { state.query = "" }.buttonStyle(.dsSecondary)
                    }
                } else {
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 220, maximum: 320), spacing: 14, alignment: .top)],
                              alignment: .leading, spacing: 14) {
                        ForEach(hits, id: \.1.id) { p, c in CaptureTile(capture: c, pack: p, showPack: true) }
                    }
                    .padding(DS.S.xl)
                }
            }
        }
    }
}

// MARK: - Welcome and first run

/// Shown before you pick a pack: what's allowed, and one Scoop → Equip → Drop with your own content.
private struct WelcomeView: View {
    @EnvironmentObject var state: LibraryState
    @EnvironmentObject var store: PackStore
    let actions: LibraryActions

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: DS.S.xl) {
                // One thing to learn: hold a key and say it.
                VStack(alignment: .leading, spacing: 10) {
                    Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 44, height: 44)
                    HStack(spacing: 8) {
                        Text("Hold").font(.dsDisplay)
                        Keycap(keys: "⌥V").scaleEffect(1.5).padding(.horizontal, 8)
                        Text("and say what you want.").font(.dsDisplay)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel("Hold Option V and say what you want.")
                    Text("Shapr keeps what you save in packs, and uses them to answer, write and fill things in, in any app.")
                        .font(.dsBody).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
                }

                VStack(alignment: .leading, spacing: 0) {
                    ExampleRow(say: "Add this", does: "Saves what you're looking at to a pack")
                    Divider()
                    ExampleRow(say: "What does this mean?", does: "Answers from your screen and your packs")
                    Divider()
                    ExampleRow(say: "Draft a reply saying yes", does: "Writes it where you're typing, in your voice")
                    Divider()
                    ExampleRow(say: "Fill this form", does: "Fills it in from what you've saved")
                }
                .dsCard(padding: 0)

                // Only what still needs switching on. Nothing here once it's all allowed.
                if !state.axTrusted || !state.screenTrusted || !state.micAllowed {
                    VStack(alignment: .leading, spacing: DS.S.s) {
                        SectionLabel(title: "Switch these on once")
                        if !state.micAllowed {
                            PermissionRow(title: "Microphone", detail: "So Shapr can hear you. Speech becomes text on this Mac.", granted: false) {
                                if VoiceSettings.micStatus == .notDetermined {
                                    AVCaptureDevice.requestAccess(for: .audio) { _ in }
                                } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
                                    NSWorkspace.shared.open(url)
                                }
                            }
                        }
                        if !state.axTrusted {
                            PermissionRow(title: "Accessibility", detail: "So Shapr can read the text you select and type for you.", granted: false) {
                                CaptureService.requestTrust()
                                CaptureService.openAccessibilitySettings()
                            }
                        }
                        if !state.screenTrusted {
                            PermissionRow(title: "Screen Recording", detail: "So Shapr can see what you ask about. Reopen Shapr after allowing.", granted: false) {
                                ScreenCapture.requestPermission()
                                ScreenCapture.openSettings()
                            }
                        }
                    }
                }

                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 6) {
                        Text("Prefer keys?").font(.dsCallout).foregroundStyle(DS.text2)
                        Keycap(keys: "⌥C")
                        Text("saves what you selected,").font(.dsCallout).foregroundStyle(DS.text2)
                        Keycap(keys: "⌥S")
                        Text("switches packs.").font(.dsCallout).foregroundStyle(DS.text2)
                    }
                    if !store.packs.isEmpty {
                        Text("Pick a pack on the left to see what's inside.").font(.dsCallout).foregroundStyle(DS.text2)
                    }
                }
            }
            .padding(DS.S.xxl)
            .padding(.top, 12)
            .frame(maxWidth: 620, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// "Add this" · what it does. One line of the welcome screen.
private struct ExampleRow: View {
    let say: String
    let does: String

    var body: some View {
        HStack(spacing: DS.S.m) {
            Image(systemName: "waveform").font(.system(size: 12, weight: .medium)).foregroundStyle(DS.accent).frame(width: 18)
            Text("“\(say)”").font(.dsHeadline).foregroundStyle(DS.text)
            Spacer(minLength: DS.S.m)
            Text(does).font(.dsCallout).foregroundStyle(DS.text2).multilineTextAlignment(.trailing)
        }
        .padding(.horizontal, DS.S.l)
        .padding(.vertical, 11)
        .accessibilityElement(children: .combine)
    }
}

enum LibraryViewColors {
    static let sidebar = Color.dynamic(0xEFEDE7, 0x201F1D)
}

enum Onboarding {
    static let droppedKey = "onboardingDropped"
}

private struct PermissionRow: View {
    let title: String
    let detail: String
    let granted: Bool
    let open: () -> Void

    var body: some View {
        HStack(spacing: DS.S.m) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .font(.system(size: 16))
                .foregroundStyle(granted ? DS.success : DS.warning)
            VStack(alignment: .leading, spacing: 2) {
                Text(title + (granted ? " is on" : " is off")).font(.dsHeadline)
                Text(detail).font(.dsCallout).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: DS.S.s)
            if !granted {
                Button("Open Settings", action: open).buttonStyle(DSButtonStyle(kind: .primary, small: true))
            }
        }
        .dsCard()
        .accessibilityElement(children: .combine)
    }
}

