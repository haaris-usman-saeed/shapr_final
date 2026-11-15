import AppKit
import Combine
import CryptoKit
import OSLog

let shareLog = Logger(subsystem: "app.shapr.Shapr", category: "share")

// MARK: - Server

/// Where shared packs live. Set at build time (SHAPR_SHARE_SERVER → Info.plist), or in Settings.
enum ShareServer {
    static let defaultsKey = "shareServer"
    static let fallback = "http://localhost:8787"

    static var base: URL {
        if let s = UserDefaults.standard.string(forKey: defaultsKey)?.nonEmpty, let u = URL(string: s) { return u }
        if let s = (Bundle.main.object(forInfoDictionaryKey: "ShaprShareServer") as? String)?.nonEmpty, let u = URL(string: s) { return u }
        return URL(string: fallback)!
    }

    static func pageURL(_ id: String, base: URL = base) -> URL { base.appendingPathComponent("p").appendingPathComponent(id) }

    /// The pack id in "https://server/p/ID", "shapr://join/ID" or a bare id. Web links only count when
    /// they point at this Shapr's server, so a link can never make Shapr fetch from somewhere else.
    static func packID(from link: String, base: URL = base) -> String? {
        let s = link.trimmingCharacters(in: .whitespacesAndNewlines)
        func valid(_ id: String) -> String? { id.range(of: #"^[A-Za-z0-9]{12}$"#, options: .regularExpression) != nil ? id : nil }
        if let id = valid(s) { return id }
        guard let u = URL(string: s) else { return nil }
        if u.scheme == "shapr", u.host == "join" { return valid(u.lastPathComponent) }
        let parts = u.path.split(separator: "/").map(String.init)
        guard ["http", "https"].contains(u.scheme ?? ""), u.host?.lowercased() == base.host?.lowercased(),
              u.port == base.port, parts.count == 2, parts[0] == "p" else { return nil }
        return valid(parts[1])
    }
}

struct SharedCapture: Codable, Equatable {
    var id: String
    var text: String
    var title: String?
    var captured: String?
    var app: String?
    var url: String?
    var image: String?
    var file: String?
    var fileName: String?
}

struct SharedManifest: Codable {
    var id: String?
    var name: String
    var emoji: String?
    var sharedBy: String?
    var version: Int?
    var updated: String?
    var captures: [SharedCapture]
}

struct ShareClient {
    enum ClientError: LocalizedError {
        case server(String)
        case offline(String)
        var errorDescription: String? {
            switch self {
            case .server(let m): return m
            case .offline(let m): return "Couldn't reach the share server (\(m))."
            }
        }
    }

    var base: URL = ShareServer.base
    var session: URLSession = .shared

    private func request(_ path: String, method: String = "GET", token: String? = nil, body: Data? = nil,
                         type: String? = nil, etag: String? = nil) async throws -> (Data, HTTPURLResponse) {
        var r = URLRequest(url: base.appendingPathComponent(path))
        r.httpMethod = method
        r.timeoutInterval = 60
        if let token { r.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        if let type { r.setValue(type, forHTTPHeaderField: "Content-Type") }
        if let etag { r.setValue(etag, forHTTPHeaderField: "If-None-Match") }
        r.httpBody = body
        let (data, resp): (Data, URLResponse)
        do { (data, resp) = try await session.data(for: r) } catch { throw ClientError.offline(error.localizedDescription) }
        guard let http = resp as? HTTPURLResponse else { throw ClientError.server("No answer from the share server.") }
        if http.statusCode >= 400 {
            let msg = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["error"] as? String
            throw ClientError.server(msg ?? "The share server said \(http.statusCode).")
        }
        return (data, http)
    }

    private func json(_ data: Data) -> [String: Any] { (try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:] }

    func create(name: String, emoji: String?) async throws -> (id: String, token: String, url: URL) {
        let body = try JSONEncoder().encode(SharedManifest(name: name, emoji: emoji, captures: []))
        let (data, _) = try await request("api/packs", method: "POST", body: body, type: "application/json")
        let j = json(data)
        guard let id = j["id"] as? String, let token = j["token"] as? String else { throw ClientError.server("The share server didn't make a link.") }
        return (id, token, (j["url"] as? String).flatMap(URL.init(string:)) ?? ShareServer.pageURL(id, base: base))
    }

    func update(_ id: String, token: String, manifest: SharedManifest) async throws -> (version: Int, joins: Int) {
        let (data, _) = try await request("api/packs/\(id)", method: "PUT", token: token,
                                          body: try JSONEncoder().encode(manifest), type: "application/json")
        let j = json(data)
        return ((j["version"] as? Int) ?? 0, (j["joins"] as? Int) ?? 0)
    }

    func upload(_ id: String, token: String, name: String, data: Data) async throws {
        _ = try await request("api/packs/\(id)/files/\(name)", method: "PUT", token: token, body: data,
                              type: "application/octet-stream")
    }

    /// nil when the pack hasn't changed since `etag`.
    func fetch(_ id: String, etag: String? = nil) async throws -> (manifest: SharedManifest, etag: String?)? {
        let (data, http) = try await request("api/packs/\(id)", etag: etag)
        if http.statusCode == 304 { return nil }
        return (try JSONDecoder().decode(SharedManifest.self, from: data), http.value(forHTTPHeaderField: "ETag"))
    }

    func file(_ id: String, name: String) async throws -> Data {
        try await request("api/packs/\(id)/files/\(name)").0
    }

    func delete(_ id: String, token: String) async throws {
        _ = try await request("api/packs/\(id)", method: "DELETE", token: token)
    }

    func countJoin(_ id: String) async {
        _ = try? await request("api/packs/\(id)/join", method: "POST")
    }
}

// MARK: - State kept next to each pack

/// A pack you share: its link, what's been published, and your sharing choices.
struct ShareState: Codable, Equatable {
    var id: String
    var url: String
    var version = 0
    var joins = 0
    var includeSources = true
    var includeTimes = false
    var includeApps = false
    var includeImages = false
    var uploaded: Set<String> = []
    /// New captures that need a privacy check before they're shared.
    var held: [UUID] = []
    var lastHash = ""
    var lastPublished: Date?
}

/// A pack you joined from someone's link: kept up to date from the server.
struct Subscription: Codable, Equatable {
    struct Entry: Codable, Equatable { var local: UUID; var hash: String }
    var id: String
    var server: String
    var etag: String?
    var version = 0
    var entries: [String: Entry] = [:]
    var lastSync: Date?
    var sharedBy: String?
}

// MARK: - Engine

/// Live shared packs: share a pack as a link, keep it updated as you capture, and keep packs you
/// joined in sync. Nothing leaves your Mac until you create a link, and new captures that might
/// hold private info wait for your review instead of being shared.
@MainActor
final class SharedPacks: ObservableObject {
    @Published private(set) var shared: [UUID: ShareState] = [:]
    @Published private(set) var subscribed: [UUID: Subscription] = [:]
    @Published private(set) var busy: Set<UUID> = []
    @Published private(set) var lastError: [UUID: String] = [:]

    let store: PackStore
    var client: ShareClient
    /// Where write tokens are kept: your Keychain (tests use memory, never your Keychain).
    var tokens: (get: (String) -> String?, set: (String, String?) -> Void) = (
        get: { Keychain.get($0) }, set: { Keychain.set($1, account: $0) })
    /// Called when new captures in a shared pack are held back for a privacy check.
    var onHeld: (Pack, Int) -> Void = { _, _ in }
    private var cancellables: Set<AnyCancellable> = []
    private var timer: Timer?
    private var signatures: [UUID: String] = [:]

    init(store: PackStore, client: ShareClient = ShareClient()) {
        self.store = store
        self.client = client
        reload()
    }

    /// Watches shared packs for new captures (republishing a few seconds after you stop adding)
    /// and syncs joined packs now and every 10 minutes.
    func start() {
        store.$packs
            .debounce(for: .seconds(3), scheduler: RunLoop.main)
            .sink { [weak self] _ in MainActor.assumeIsolated { self?.packsChanged() } }
            .store(in: &cancellables)
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncSoon() }
        }
        Task { await syncAll() }
    }

    // MARK: Files

    private static func dir(_ p: Pack) -> URL { p.folder.appendingPathComponent(".shapr", isDirectory: true) }
    private static func shareURL(_ p: Pack) -> URL { dir(p).appendingPathComponent("share.json") }
    private static func subscriptionURL(_ p: Pack) -> URL { dir(p).appendingPathComponent("subscription.json") }
    private static func tokenAccount(_ id: String) -> String { "share-token-\(id)" }

    func reload() {
        var s: [UUID: ShareState] = [:], j: [UUID: Subscription] = [:]
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        for p in store.packs {
            if let d = try? Data(contentsOf: Self.shareURL(p)), let v = try? dec.decode(ShareState.self, from: d) { s[p.id] = v }
            if let d = try? Data(contentsOf: Self.subscriptionURL(p)), let v = try? dec.decode(Subscription.self, from: d) { j[p.id] = v }
        }
        if s != shared { shared = s }
        if j != subscribed { subscribed = j }
    }

    private func write<T: Encodable>(_ value: T?, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        guard let value else { try? FileManager.default.removeItem(at: url); return }
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try? enc.encode(value).write(to: url, options: .atomic)
    }

    private func save(_ state: ShareState?, for packID: UUID) {
        guard let p = store.pack(packID) else { return }
        write(state, to: Self.shareURL(p))
        shared[packID] = state
    }

    private func save(_ sub: Subscription?, for packID: UUID) {
        guard let p = store.pack(packID) else { return }
        write(sub, to: Self.subscriptionURL(p))
        subscribed[packID] = sub
    }

    // MARK: Sharing

    /// Creates a link for the pack as reviewed in Share Safely, or updates the existing one.
    @discardableResult
    func share(_ session: ShareSession) async throws -> URL {
        guard let pack = store.pack(session.packID) else { throw ShareClient.ClientError.server("That pack is gone.") }
        store.saveRedactionRules(session.rules(), for: pack.id)
        var state: ShareState
        if let existing = shared[pack.id] {
            state = existing
        } else {
            let made = try await client.create(name: pack.name, emoji: pack.meta.emoji)
            tokens.set(Self.tokenAccount(made.id), made.token)
            state = ShareState(id: made.id, url: made.url.absoluteString)
        }
        state.includeSources = session.includeSources
        state.includeTimes = session.includeTimes
        state.includeApps = session.includeApps
        state.includeImages = session.includeImages
        state.held = []
        state.lastHash = ""
        save(state, for: pack.id)
        try await publish(pack.id)
        shareLog.notice("shared pack as \(state.id, privacy: .public)")
        return URL(string: state.url) ?? ShareServer.pageURL(state.id)
    }

    /// What friends get right now, plus the captures waiting for a privacy check.
    func build(_ pack: Pack, state: ShareState) -> (captures: [SharedCapture], files: [String: URL], held: [UUID]) {
        let rules = store.redactionRules(for: pack.id)
        let session = ShareSession(pack: pack, rules: rules)
        session.includeSources = state.includeSources
        session.includeTimes = state.includeTimes
        session.includeApps = state.includeApps
        session.includeImages = state.includeImages
        // A capture you haven't reviewed with something private-looking in it waits for you.
        let unreviewed = Set(pack.captures.map(\.id)).subtracting(rules.reviewedCaptures)
        let held = Set(session.flags.filter { unreviewed.contains($0.captureID) && !$0.remembered && !session.excluded.contains($0.captureID) }
            .map(\.captureID))
        let originals = Dictionary(uniqueKeysWithValues: pack.captures.map { ($0.id, $0) })
        let iso = ISO8601DateFormatter()
        var files: [String: URL] = [:]
        let captures: [SharedCapture] = session.sharedCaptures().compactMap { c in
            guard !held.contains(c.id), let original = originals[c.id] else { return nil }
            let key = c.id.uuidString.lowercased()
            var out = SharedCapture(id: key, text: c.text, title: c.title,
                                    captured: state.includeTimes ? iso.string(from: c.capturedAt) : nil,
                                    app: c.appName, url: c.url)
            if state.includeImages, let img = store.imageURL(for: original) {
                let name = "\(key).\(img.pathExtension.lowercased().nonEmpty ?? "png")"
                out.image = name
                files[name] = img
            }
            if state.includeImages, let f = store.fileURL(for: original), FileTypes.isAllowed(ext: f.pathExtension) {
                let name = "\(key)-file.\(f.pathExtension.lowercased())"
                out.file = name
                out.fileName = original.title ?? f.lastPathComponent
                files[name] = f
            }
            return out
        }
        return (captures, files, pack.captures.map(\.id).filter(held.contains))
    }

    /// Sends the pack's current shared copy to the server (only what changed).
    func publish(_ packID: UUID) async throws {
        guard let pack = store.pack(packID), var state = shared[packID] else { return }
        guard let token = tokens.get(Self.tokenAccount(state.id)) else {
            throw ShareClient.ClientError.server("This Mac doesn't have the key for that link anymore. Stop sharing and share again.")
        }
        busy.insert(packID)
        defer { busy.remove(packID) }
        let (captures, files, held) = build(pack, state: state)
        let manifest = SharedManifest(name: pack.name, emoji: pack.meta.emoji, captures: captures)
        let enc = JSONEncoder()
        enc.outputFormatting = .sortedKeys
        let hash = Self.sha((try? enc.encode(manifest)) ?? Data()) + Self.sha(Data(files.keys.sorted().joined(separator: "|").utf8))
        if hash == state.lastHash, held == state.held { return }

        for (name, url) in files where !state.uploaded.contains(name) {
            guard let data = try? Data(contentsOf: url), data.count <= 25_000_000 else { continue }
            try await client.upload(state.id, token: token, name: name, data: data)
        }
        do {
            let r = try await client.update(state.id, token: token, manifest: manifest)
            state.version = r.version
            state.joins = r.joins
        } catch {
            lastError[packID] = error.localizedDescription
            throw error
        }
        let newlyHeld = held.filter { !state.held.contains($0) }
        state.uploaded = Set(files.keys)
        state.held = held
        state.lastHash = hash
        state.lastPublished = Date()
        lastError[packID] = nil
        save(state, for: packID)
        if !newlyHeld.isEmpty { onHeld(pack, newlyHeld.count) }
        shareLog.notice("published \(captures.count) capture(s), \(held.count) held, version \(state.version)")
    }

    func stopSharing(_ packID: UUID) async {
        guard let state = shared[packID] else { return }
        if let token = tokens.get(Self.tokenAccount(state.id)) {
            try? await client.delete(state.id, token: token)
        }
        tokens.set(Self.tokenAccount(state.id), nil)
        save(nil as ShareState?, for: packID)
    }

    private func packsChanged() {
        reload()
        for (id, _) in shared {
            guard let p = store.pack(id) else { continue }
            let sig = p.captures.map { $0.id.uuidString + String($0.text.count) }.joined()
            if signatures[id] == nil { signatures[id] = sig; continue }
            guard signatures[id] != sig else { continue }
            signatures[id] = sig
            Task { try? await publish(id) }
        }
    }

    // MARK: Joining

    /// Adds a shared pack to this Mac and keeps it in sync.
    func join(_ link: String) async throws -> Pack {
        guard let id = ShareServer.packID(from: link, base: client.base) else {
            throw ShareClient.ClientError.server("That isn't a Shapr pack link for this server.")
        }
        if let existing = subscribed.first(where: { $0.value.id == id }), let p = store.pack(existing.key) {
            try? await sync(p.id)
            return store.pack(p.id) ?? p
        }
        guard let (manifest, etag) = try await client.fetch(id) else { throw ShareClient.ClientError.server("The pack didn't load.") }
        let pack = store.createPack(name: PackNaming.clean(manifest.name), emoji: PackNaming.cleanEmoji(manifest.emoji), autoNamed: false)
        var sub = Subscription(id: id, server: client.base.absoluteString, etag: etag, sharedBy: manifest.sharedBy)
        save(sub, for: pack.id)
        sub = await apply(manifest, to: pack.id, sub: sub)
        sub.etag = etag
        sub.version = manifest.version ?? 0
        sub.lastSync = Date()
        save(sub, for: pack.id)
        await client.countJoin(id)
        shareLog.notice("joined \(id, privacy: .public) with \(manifest.captures.count) capture(s)")
        return store.pack(pack.id) ?? pack
    }

    /// Brings a joined pack up to date: adds new captures, updates edited ones, removes deleted ones.
    func sync(_ packID: UUID) async throws {
        guard var sub = subscribed[packID], store.pack(packID) != nil else { return }
        busy.insert(packID)
        defer { busy.remove(packID) }
        do {
            if let (manifest, etag) = try await client.fetch(sub.id, etag: sub.etag) {
                sub = await apply(manifest, to: packID, sub: sub)
                sub.etag = etag
                sub.version = manifest.version ?? sub.version
            }
            sub.lastSync = Date()
            lastError[packID] = nil
            save(sub, for: packID)
        } catch {
            lastError[packID] = error.localizedDescription
            throw error
        }
    }

    func syncSoon() { Task { @MainActor in await syncAll() } }

    func syncAll() async {
        reload()
        for id in subscribed.keys { try? await sync(id) }
        for id in shared.keys { try? await publish(id) }
    }

    /// Stops syncing; the pack and its captures stay on this Mac.
    func leave(_ packID: UUID) { save(nil as Subscription?, for: packID) }

    private func apply(_ manifest: SharedManifest, to packID: UUID, sub: Subscription) async -> Subscription {
        var sub = sub
        let remote = Dictionary(manifest.captures.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        // Gone from the shared pack: remove here too.
        for (rid, entry) in sub.entries where remote[rid] == nil {
            store.removeCapture(entry.local, toTrash: false)
            sub.entries[rid] = nil
        }
        let iso = ISO8601DateFormatter()
        for c in manifest.captures {
            let hash = Self.hash(c)
            if let entry = sub.entries[c.id] {
                if entry.hash == hash { continue }
                store.removeCapture(entry.local, toTrash: false) // edited: replace it
            }
            var image: Data?
            if let name = c.image, let data = try? await client.file(sub.id, name: name), NSImage(data: data) != nil {
                image = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
            }
            var attachment: URL?
            if let name = c.file {
                let display = FileDownloader.sanitize(c.fileName ?? name)
                let ext = (display as NSString).pathExtension.lowercased().nonEmpty ?? (name as NSString).pathExtension.lowercased()
                if FileTypes.isAllowed(ext: ext), !FileTypes.blocked.contains(ext), let data = try? await client.file(sub.id, name: name) {
                    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-join-\(UUID().uuidString)")
                    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                    let dest = dir.appendingPathComponent((display as NSString).pathExtension.isEmpty ? display + "." + ext : display)
                    if (try? data.write(to: dest)) != nil {
                        Quarantine.mark(dest, from: ShareServer.pageURL(sub.id, base: client.base))
                        attachment = dest
                    }
                }
            }
            let d = CaptureDraft(text: c.text, capturedAt: c.captured.flatMap(iso.date(from:)) ?? Date(), appName: c.app,
                                 title: c.title, url: c.url, imageData: image, attachment: attachment)
            if let added = store.add(d, to: packID) {
                sub.entries[c.id] = .init(local: added.id, hash: hash)
            }
        }
        return sub
    }

    static func hash(_ c: SharedCapture) -> String {
        sha(Data([c.text, c.title ?? "", c.url ?? "", c.image ?? "", c.file ?? ""].joined(separator: "\u{1F}").utf8))
    }

    static func sha(_ d: Data) -> String { SHA256.hash(data: d).map { String(format: "%02x", $0) }.joined() }
}
