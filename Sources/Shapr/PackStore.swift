import Foundation
import AppKit

/// Owns the packs on disk. Layout:
///
///     ~/Shapr/Packs/<pack-slug>/pack.json        name, emoji, id
///     ~/Shapr/Packs/<pack-slug>/<capture>.md     one file per capture
///     ~/Shapr/Packs/<pack-slug>/.shapr/          redaction choices for Safe Share
@MainActor
final class PackStore: ObservableObject {
    @Published private(set) var packs: [Pack] = []
    /// The pack chosen on the wheel. nil = auto-sort.
    @Published private(set) var equippedPackID: UUID?
    /// Six inventory slots on the wheel, stable so muscle memory works.
    @Published private(set) var wheelSlots: [UUID?] = Array(repeating: nil, count: 6)

    /// The pack auto-sort last confirmed. Similar captures go here without asking.
    private(set) var activePackID: UUID?
    private var activeAt: Date?

    /// Name of a pack made with ＋ before it has any captures.
    static let placeholderName = "New Pack"

    let root: URL
    var packsDir: URL { root.appendingPathComponent("Packs", isDirectory: true) }
    var sharedDir: URL { root.appendingPathComponent("Shared", isDirectory: true) }

    private let defaults: UserDefaults
    /// False for the MCP server process: it reads the wheel and equipped pack but never changes them.
    private let persistPrefs: Bool
    private let fm = FileManager.default
    private var sourceCache: [UUID: [PackSource]] = [:]

    private enum Keys {
        static let equipped = "equippedPackID"
        static let slots = "wheelSlots"
    }

    init(root: URL, defaults: UserDefaults = .standard, persistPrefs: Bool = true) {
        self.root = root
        self.defaults = defaults
        self.persistPrefs = persistPrefs
        try? fm.createDirectory(at: packsDir, withIntermediateDirectories: true)
        load()
    }

    nonisolated static func defaultRoot() -> URL {
        if let env = ProcessInfo.processInfo.environment["SHAPR_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: (env as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Shapr", isDirectory: true)
    }

    // MARK: Loading

    func load() {
        sourceCache = [:]
        let dirs = (try? fm.contentsOfDirectory(at: packsDir, includingPropertiesForKeys: [.isDirectoryKey],
                                                options: [.skipsHiddenFiles])) ?? []
        packs = dirs.filter(isDirectory).compactMap(loadPack)
        assignHues()
        sortPacks()

        if let s = defaults.string(forKey: Keys.equipped), let id = UUID(uuidString: s), pack(id) != nil {
            equippedPackID = id
        } else {
            equippedPackID = nil
        }

        let saved = defaults.stringArray(forKey: Keys.slots) ?? []
        var slots: [UUID?] = (0..<6).map { i in
            guard i < saved.count, let id = UUID(uuidString: saved[i]), pack(id) != nil else { return nil }
            return id
        }
        for p in packs where !slots.contains(p.id) {
            guard let i = slots.firstIndex(where: { $0 == nil }) else { break }
            slots[i] = p.id
        }
        wheelSlots = slots
        saveSlots()
    }

    private func isDirectory(_ url: URL) -> Bool {
        (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true
    }

    private func loadPack(at dir: URL) -> Pack? {
        let metaURL = dir.appendingPathComponent("pack.json")
        let meta: PackMeta
        if let data = try? Data(contentsOf: metaURL), let m = try? Self.decoder.decode(PackMeta.self, from: data) {
            meta = m
        } else {
            // A folder someone made by hand: adopt it as a pack.
            let name = dir.lastPathComponent.replacingOccurrences(of: "-", with: " ").capitalized
            meta = PackMeta(id: UUID(), name: name, emoji: nil, created: Date(), autoNamed: false)
            writeMeta(meta, in: dir)
        }

        var captures: [Capture] = []
        let files = (try? fm.contentsOfDirectory(at: dir, includingPropertiesForKeys: [.creationDateKey],
                                                 options: [.skipsHiddenFiles])) ?? []
        for f in files where f.pathExtension.lowercased() == "md" && !f.lastPathComponent.contains(".file.") {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            if let c = CaptureFile.parse(s, fileName: f.lastPathComponent) {
                captures.append(c)
            } else if let text = s.nonEmpty {
                // A plain Markdown file dropped into the folder: give it an id so it can be moved and shared.
                let created = (try? f.resourceValues(forKeys: [.creationDateKey]).creationDate) ?? Date()
                let c = Capture(id: UUID(), text: text, capturedAt: created, appName: nil, bundleID: nil,
                                title: f.deletingPathExtension().lastPathComponent, url: nil,
                                fileName: f.lastPathComponent)
                try? CaptureFile.serialize(c).write(to: f, atomically: true, encoding: .utf8)
                captures.append(c)
            }
        }
        captures.sort { $0.capturedAt < $1.capturedAt }
        return Pack(meta: meta, folder: dir, captures: captures)
    }

    // MARK: Queries

    func pack(_ id: UUID?) -> Pack? {
        guard let id else { return nil }
        return packs.first { $0.id == id }
    }

    private func index(_ id: UUID) -> Int? { packs.firstIndex { $0.id == id } }

    func packContaining(_ captureID: UUID) -> Pack? {
        packs.first { $0.captures.contains { $0.id == captureID } }
    }

    func isActive(_ id: UUID) -> Bool {
        guard activePackID == id, let at = activeAt else { return false }
        return Date().timeIntervalSince(at) < 45 * 60
    }

    /// Packs Auto-sort can file into. Style packs are left out: they only take what you add on purpose.
    func summaries(limit: Int = 12) -> [PackSummary] {
        packs.filter { !$0.isStyle }.prefix(limit).map { p in
            PackSummary(
                id: p.id, name: p.name,
                samples: p.captures.suffix(3).reversed().map { $0.displayTitle.singleLine.truncated(80) },
                hosts: Set(p.captures.compactMap(\.host)),
                texts: p.captures.suffix(8).map { (($0.title ?? "") + ". " + $0.text.prefix(400)) }
            )
        }
    }

    // MARK: Mutations

    @discardableResult
    func createPack(name: String, emoji: String?, autoNamed: Bool) -> Pack {
        var clean = PackNaming.clean(name)
        if packs.contains(where: { $0.name.caseInsensitiveCompare(clean) == .orderedSame }) {
            var n = 2
            while packs.contains(where: { $0.name.caseInsensitiveCompare("\(clean) \(n)") == .orderedSame }) { n += 1 }
            clean = "\(clean) \(n)"
        }
        let dir = uniqueURL(in: packsDir, base: clean.slug(), ext: nil)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        var meta = PackMeta(id: UUID(), name: clean, emoji: emoji, created: Date(), autoNamed: autoNamed)
        let hue = freeHue(for: meta.id)
        meta.hue = hue
        PackStyle.assign(hue, to: meta.id)
        writeMeta(meta, in: dir)
        let p = Pack(meta: meta, folder: dir, captures: [])
        packs.append(p)
        sortPacks()
        ensureOnWheel(p.id)
        return p
    }

    @discardableResult
    func add(_ d: CaptureDraft, to packID: UUID) -> Capture? {
        guard let i = index(packID) else { return nil }
        let base = Self.stamp(d.capturedAt) + "-" + (d.title?.nonEmpty ?? d.text).slug()
        let url = uniqueURL(in: packs[i].folder, base: base, ext: "md")
        var c = Capture(id: UUID(), text: d.text, capturedAt: d.capturedAt, appName: d.appName,
                        bundleID: d.bundleID, title: d.title, url: d.url, fileName: url.lastPathComponent)
        do {
            if let png = d.imageData {
                let imageURL = url.deletingPathExtension().appendingPathExtension("png")
                try png.write(to: imageURL, options: .atomic)
                c.image = imageURL.lastPathComponent
            }
            if let src = d.attachment {
                let ext = src.pathExtension.lowercased()
                // "<capture>.file.<ext>", so an attached .md never collides with the capture's own .md.
                let dest = url.deletingPathExtension().appendingPathExtension("file").appendingPathExtension(ext.isEmpty ? "bin" : ext)
                try fm.copyItem(at: src, to: dest) // keeps the quarantine mark
                c.file = dest.lastPathComponent
            }
            try CaptureFile.serialize(c).write(to: url, atomically: true, encoding: .utf8)
        } catch {
            NSLog("Shapr: could not write capture: \(error)")
            return nil
        }
        packs[i].captures.append(c)
        sortPacks()
        ensureOnWheel(packID)
        return c
    }

    /// `toTrash` keeps deleted captures recoverable from the Finder Trash.
    func removeCapture(_ captureID: UUID, toTrash: Bool = true) {
        guard let p = packContaining(captureID), let i = index(p.id),
              let ci = packs[i].captures.firstIndex(where: { $0.id == captureID }) else { return }
        let c = packs[i].captures[ci]
        var files = [packs[i].folder.appendingPathComponent(c.fileName)]
        files += c.sideFiles.map { packs[i].folder.appendingPathComponent($0) }
        for file in files {
            if toTrash { try? fm.trashItem(at: file, resultingItemURL: nil) } else { try? fm.removeItem(at: file) }
        }
        packs[i].captures.remove(at: ci)
        sortPacks()
    }

    func moveCapture(_ captureID: UUID, to dest: UUID) {
        guard let src = packContaining(captureID), src.id != dest,
              let si = index(src.id), let di = index(dest),
              let ci = packs[si].captures.firstIndex(where: { $0.id == captureID }) else { return }
        var c = packs[si].captures[ci]
        let from = packs[si].folder.appendingPathComponent(c.fileName)
        let base = (c.fileName as NSString).deletingPathExtension
        let to = uniqueURL(in: packs[di].folder, base: base, ext: "md")
        let oldBase = (c.fileName as NSString).deletingPathExtension
        for key in [\Capture.image, \Capture.file] {
            guard let side = c[keyPath: key] else { continue }
            let base = to.deletingPathExtension().lastPathComponent
            let suffix = side.hasPrefix(oldBase) ? String(side.dropFirst(oldBase.count)) : "." + (side as NSString).pathExtension
            let sideTo = packs[di].folder.appendingPathComponent(base + suffix)
            if (try? fm.moveItem(at: packs[si].folder.appendingPathComponent(side), to: sideTo)) != nil {
                c[keyPath: key] = sideTo.lastPathComponent
            } else {
                c[keyPath: key] = nil
            }
        }
        do { try CaptureFile.serialize(c).write(to: from, atomically: true, encoding: .utf8) } catch {}
        do { try fm.moveItem(at: from, to: to) } catch { NSLog("Shapr: move failed: \(error)"); return }
        c.fileName = to.lastPathComponent
        packs[si].captures.remove(at: ci)
        packs[di].captures.append(c)
        packs[di].captures.sort { $0.capturedAt < $1.capturedAt }
        sortPacks()
        ensureOnWheel(dest)
    }

    /// Where a capture's attached file lives, if it has one.
    func fileURL(for c: Capture) -> URL? {
        guard let f = c.file, let p = packContaining(c.id) else { return nil }
        return p.folder.appendingPathComponent(f)
    }

    /// Where a capture's screenshot lives, if it has one.
    func imageURL(for c: Capture) -> URL? {
        guard let img = c.image, let p = packContaining(c.id) else { return nil }
        return p.folder.appendingPathComponent(img)
    }

    func rename(_ packID: UUID, to name: String, emoji: String?? = nil, autoNamed: Bool = false) {
        guard let i = index(packID), let clean = name.nonEmpty.map(PackNaming.clean) else { return }
        packs[i].meta.name = clean
        if let emoji { packs[i].meta.emoji = emoji }
        packs[i].meta.autoNamed = autoNamed
        let newSlug = clean.slug()
        if newSlug != packs[i].folder.lastPathComponent {
            let dest = uniqueURL(in: packsDir, base: newSlug, ext: nil)
            if (try? fm.moveItem(at: packs[i].folder, to: dest)) != nil { packs[i].folder = dest }
        }
        writeMeta(packs[i].meta, in: packs[i].folder)
        objectWillChange.send()
    }

    /// Facts (what's true) or style (how you write).
    func setRole(_ packID: UUID, _ role: PackRole) {
        guard let i = index(packID) else { return }
        packs[i].meta.role = role == .facts ? nil : role
        writeMeta(packs[i].meta, in: packs[i].folder)
        objectWillChange.send()
    }

    /// Style packs, most recently used first.
    var stylePacks: [Pack] { packs.filter(\.isStyle) }

    func setEmoji(_ packID: UUID, _ emoji: String?) {
        guard let i = index(packID) else { return }
        packs[i].meta.emoji = emoji
        writeMeta(packs[i].meta, in: packs[i].folder)
    }

    /// Moves the pack's folder to the Trash.
    func deletePack(_ packID: UUID) {
        guard let i = index(packID) else { return }
        try? fm.trashItem(at: packs[i].folder, resultingItemURL: nil)
        packs.remove(at: i)
        if equippedPackID == packID { equip(nil) }
        if activePackID == packID { activePackID = nil }
        wheelSlots = wheelSlots.map { $0 == packID ? nil : $0 }
        saveSlots()
    }

    /// Deletes a pack that was created a moment ago (toast Undo). Skips the Trash.
    func discardNewPack(_ packID: UUID) {
        guard let i = index(packID), packs[i].captures.isEmpty else { return }
        try? fm.removeItem(at: packs[i].folder)
        packs.remove(at: i)
        if activePackID == packID { activePackID = nil }
        wheelSlots = wheelSlots.map { $0 == packID ? nil : $0 }
        saveSlots()
    }

    func merge(_ source: UUID, into dest: UUID) {
        guard source != dest, let src = pack(source) else { return }
        for c in src.captures { moveCapture(c.id, to: dest) }
        deletePack(source)
    }

    func equip(_ packID: UUID?) {
        equippedPackID = packID
        if persistPrefs { defaults.set(packID?.uuidString, forKey: Keys.equipped) }
        if let packID { ensureOnWheel(packID) }
    }

    func markActive(_ packID: UUID?) {
        activePackID = packID
        activeAt = packID == nil ? nil : Date()
    }

    func place(_ packID: UUID, inSlot slot: Int) {
        guard (0..<6).contains(slot) else { return }
        if let old = wheelSlots.firstIndex(of: packID) { wheelSlots[old] = wheelSlots[slot] }
        wheelSlots[slot] = packID
        saveSlots()
    }

    // MARK: Safe Share rules

    func redactionRules(for packID: UUID) -> RedactionRules {
        guard let p = pack(packID),
              let data = try? Data(contentsOf: rulesURL(p)),
              let r = try? JSONDecoder().decode(RedactionRules.self, from: data) else { return RedactionRules() }
        return r
    }

    func saveRedactionRules(_ rules: RedactionRules, for packID: UUID) {
        guard let p = pack(packID) else { return }
        let url = rulesURL(p)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        try? enc.encode(rules).write(to: url, options: .atomic)
    }

    private func rulesURL(_ p: Pack) -> URL {
        p.folder.appendingPathComponent(".shapr", isDirectory: true).appendingPathComponent("redactions.json")
    }

    // MARK: Live sources

    /// The folders, repos, pages and threads that keep this pack up to date.
    func sources(for packID: UUID) -> [PackSource] {
        if let cached = sourceCache[packID] { return cached }
        guard let p = pack(packID) else { return [] }
        let list = (try? Data(contentsOf: sourcesURL(p))).flatMap { try? Self.decoder.decode([PackSource].self, from: $0) } ?? []
        sourceCache[packID] = list
        return list
    }

    func saveSources(_ sources: [PackSource], for packID: UUID) {
        guard let p = pack(packID) else { return }
        let url = sourcesURL(p)
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(sources).write(to: url, options: .atomic)
        sourceCache[packID] = sources
        objectWillChange.send()
    }

    func updateSource(_ source: PackSource, in packID: UUID) {
        var all = sources(for: packID)
        if let i = all.firstIndex(where: { $0.id == source.id }) { all[i] = source } else { all.append(source) }
        saveSources(all, for: packID)
    }

    /// Every pack's sources, for syncing.
    func allSources() -> [(packID: UUID, source: PackSource)] {
        packs.flatMap { p in sources(for: p.id).map { (p.id, $0) } }
    }

    private func sourcesURL(_ p: Pack) -> URL {
        p.folder.appendingPathComponent(".shapr", isDirectory: true).appendingPathComponent("sources.json")
    }

    enum SourceChange: Equatable { case added, updated, unchanged }

    /// Adds an item from a live source, or rewrites the capture that already holds it when it changed.
    /// Never makes a second copy of the same item.
    @discardableResult
    func upsertSourceItem(packID: UUID, sourceID: UUID, key: String, rev: String, draft: CaptureDraft) -> SourceChange {
        guard let i = index(packID) else { return .unchanged }
        let sid = sourceID.uuidString
        if let ci = packs[i].captures.firstIndex(where: { $0.sourceID == sid && $0.sourceKey == key }) {
            var c = packs[i].captures[ci]
            guard c.sourceRev != rev else { return .unchanged }
            c.text = draft.text
            c.title = draft.title ?? c.title
            c.url = draft.url ?? c.url
            c.appName = draft.appName ?? c.appName
            c.sourceRev = rev
            c.capturedAt = draft.capturedAt
            let url = packs[i].folder.appendingPathComponent(c.fileName)
            guard (try? CaptureFile.serialize(c).write(to: url, atomically: true, encoding: .utf8)) != nil else { return .unchanged }
            packs[i].captures[ci] = c
            packs[i].captures.sort { $0.capturedAt < $1.capturedAt }
            sortPacks()
            return .updated
        }
        let base = Self.stamp(draft.capturedAt) + "-" + (draft.title?.nonEmpty ?? draft.text).slug()
        let url = uniqueURL(in: packs[i].folder, base: base, ext: "md")
        let c = Capture(id: UUID(), text: draft.text, capturedAt: draft.capturedAt, appName: draft.appName,
                        bundleID: draft.bundleID, title: draft.title, url: draft.url, fileName: url.lastPathComponent,
                        sourceID: sid, sourceKey: key, sourceRev: rev)
        guard (try? CaptureFile.serialize(c).write(to: url, atomically: true, encoding: .utf8)) != nil else { return .unchanged }
        packs[i].captures.append(c)
        packs[i].captures.sort { $0.capturedAt < $1.capturedAt }
        sortPacks()
        return .added
    }

    /// Removes a source's captures whose items are gone (a deleted file, a closed issue).
    /// `keep: nil` removes all of them.
    @discardableResult
    func removeSourceItems(packID: UUID, sourceID: UUID, keep: Set<String>?) -> Int {
        guard let p = pack(packID) else { return 0 }
        let sid = sourceID.uuidString
        let gone = p.captures.filter { $0.sourceID == sid && !(keep?.contains($0.sourceKey ?? "") ?? false) }
        for c in gone { removeCapture(c.id, toTrash: false) }
        return gone.count
    }

    /// Stops a source; its captures stay unless `removeItems`.
    func removeSource(_ sourceID: UUID, from packID: UUID, removeItems: Bool) {
        saveSources(sources(for: packID).filter { $0.id != sourceID }, for: packID)
        if removeItems { removeSourceItems(packID: packID, sourceID: sourceID, keep: nil) }
    }

    // MARK: Helpers

    private func ensureOnWheel(_ packID: UUID) {
        if wheelSlots.contains(packID) { return }
        if let i = wheelSlots.firstIndex(where: { $0 == nil }) {
            wheelSlots[i] = packID
        } else {
            // Replace the slot whose pack was used least recently (never the equipped one).
            let candidates = wheelSlots.indices.filter { wheelSlots[$0] != equippedPackID }
            let i = candidates.min { (pack(wheelSlots[$0])?.updated ?? .distantPast) < (pack(wheelSlots[$1])?.updated ?? .distantPast) } ?? 5
            wheelSlots[i] = packID
        }
        saveSlots()
    }

    private func saveSlots() {
        guard persistPrefs else { return }
        defaults.set(wheelSlots.map { $0?.uuidString ?? "" }, forKey: Keys.slots)
    }

    private func sortPacks() {
        packs.sort { $0.updated > $1.updated }
    }

    // MARK: Colors

    /// Gives every pack its own color while there are colors to go round, and keeps it for life.
    /// Packs saved before 0.16 only had the color their id suggested, so two could share one: the
    /// newer of the two moves to a free color, once.
    private func assignHues() {
        var counts = [Int](repeating: 0, count: PackStyle.palette.count)
        let oldestFirst = packs.indices.sorted {
            (packs[$0].meta.created, packs[$0].id.uuidString) < (packs[$1].meta.created, packs[$1].id.uuidString)
        }
        for i in oldestFirst {
            var hue = packs[i].meta.hue ?? -1
            if !counts.indices.contains(hue) {
                hue = PackStyle.leastUsed(counts, from: PackStyle.hashIndex(packs[i].id))
                packs[i].meta.hue = hue
                writeMeta(packs[i].meta, in: packs[i].folder)
            }
            counts[hue] += 1
            PackStyle.assign(hue, to: packs[i].id)
        }
    }

    /// A color no pack has yet (or the one fewest have), for a pack being made.
    private func freeHue(for id: UUID) -> Int {
        var counts = [Int](repeating: 0, count: PackStyle.palette.count)
        for p in packs { counts[PackStyle.index(p.id)] += 1 }
        return PackStyle.leastUsed(counts, from: PackStyle.hashIndex(id))
    }

    private func writeMeta(_ meta: PackMeta, in dir: URL) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(meta).write(to: dir.appendingPathComponent("pack.json"), options: .atomic)
    }

    private static let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    private func uniqueURL(in dir: URL, base: String, ext: String?) -> URL {
        func make(_ name: String) -> URL {
            let u = dir.appendingPathComponent(name, isDirectory: ext == nil)
            return ext.map { u.appendingPathExtension($0) } ?? u
        }
        var candidate = make(base)
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            candidate = make("\(base)-\(n)")
            n += 1
        }
        return candidate
    }

    static func stamp(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd-HHmmss"
        return f.string(from: d)
    }
}

extension PackStore {
    /// The same capture already saved: same text (ignoring spacing and case) from the same place.
    /// Screenshots count as the same only if their text and source match and they have no new text.
    func duplicate(of d: CaptureDraft) -> (Pack, Capture)? {
        func norm(_ s: String) -> String { s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ").prefix(20_000).description }
        let text = norm(d.text)
        guard text.count >= 3 || d.attachment != nil else { return nil }
        for p in packs {
            for c in p.captures.reversed() where norm(c.text) == text && (c.url ?? "") == (d.url ?? "") {
                if d.imageData != nil, text.count < 20 { continue } // two screenshots with no readable text aren't "the same"
                return (p, c)
            }
        }
        return nil
    }
}

