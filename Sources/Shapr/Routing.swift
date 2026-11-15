import AppKit
import ApplicationServices
import SwiftUI

/// What Shapr can tell about where you are: who the email is from, which site, repo, folder or page.
struct RouteSignals: Equatable {
    /// Addresses on screen, the sender first when known.
    var emails: [String] = []
    /// True when `emails.first` is known to be the sender (Apple Mail tells us; on web mail it's the first address).
    var senderKnown = false
    var url: String?
    /// A file being viewed or edited (Preview, Xcode, a text editor).
    var documentPath: String?

    var isEmpty: Bool { emails.isEmpty && url == nil && documentPath == nil }
}

/// A pack Shapr picked for you, and why, in words.
struct RouteSuggestion: Equatable {
    let packID: UUID
    let reason: String
    let score: Double
    /// Strong evidence (a sender, a repo, a linked page, or your own earlier choice) can override the equipped pack.
    var isStrong: Bool { score >= 3 }
}

/// Picks the pack that fits where you are, so you rarely have to choose.
/// Evidence comes from the packs themselves (addresses and sites in captures, linked sources, pack names)
/// and from your own past choices. Everything stays on this Mac.
enum PackRouter {
    // MARK: Keys

    /// One piece of evidence: "email:ana@acme.com", "domain:acme.com", "repo:github.com/acme/app",
    /// "host:docs.acme.dev", "folder:/Users/me/Acme", "url:mail.google.com/mail/u/0/#inbox/FMf…".
    struct Key: Hashable, Comparable {
        enum Kind: String, CaseIterable { case email, domain, repo, url, folder, host }
        let kind: Kind
        let value: String
        var raw: String { kind.rawValue + ":" + value }
        static func < (a: Key, b: Key) -> Bool { a.raw < b.raw }

        var weight: Double {
            switch kind {
            case .email: return 3.2
            case .url: return 3.2
            case .repo: return 3.0
            case .folder: return 3.0
            case .domain: return 2.2
            case .host: return 1.2
            }
        }
    }

    /// Webmail, AI chats and big platforms say nothing about which project you're on.
    static let genericHosts: Set<String> = [
        "mail.google.com", "gmail.com", "outlook.live.com", "outlook.office.com", "outlook.office365.com", "mail.yahoo.com",
        "chatgpt.com", "chat.openai.com", "claude.ai", "gemini.google.com", "perplexity.ai", "www.perplexity.ai",
        "google.com", "www.google.com", "bing.com", "duckduckgo.com", "youtube.com", "www.youtube.com",
        "app.slack.com", "discord.com", "teams.microsoft.com", "web.whatsapp.com", "x.com", "twitter.com",
        "linkedin.com", "www.linkedin.com", "facebook.com", "reddit.com", "www.reddit.com", "news.ycombinator.com",
        "docs.google.com", "drive.google.com", "notion.so", "www.notion.so", "github.com", "gitlab.com",
        "en.wikipedia.org", "wikipedia.org", "stackoverflow.com", "localhost",
    ]

    /// Addresses at these say nothing about a company.
    static let freeMail: Set<String> = [
        "gmail.com", "googlemail.com", "outlook.com", "hotmail.com", "live.com", "msn.com", "yahoo.com", "ymail.com",
        "icloud.com", "me.com", "mac.com", "aol.com", "proton.me", "protonmail.com", "pm.me", "gmx.com", "gmx.net",
        "yandex.com", "zoho.com", "hey.com", "fastmail.com", "mail.com", "qq.com", "163.com", "126.com",
        "example.com", "users.noreply.github.com",
    ]

    private static let secondLevel: Set<String> = ["co", "com", "ac", "edu", "gov", "org", "net", "ne", "or", "go"]

    /// "mail.acme.co.uk" → "acme.co.uk", "docs.acme.com" → "acme.com".
    static func baseDomain(_ host: String) -> String {
        var labels = host.lowercased().split(separator: ".").map(String.init)
        if labels.first == "www" { labels.removeFirst() }
        guard labels.count > 2 else { return labels.joined(separator: ".") }
        let n = labels.count
        if labels[n - 1].count == 2, secondLevel.contains(labels[n - 2]) { return labels.suffix(3).joined(separator: ".") }
        return labels.suffix(2).joined(separator: ".")
    }

    private static let emailPattern = try! NSRegularExpression(
        pattern: #"(?<![\w.+-])[A-Za-z0-9._%+-]{1,64}@[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)*\.[A-Za-z]{2,24}(?![\w-])"#)

    /// Email addresses in text, lowercased, in order, without repeats.
    static func emails(in text: String, limit: Int = 30) -> [String] {
        let s = String(text.prefix(40_000))
        var out: [String] = []
        for m in emailPattern.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let r = Range(m.range, in: s) else { continue }
            let e = s[r].lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
            if e.hasSuffix(".png") || e.hasSuffix(".jpg") || e.contains("noreply") || e.contains("no-reply") { continue }
            if !out.contains(e) { out.append(e) }
            if out.count >= limit { break }
        }
        return out
    }

    static func domain(ofEmail e: String) -> String? {
        guard let at = e.lastIndex(of: "@") else { return nil }
        return baseDomain(String(e[e.index(after: at)...]))
    }

    /// "https://github.com/acme/app/issues/4" → "github.com/acme/app".
    static func repo(of url: String) -> String? {
        guard let u = URL(string: url), let host = u.host?.lowercased(), ["github.com", "gitlab.com"].contains(host) else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        guard parts.count >= 2, !["orgs", "settings", "notifications", "search", "marketplace", "explore"].contains(parts[0]) else { return nil }
        return "\(host)/\(parts[0].lowercased())/\(parts[1].lowercased())"
    }

    /// A page address you can compare: no scheme, no www, no tracking query. Keeps the fragment for
    /// web mail, where the thread lives after the #.
    static func normalizedURL(_ url: String) -> String? {
        guard var c = URLComponents(string: url), let host = c.host?.lowercased() else { return nil }
        c.queryItems = c.queryItems?.filter { !$0.name.hasPrefix("utm_") && !["ref", "fbclid", "gclid", "si"].contains($0.name) }
        if c.queryItems?.isEmpty == true { c.queryItems = nil }
        var out = (host.hasPrefix("www.") ? String(host.dropFirst(4)) : host) + c.path
        if out.hasSuffix("/") { out.removeLast() }
        if let q = c.percentEncodedQuery { out += "?" + q }
        let keepsFragment = ["mail.google.com", "outlook.live.com", "outlook.office.com"].contains(host)
        if keepsFragment, let f = c.fragment?.nonEmpty { out += "#" + f }
        return out
    }

    /// The evidence one place gives.
    static func keys(for s: RouteSignals) -> [Key] {
        var out: [Key] = []
        for (i, e) in s.emails.prefix(3).enumerated() {
            out.append(Key(kind: .email, value: e))
            if let d = domain(ofEmail: e), !freeMail.contains(d), i < 4 { out.append(Key(kind: .domain, value: d)) }
        }
        if let url = s.url {
            if let r = repo(of: url) { out.append(Key(kind: .repo, value: r)) }
            if let n = normalizedURL(url) { out.append(Key(kind: .url, value: n)) }
            if let host = URL(string: url)?.host?.lowercased(), !genericHosts.contains(host),
               !genericHosts.contains(baseDomain(host)), URL(string: url)?.isFileURL == false {
                out.append(Key(kind: .host, value: host))
                out.append(Key(kind: .domain, value: baseDomain(host)))
            }
            if let u = URL(string: url), u.isFileURL { out.append(Key(kind: .folder, value: u.deletingLastPathComponent().path)) }
        }
        if let path = s.documentPath {
            let p = path.hasPrefix("file://") ? (URL(string: path)?.path ?? path) : path
            out.append(Key(kind: .folder, value: (p as NSString).deletingLastPathComponent))
        }
        return Array(Set(out)).sorted()
    }

    // MARK: The index

    struct Index {
        /// key → pack → how many captures (or sources) back it up.
        var counts: [Key: [UUID: Int]] = [:]
        /// Folders linked as sources (prefix match).
        var folders: [(path: String, packID: UUID)] = []
        var names: [UUID: String] = [:]
    }

    /// What each pack is about, from its captures and live sources. Style packs are left out.
    static func index(packs: [Pack], sources: [(packID: UUID, source: PackSource)] = []) -> Index {
        var ix = Index()
        func add(_ k: Key, _ id: UUID, _ n: Int = 1) { ix.counts[k, default: [:]][id, default: 0] += n }
        // Addresses that show up in many packs are probably yours, so they aren't evidence.
        var emailPacks: [String: Set<UUID>] = [:]
        for p in packs where !p.isStyle {
            ix.names[p.id] = p.name
            for c in p.captures.suffix(400) {
                let found = emails(in: (c.title ?? "") + "\n" + c.text.prefix(8000), limit: 12)
                for e in found { emailPacks[e, default: []].insert(p.id) }
                let sig = RouteSignals(emails: found, url: c.url)
                for k in keys(for: sig) where k.kind != .url || c.sourceID != nil { add(k, p.id) }
            }
        }
        let crowded = Set(emailPacks.filter { $0.value.count >= 3 }.keys)
        for e in crowded {
            ix.counts[Key(kind: .email, value: e)] = nil
            if let d = domain(ofEmail: e) { ix.counts[Key(kind: .domain, value: d)] = nil }
        }
        for (pid, src) in sources {
            switch src.kind {
            case .folder: ix.folders.append((src.location, pid))
            case .github: add(Key(kind: .repo, value: "github.com/" + src.location.lowercased()), pid, 5)
            case .notion, .page, .web: if let n = normalizedURL(src.location) { add(Key(kind: .url, value: n), pid, 5) }
            case .mail: break
            }
        }
        return ix
    }

    // MARK: Picking

    /// The pack that fits these signals, or nil when nothing clearly does.
    static func suggest(_ s: RouteSignals, index ix: Index, learned: [String: UUID] = [:], valid: Set<UUID>) -> RouteSuggestion? {
        let ks = keys(for: s)
        var score: [UUID: Double] = [:]
        var why: [UUID: (Double, String)] = [:]
        func credit(_ id: UUID, _ amount: Double, _ reason: String) {
            guard valid.contains(id), amount > 0 else { return }
            score[id, default: 0] += amount
            if amount > (why[id]?.0 ?? 0) { why[id] = (amount, reason) }
        }
        let sender = s.emails.first
        for k in ks {
            // Your own earlier choice for this exact place wins.
            if let id = learned[k.raw] { credit(id, 6, "you used it here before") }
            if let packs = ix.counts[k] {
                let share = 1.0 / Double(packs.count)
                for (id, n) in packs {
                    let amount = k.weight * share * (0.6 + 0.4 * min(Double(n), 5) / 5)
                    credit(id, amount, reason(for: k, sender: sender, senderKnown: s.senderKnown))
                }
            }
            // A pack named after the company: "Acme" ↔ acme.com.
            if k.kind == .domain {
                let label = k.value.split(separator: ".").first.map(String.init) ?? ""
                if label.count >= 3 {
                    for (id, name) in ix.names where nameMatches(name, label) {
                        credit(id, 2.4, reason(for: k, sender: sender, senderKnown: s.senderKnown))
                    }
                }
            }
            if k.kind == .folder {
                for f in ix.folders where k.value == f.path || k.value.hasPrefix(f.path + "/") {
                    credit(f.packID, 4, "this file is in a folder linked to it")
                }
            }
        }
        let ranked = score.sorted { $0.value > $1.value }
        guard let best = ranked.first, best.value >= 2 else { return nil }
        if ranked.count > 1, ranked[1].value * 1.5 > best.value { return nil }
        return RouteSuggestion(packID: best.key, reason: why[best.key]?.1 ?? "it matches", score: best.value)
    }

    static func nameMatches(_ name: String, _ label: String) -> Bool {
        let words = name.lowercased().split { !($0.isLetter || $0.isNumber) }.map(String.init)
        return words.contains(label) || name.lowercased().replacingOccurrences(of: " ", with: "") == label
    }

    private static func reason(for k: Key, sender: String?, senderKnown: Bool) -> String {
        switch k.kind {
        case .email:
            return k.value == sender ? "the email is from \(k.value)" : "\(k.value) is on screen"
        case .domain:
            if let s = sender, domain(ofEmail: s) == k.value { return "the email is from someone at \(k.value)" }
            return "this is about \(k.value)"
        case .repo: return "this is the \(k.value.split(separator: "/").suffix(2).joined(separator: "/")) repo"
        case .url: return "this page is linked to it"
        case .folder: return "this file's folder is in it"
        case .host: return "you've saved pages from \(k.value) there"
        }
    }

    // MARK: Learning from your choices

    private static let learnedKey = "routeLearned"

    static func learned(_ defaults: UserDefaults = .standard) -> [String: UUID] {
        (defaults.dictionary(forKey: learnedKey) as? [String: String] ?? [:]).compactMapValues(UUID.init(uuidString:))
    }

    /// Remembers that you chose this pack here, so next time Shapr picks it for you.
    static func learn(_ s: RouteSignals, packID: UUID, defaults: UserDefaults = .standard) {
        var all = defaults.dictionary(forKey: learnedKey) as? [String: String] ?? [:]
        // Only the sender: your own address is on screen too, and must never point at one pack.
        var only = s
        only.emails = Array(s.emails.prefix(1))
        for k in keys(for: only) where k.kind != .host {
            // A free-mail address is a person, so it's fine; a free-mail domain was never a key.
            all[k.raw] = packID.uuidString
        }
        if all.count > 2000 { all = Dictionary(uniqueKeysWithValues: all.shuffled().prefix(1500).map { ($0.key, $0.value) }) }
        defaults.set(all, forKey: learnedKey)
    }

    static var enabled: Bool {
        get { UserDefaults.standard.object(forKey: "routeAuto") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "routeAuto") }
    }
}

// MARK: - Reading the signals from the screen

enum ScreenSignals {
    /// Reads who the email is from (and other addresses), the page or file in front. Runs off the main
    /// thread and gives up after `budget` seconds, so panels never wait long.
    static func read(app: NSRunningApplication?, url: String?, budget: TimeInterval = 0.45) async -> RouteSignals {
        guard let app else { return RouteSignals(url: url) }
        let pid = app.processIdentifier
        let bid = app.bundleIdentifier ?? ""
        var sig = await Task.detached(priority: .userInitiated) { () -> RouteSignals in
            var s = RouteSignals(url: url)
            let found = windowText(pid: pid, budget: budget)
            s.emails = PackRouter.emails(in: found.text, limit: 12)
            s.documentPath = found.document
            if s.url == nil, let web = found.webURL { s.url = web }
            return s
        }.value
        if bid == "com.apple.mail", let from = await MainActor.run(body: { mailSender() }) {
            sig.emails.removeAll { $0 == from }
            sig.emails.insert(from, at: 0)
            sig.senderKnown = true
        }
        return sig
    }

    /// The sender of the message selected in Apple Mail ("Ana <ana@acme.com>" → "ana@acme.com").
    @MainActor
    static func mailSender() -> String? {
        let script = """
        tell application id "com.apple.mail"
          set s to selection
          if (count of s) > 0 then return sender of item 1 of s
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err).stringValue else { return nil }
        return PackRouter.emails(in: out, limit: 1).first
    }

    /// Visible text of the focused window (titles, values, descriptions), the document it shows,
    /// and the web page address when there is one.
    static func windowText(pid: pid_t, budget: TimeInterval, maxNodes: Int = 3500) -> (text: String, document: String?, webURL: String?) {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.25)
        guard let win: AXUIElement = ax(app, kAXFocusedWindowAttribute) else { return ("", nil, nil) }
        let deadline = Date().addingTimeInterval(budget)
        var parts: [String] = []
        var chars = 0
        var visited = 0
        var webURL: String?
        let document: String? = ax(win, kAXDocumentAttribute)
        var stack: [AXUIElement] = [win]
        while let el = stack.popLast(), visited < maxNodes, chars < 60_000, Date() < deadline {
            visited += 1
            let role: String = ax(el, kAXRoleAttribute) ?? ""
            if role == "AXWebArea", webURL == nil, let u: URL = ax(el, "AXURL") { webURL = u.absoluteString }
            for key in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
                if let v: String = ax(el, key), !v.isEmpty, v.count < 2000 {
                    parts.append(v)
                    chars += v.count
                }
            }
            if role == "AXTextArea" || role == "AXTextField" { continue }
            let children: [AXUIElement] = ax(el, kAXChildrenAttribute) ?? []
            stack.append(contentsOf: children.reversed())
        }
        return (parts.joined(separator: "\n"), document, webURL)
    }

    private static func ax<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }
}

// MARK: - Using it

@MainActor
private enum RouteCache {
    static var index: PackRouter.Index?
    static var key = 0
}

@MainActor
extension PackStore {
    /// The pack that fits where you are right now, or nil.
    func suggestPack(for signals: RouteSignals) -> RouteSuggestion? {
        guard PackRouter.enabled, !signals.isEmpty else { return nil }
        return PackRouter.suggest(signals, index: routeIndex(), learned: PackRouter.learned(),
                                  valid: Set(packs.filter { !$0.isStyle }.map(\.id)))
    }

    /// The index, rebuilt only when packs, captures or sources change.
    private func routeIndex() -> PackRouter.Index {
        let sources = allSources()
        var h = Hasher()
        for p in packs { h.combine(p.id); h.combine(p.captures.count); h.combine(p.updated); h.combine(p.meta.role); h.combine(p.name) }
        for (pid, s) in sources { h.combine(pid); h.combine(s.id) }
        let key = h.finalize()
        if let cached = RouteCache.index, RouteCache.key == key { return cached }
        let ix = PackRouter.index(packs: packs, sources: sources)
        RouteCache.index = ix
        RouteCache.key = key
        return ix
    }

    /// Which pack a panel should open with: the router's pick when it's clear (and, with a pack equipped,
    /// only when the evidence is strong and says nothing for the equipped one), else the equipped pack.
    func packToUse(_ suggestion: RouteSuggestion?) -> (pack: Pack?, picked: RouteSuggestion?) {
        let equipped = pack(equippedPackID)
        let fallback = equipped ?? pack(activePackID) ?? packs.filter { !$0.isStyle }.max { $0.updated < $1.updated } ?? packs.first
        guard let s = suggestion, let p = pack(s.packID), p.id != fallback?.id else { return (fallback, nil) }
        if equipped == nil || s.isStrong { return (p, s) }
        return (fallback, nil)
    }
}

/// "Picked Acme because the email is from someone at acme.com · Use Bug #42"
struct PickedLine: View {
    let pack: Pack
    let reason: String
    let fallback: Pack?
    var onUndo: () -> Void = {}

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "wand.and.sparkles").font(.system(size: 11, weight: .medium)).foregroundStyle(DS.accent)
            (Text("Picked ") + Text(pack.name).fontWeight(.semibold) + Text(" because \(reason)"))
                .font(.dsMeta).foregroundStyle(DS.text2).lineLimit(1).truncationMode(.tail)
            Spacer(minLength: 4)
            if let f = fallback, f.id != pack.id {
                Button("Use \(f.name)", action: onUndo)
                    .buttonStyle(DSButtonStyle(kind: .plain, small: true))
                    .help("Use the pack you had on, and remember it for next time")
            }
        }
        .padding(.horizontal, DS.S.l).padding(.vertical, 5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(DS.accent.opacity(0.07))
        .accessibilityElement(children: .combine)
    }
}
