import AppKit
import ApplicationServices

enum SuggestionSettings {
    static let openedKey = "suggestOpenedFiles"
    static let downloadsKey = "suggestDownloads"
    static let neverKey = "suggestNeverFolders"
    static let askedKey = "suggestAskedFiles"

    static var opened: Bool {
        get { UserDefaults.standard.object(forKey: openedKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: openedKey) }
    }
    static var downloads: Bool {
        get { UserDefaults.standard.object(forKey: downloadsKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: downloadsKey) }
    }
    static var neverFolders: [String] {
        get { UserDefaults.standard.stringArray(forKey: neverKey) ?? [] }
        set { UserDefaults.standard.set(newValue, forKey: neverKey) }
    }
}

/// "You opened syllabus.pdf. Add it to 📚 History Essay?"
/// Asks only while you're working on a pack, only about documents and code, once per file, and
/// decides which pack fits on this Mac. Nothing is read into a pack until you click Add.
@MainActor
final class FileSuggester {
    enum Reason {
        case opened(app: String?)
        case downloaded
    }

    private let store: PackStore
    private let toast: ToastController
    private let sorter: Sorter
    private var timer: Timer?
    private var query: NSMetadataQuery?
    private var downloadsWatcher: PackWatcher?
    private var downloadsSeen: Set<String> = []
    private var lastFrontDoc: String?
    private var lastPrompt = Date.distantPast
    private var asked: [String]
    private var pending: Set<String> = []
    private let started = Date()

    init(store: PackStore, toast: ToastController, sorter: Sorter) {
        self.store = store
        self.toast = toast
        self.sorter = sorter
        asked = UserDefaults.standard.stringArray(forKey: SuggestionSettings.askedKey) ?? []
    }

    func start() {
        // The document in the front window (Preview, Word, Pages, Xcode, VS Code, Cursor…).
        timer = Timer.scheduledTimer(withTimeInterval: 1.5, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        // Files opened from Finder in apps that don't say which document they show.
        let q = NSMetadataQuery()
        q.searchScopes = [NSMetadataQueryUserHomeScope]
        q.predicate = NSPredicate(format: "kMDItemLastUsedDate >= %@", started as NSDate)
        NotificationCenter.default.addObserver(forName: .NSMetadataQueryDidUpdate, object: q, queue: .main) { [weak self] note in
            let items = ((note.userInfo?[NSMetadataQueryUpdateAddedItemsKey] as? [NSMetadataItem]) ?? [])
                + ((note.userInfo?[NSMetadataQueryUpdateChangedItemsKey] as? [NSMetadataItem]) ?? [])
            let paths = items.compactMap { $0.value(forAttribute: NSMetadataItemPathKey) as? String }
            MainActor.assumeIsolated {
                guard let self, SuggestionSettings.opened else { return }
                for p in paths { self.consider(URL(fileURLWithPath: p), reason: .opened(app: nil)) }
            }
        }
        q.start()
        query = q
    }

    // MARK: Sources

    private func tick() {
        guard CaptureService.isTrusted, !workingPacks().isEmpty else { return }
        if SuggestionSettings.downloads, downloadsWatcher == nil { startDownloadsWatcher() }
        guard SuggestionSettings.opened, let app = NSWorkspace.shared.frontmostApplication,
              app.bundleIdentifier != Bundle.main.bundleIdentifier else { return }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.3)
        guard let win: AXUIElement = FormScanner.attr(el, kAXFocusedWindowAttribute),
              let doc: String = FormScanner.attr(win, kAXDocumentAttribute),
              doc != lastFrontDoc, let url = URL(string: doc), url.isFileURL else { return }
        lastFrontDoc = doc
        consider(url, reason: .opened(app: app.localizedName))
    }

    /// Started only once you're working on a pack, so the "access Downloads" question comes at a sensible time.
    private func startDownloadsWatcher() {
        let dir = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        downloadsSeen = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        downloadsWatcher = PackWatcher(path: dir.path) { [weak self] in
            MainActor.assumeIsolated { self?.downloadsChanged(dir) }
        }
    }

    private func downloadsChanged(_ dir: URL) {
        guard SuggestionSettings.downloads else { return }
        let now = Set((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? [])
        let fresh = now.subtracting(downloadsSeen)
        downloadsSeen = now
        let partial: Set<String> = ["crdownload", "download", "part", "tmp", "partial"]
        for name in fresh where !name.hasPrefix(".") && !partial.contains((name as NSString).pathExtension.lowercased()) {
            let url = dir.appendingPathComponent(name)
            // Wait until it stops growing.
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                MainActor.assumeIsolated { self?.consider(url, reason: .downloaded) }
            }
        }
    }

    // MARK: Deciding

    /// Packs you're working on right now: the equipped one, the one auto-sort last used, and any
    /// pack you added to in the last two hours.
    func workingPacks() -> [Pack] {
        var ids: [UUID] = []
        if let eq = store.equippedPackID { ids.append(eq) }
        if let a = store.activePackID, store.isActive(a) { ids.append(a) }
        for p in store.packs where Date().timeIntervalSince(p.updated) < 2 * 3600 { ids.append(p.id) }
        var seen = Set<UUID>()
        return ids.filter { seen.insert($0).inserted }.compactMap { store.pack($0) }.prefix(5).map { $0 }
    }

    /// Plain rules about which files are worth asking about at all.
    static func isCandidate(_ url: URL, shaprRoot: URL, neverFolders: [String], home: URL = FileManager.default.homeDirectoryForCurrentUser) -> Bool {
        let path = url.standardizedFileURL.path
        let ext = url.pathExtension.lowercased()
        guard FileTypes.isAllowed(ext: ext), !FileTypes.images.contains(ext) else { return false }
        guard !path.hasPrefix(shaprRoot.standardizedFileURL.path + "/") else { return false }
        if url.pathComponents.contains(where: { $0.hasPrefix(".") && $0 != "." }) { return false }
        let skip = ["/System/", "/Library/", "/Applications/", "/private/", "/var/", "/tmp/", "/opt/", "/usr/",
                    home.path + "/Library/", "/node_modules/", "/DerivedData/", ".app/", "/Pods/", "/.build/"]
        if skip.contains(where: { path.hasPrefix($0) || path.contains($0) }) { return false }
        if neverFolders.contains(where: { path.hasPrefix($0.hasSuffix("/") ? $0 : $0 + "/") }) { return false }
        return true
    }

    func consider(_ url: URL, reason: Reason) {
        let path = url.standardizedFileURL.path
        guard !asked.contains(path), !pending.contains(path),
              Self.isCandidate(url, shaprRoot: store.root, neverFolders: SuggestionSettings.neverFolders) else { return }
        let size = (try? url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey]))
        guard size?.isRegularFile == true, let bytes = size?.fileSize, bytes > 0, bytes <= FileTypes.maxBytes else { return }
        // Already in a pack?
        let fileURL = url.standardizedFileURL.absoluteString
        guard !store.packs.contains(where: { $0.captures.contains { $0.url == fileURL } }) else { return }
        let packs = workingPacks()
        guard !packs.isEmpty, Date().timeIntervalSince(lastPrompt) > 60 else { return }

        pending.insert(path)
        Task {
            defer { pending.remove(path) }
            let target: Pack?
            if let eq = store.pack(store.equippedPackID) {
                target = eq // you said "everything goes here"
            } else {
                // Which working pack does it fit? Decided on this Mac, from the name and the start of the text.
                let text = await FileText.extract(url)
                let probe = CaptureDraft(text: url.lastPathComponent + "\n" + String(text.prefix(1500)), title: url.lastPathComponent)
                let summaries = store.summaries(limit: 50).filter { s in packs.contains { $0.id == s.id } }
                let decision = await sorter.decide(probe, packs: summaries, allowClaude: false)
                target = store.pack(decision.packID)
            }
            guard let target else { return }
            remember(path)
            lastPrompt = Date()
            showPrompt(url, pack: target, reason: reason)
        }
    }

    private func remember(_ path: String) {
        asked.append(path)
        if asked.count > 600 { asked.removeFirst(asked.count - 600) }
        UserDefaults.standard.set(asked, forKey: SuggestionSettings.askedKey)
    }

    // MARK: Prompt

    private func showPrompt(_ url: URL, pack: Pack, reason: Reason) {
        let why: String
        switch reason {
        case .opened(let app): why = app.map { "You opened it in \($0)" } ?? "You just opened it"
        case .downloaded: why = "Just downloaded"
        }
        let others = store.packs.filter { $0.id != pack.id }.prefix(8).map { p in
            (p.label, { [weak self] () -> Void in self?.add(url, to: p.id) })
        }
        let folder = url.deletingLastPathComponent()
        var actions = [ToastAction(title: "Add", style: .primary) { [weak self] in self?.add(url, to: pack.id) }]
        if !others.isEmpty { actions.append(ToastAction(title: "Other", style: .menu(others))) }
        actions.append(ToastAction(title: "Not here") {
            var never = SuggestionSettings.neverFolders
            if !never.contains(folder.path) { never.append(folder.path) }
            SuggestionSettings.neverFolders = never
        })
        toast.show(ToastContent(icon: .symbol(CapturePreview.fileSymbol(url.pathExtension.lowercased())),
                                title: url.lastPathComponent,
                                subtitle: "\(why) · \"Not here\" stops asking about \(folder.lastPathComponent)",
                                actions: actions,
                                preview: .file(name: url.lastPathComponent, ext: url.pathExtension.lowercased()),
                                pack: pack, eyebrow: "Add to"), duration: 9)
    }

    private func add(_ url: URL, to packID: UUID) {
        Task {
            guard let d = await FileImporter.draft(file: url, name: url.lastPathComponent, sourceURL: url.standardizedFileURL,
                                                   appName: "Opened file"),
                  let c = store.add(d, to: packID), let p = store.pack(packID) else { return }
            store.markActive(packID)
            toast.show(ToastContent(icon: .pack(p), title: "Added to \(p.name)",
                                    subtitle: url.lastPathComponent,
                                    actions: [ToastAction(title: "Undo") { [weak self] in self?.store.removeCapture(c.id, toTrash: false) }]),
                       duration: 3)
        }
    }

    static func emoji(for ext: String) -> String {
        switch ext.lowercased() {
        case "pdf": return "📕"
        case "doc", "docx", "pages", "rtf", "odt": return "📝"
        case "ppt", "pptx", "key": return "📊"
        case "xlsx", "numbers", "csv", "tsv": return "📈"
        case "sql": return "🗄️"
        case "md", "markdown", "txt": return "📄"
        default: return FileTypes.text.contains(ext.lowercased()) ? "💻" : "📄"
        }
    }
}
