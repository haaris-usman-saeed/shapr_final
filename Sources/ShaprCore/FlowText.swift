import Foundation

/// 64-bit FNV-1a: a fast, stable fingerprint for de-duplication (not for security).
public struct FNV1a {
    public private(set) var value: UInt64 = 0xcbf2_9ce4_8422_2325
    public init() {}
    public mutating func add(_ s: String) {
        for b in s.utf8 { value ^= UInt64(b); value = value &* 0x0000_0100_0000_01b3 }
        value ^= 0xff; value = value &* 0x0000_0100_0000_01b3 // field separator
    }
}

public enum Text {
    static let stopwords: Set<String> = [
        "the", "and", "for", "are", "but", "not", "you", "your", "all", "any", "can", "had", "her", "was", "one", "our", "out",
        "has", "have", "him", "his", "how", "its", "may", "new", "now", "old", "see", "two", "way", "who", "did", "get", "got",
        "let", "say", "she", "too", "use", "with", "this", "that", "from", "they", "will", "would", "there", "their", "what",
        "about", "which", "when", "make", "like", "just", "into", "than", "then", "them", "these", "some", "could", "other",
        "been", "were", "here", "more", "also", "only", "very", "after", "before", "should", "while", "where", "does", "each",
        "why", "yes", "off", "via", "per", "www", "com", "http", "https", "html", "org", "net", "edu", "app", "file", "line",
        "window", "untitled", "home", "page", "new tab", "google", "search", "visual", "studio", "code", "safari", "chrome",
        "terminal", "xcode", "edited", "documentation", "docs",
    ]

    /// Lowercase terms worth matching on: no stopwords, no pure numbers, at least 3 characters.
    public static func terms(_ s: String, limit: Int = 400) -> [String] {
        var out: [String] = []
        var cur = ""
        func flush() {
            defer { cur = "" }
            guard cur.count >= 3, cur.count <= 40, !stopwords.contains(cur), cur.contains(where: \.isLetter) else { return }
            out.append(cur)
        }
        for ch in s.lowercased() {
            if ch.isLetter || ch.isNumber || ch == "_" { cur.append(ch) } else { flush() }
            if out.count >= limit { break }
        }
        flush()
        return out
    }

    /// Terms reduced to a short stem, so "postgres" matches "PostgreSQL" and "connection" matches "connecting".
    public static func stems(_ s: String) -> Set<String> {
        Set(terms(s).map { String($0.prefix(6)) })
    }

    /// Lowercased, single-spaced; optionally with numbers masked so "line 41" and "line 42" match.
    public static func normalized(_ s: String, maskNumbers: Bool = false) -> String {
        var out = ""
        var lastSpace = true
        var inNumber = false
        for ch in s.lowercased() {
            if ch.isWhitespace {
                if !lastSpace { out.append(" ") }
                lastSpace = true
                inNumber = false
                continue
            }
            lastSpace = false
            if maskNumbers, ch.isNumber {
                if !inNumber { out.append("#") }
                inNumber = true
                continue
            }
            inNumber = false
            out.append(ch)
        }
        return out.trimmingCharacters(in: .whitespaces)
    }

    /// |A∩B| / min(|A|,|B|): how much of the smaller side the larger one covers.
    public static func overlap(_ a: Set<String>, _ b: Set<String>) -> (score: Double, shared: Int) {
        guard !a.isEmpty, !b.isEmpty else { return (0, 0) }
        let n = a.intersection(b).count
        return (Double(n) / Double(min(a.count, b.count)), n)
    }

    /// A web address without its query and fragment, which often hold tokens.
    public static func stripQuery(_ url: String?) -> String? {
        guard let url, !url.isEmpty else { return nil }
        var s = url
        if let i = s.firstIndex(where: { $0 == "?" || $0 == "#" }) { s = String(s[..<i]) }
        return s
    }

    public static func clip(_ s: String, _ n: Int) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= n ? t : String(t.prefix(n - 1)) + "…"
    }

    public static func firstLine(_ s: String) -> String {
        s.split(whereSeparator: \.isNewline).first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
    }
}

// MARK: - Project identity

public enum ProjectKeys {
    static let ignoredSegments: Set<String> = ["xcode", "terminal", "zsh", "bash", "fish", "sh", "login", "inbox", "messages",
                                               "untitled", "welcome", "settings", "preferences", "home", "start", "new-tab",
                                               "readme", "localhost", "docs", "documentation"]
    /// Repositories, folders and file names that identify what a window is about.
    /// "app.js — shapr_final — Visual Studio Code" → ["proj:shapr_final", "file:app.js"].
    public static func from(title: String?, url: String?, documentPath: String?, projectHint: String?, appName: String) -> [String] {
        var keys: [String] = []
        func add(_ k: String) { if !keys.contains(k) { keys.append(k) } }
        if let p = projectHint?.trimmingCharacters(in: .whitespaces), !p.isEmpty { add("proj:" + p.lowercased()) }
        if let u = url.flatMap(URL.init(string:)), let host = u.host?.lowercased() {
            let parts = u.path.split(separator: "/").map(String.init)
            if (host == "github.com" || host == "gitlab.com" || host == "bitbucket.org"), parts.count >= 2 {
                add("repo:\(parts[0].lowercased())/\(parts[1].lowercased())")
                add("proj:" + parts[1].lowercased())
            } else if host == "localhost" || host == "127.0.0.1" {
                add("host:localhost:\(u.port ?? 80)")
            }
        }
        if let d = documentPath, !d.isEmpty {
            let comps = d.split(separator: "/").map(String.init)
            if let f = comps.last { add("file:" + f.lowercased()) }
        }
        if let t = title {
            let app = appName.lowercased()
            let separators = [" — ", " – ", " - ", " · ", " | "]
            var segments = [t]
            for sep in separators { segments = segments.flatMap { $0.components(separatedBy: sep) } }
            for raw in segments {
                let s = raw.trimmingCharacters(in: CharacterSet.whitespaces.union(CharacterSet(charactersIn: "●•*")))
                let low = s.lowercased()
                guard !s.isEmpty, low != app, !low.hasPrefix(app), !app.hasPrefix(low), s.count <= 60 else { continue }
                if low.hasSuffix("visual studio code") || ignoredSegments.contains(low) || low.contains("×") { continue }
                if !s.contains(" "), let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 6, s.distance(from: s.startIndex, to: dot) >= 1 {
                    add("file:" + low)
                } else if !s.contains(" "), s.count >= 3, s.contains(where: \.isLetter),
                          s.contains(where: { $0 == "_" || $0 == "-" }) || s == low {
                    add("proj:" + low)
                }
            }
        }
        return keys
    }
}
