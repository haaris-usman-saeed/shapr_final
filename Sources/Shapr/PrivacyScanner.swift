import Foundation
import NaturalLanguage

enum FlagKind: String, Codable, CaseIterable {
    case secret, card, email, phone, address, ipAddress, secretURL, internalURL, person, organization, place

    var label: String {
        switch self {
        case .secret: return "Secret / API key"
        case .card: return "Card number"
        case .email: return "Email"
        case .phone: return "Phone"
        case .address: return "Address"
        case .ipAddress: return "IP address"
        case .secretURL: return "Link with token"
        case .internalURL: return "Internal link"
        case .person: return "Person"
        case .organization: return "Organization"
        case .place: return "Place"
        }
    }

    var placeholder: String {
        switch self {
        case .secret: return "[secret]"
        case .card: return "[card number]"
        case .email: return "[email]"
        case .phone: return "[phone]"
        case .address: return "[address]"
        case .ipAddress: return "[ip]"
        case .secretURL, .internalURL: return "[link]"
        case .person: return "[name]"
        case .organization: return "[organization]"
        case .place: return "[place]"
        }
    }

    /// Lower = checked first; overlapping matches keep the higher-priority kind.
    var priority: Int { FlagKind.allCases.firstIndex(of: self)! }

    /// Companies and places are usually the point of research (Toyota, Tokyo), so they start as Keep.
    var defaultAction: RedactAction {
        switch self {
        case .organization, .place: return .keep
        case .internalURL: return .remove
        default: return .replace
        }
    }
}

enum RedactAction: String, Codable, CaseIterable {
    case keep, replace, remove
    var title: String { rawValue.capitalized }
}

enum FlagField: String, Codable { case text, title, url }

struct PrivacyFlag: Identifiable, Hashable {
    let captureID: UUID
    let field: FlagField
    let range: NSRange
    let match: String
    let kind: FlagKind
    let context: String
    var action: RedactAction
    var replacement: String
    var remembered = false

    var id: String { "\(captureID)|\(field.rawValue)|\(range.location)|\(range.length)" }
    var ruleKey: String { "\(kind.rawValue)|\(match.lowercased())" }
}

/// Choices from earlier shares of a pack, so re-sharing only asks about new things.
struct RedactionRules: Codable {
    struct Rule: Codable {
        var action: RedactAction
        var replacement: String
    }
    var rules: [String: Rule] = [:]
    var excludedCaptures: Set<UUID> = []
    var reviewedCaptures: Set<UUID> = []
}

enum PrivacyScanner {
    private struct Hit {
        let range: NSRange
        let kind: FlagKind
    }

    private static let patterns: [(FlagKind, String)] = [
        (.secret, #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#),
        (.secret, #"\bsk-(?:ant-)?[A-Za-z0-9_\-]{16,}"#),
        (.secret, #"\bgh[pousr]_[A-Za-z0-9]{20,}\b"#),
        (.secret, #"\bgithub_pat_[A-Za-z0-9_]{20,}\b"#),
        (.secret, #"\bAKIA[0-9A-Z]{16}\b"#),
        (.secret, #"\bxox[abprs]-[A-Za-z0-9\-]{10,}"#),
        (.secret, #"\bAIza[0-9A-Za-z_\-]{35}\b"#),
        (.secret, #"\beyJ[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}\.[A-Za-z0-9_\-]{10,}"#),
        (.secret, #"(?i)\b(?:api[_-]?key|secret|token|passw(?:or)?d|pwd)\b\s*[:=]\s*["']?[^\s"']{6,}"#),
        (.email, #"\b[A-Za-z0-9._%+\-]+@[A-Za-z0-9.\-]+\.[A-Za-z]{2,}\b"#),
        (.card, #"\b(?:\d[ \-]?){12,18}\d\b"#),
        (.ipAddress, #"\b(?:(?:25[0-5]|2[0-4]\d|1?\d?\d)\.){3}(?:25[0-5]|2[0-4]\d|1?\d?\d)\b"#),
    ]

    private static let compiled: [(FlagKind, NSRegularExpression)] = patterns.compactMap { kind, p in
        (try? NSRegularExpression(pattern: p)).map { (kind, $0) }
    }

    private static let sensitiveQueryKeys: Set<String> = [
        "token", "access_token", "id_token", "key", "apikey", "api_key", "sig", "signature", "session",
        "sessionid", "auth", "code", "password", "secret", "x-amz-signature", "x-amz-credential",
    ]

    // MARK: Scan

    static func scan(_ captures: [Capture], rules: RedactionRules) -> [PrivacyFlag] {
        var flags: [PrivacyFlag] = []
        for c in captures {
            flags += scanText(c.text, captureID: c.id, field: .text, rules: rules)
            if let t = c.title { flags += scanText(t, captureID: c.id, field: .title, rules: rules) }
            if let u = c.url, let f = scanURL(u, captureID: c.id, rules: rules) { flags.append(f) }
        }
        return flags
    }

    static func scanText(_ text: String, captureID: UUID, field: FlagField, rules: RedactionRules) -> [PrivacyFlag] {
        let ns = text as NSString
        let full = NSRange(location: 0, length: ns.length)
        var hits: [Hit] = []

        for (kind, re) in compiled {
            for m in re.matches(in: text, range: full) {
                if kind == .card && !luhn(ns.substring(with: m.range)) { continue }
                hits.append(Hit(range: trimTrailingPunctuation(m.range, in: ns), kind: kind))
            }
        }

        let types: NSTextCheckingResult.CheckingType = [.phoneNumber, .address]
        if let detector = try? NSDataDetector(types: types.rawValue) {
            for m in detector.matches(in: text, range: full) {
                switch m.resultType {
                case .phoneNumber: hits.append(Hit(range: m.range, kind: .phone))
                case .address: hits.append(Hit(range: m.range, kind: .address))
                default: break
                }
            }
        }

        // Links (our own pattern, so made-up TLDs like .internal are caught too).
        for m in urlPattern.matches(in: text, range: full) {
            let r = trimTrailingPunctuation(m.range, in: ns)
            guard let url = URL(string: ns.substring(with: r)) else { continue }
            if isInternal(url) { hits.append(Hit(range: r, kind: .internalURL)) }
            else if hasSensitiveQuery(url) { hits.append(Hit(range: r, kind: .secretURL)) }
        }

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        var names: [Hit] = []
        tagger.enumerateTags(in: text.startIndex..<text.endIndex, unit: .word, scheme: .nameType,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, r in
            let kind: FlagKind?
            switch tag {
            case .personalName?: kind = .person
            case .organizationName?: kind = .organization
            case .placeName?: kind = .place
            default: kind = nil
            }
            guard let kind else { return true }
            var nr = NSRange(r, in: text)
            if kind == .person { nr = extendSurname(nr, in: ns) }
            // Join "Jane" + "Doe" into one name when only spaces separate them.
            if let last = names.last, last.kind == kind,
               ns.substring(with: NSRange(location: NSMaxRange(last.range), length: nr.location - NSMaxRange(last.range)))
                   .trimmingCharacters(in: .whitespaces).isEmpty {
                names[names.count - 1] = Hit(range: NSUnionRange(last.range, nr), kind: kind)
            } else {
                names.append(Hit(range: nr, kind: kind))
            }
            return true
        }
        hits += names

        // Where matches overlap, the longer one wins (a whole link beats the token inside it);
        // equal lengths go to the more sensitive kind.
        hits.sort { $0.range.length != $1.range.length ? $0.range.length > $1.range.length
                                                        : $0.kind.priority < $1.kind.priority }
        var accepted: [Hit] = []
        for h in hits where !accepted.contains(where: { NSIntersectionRange($0.range, h.range).length > 0 }) {
            accepted.append(h)
        }
        accepted.sort { $0.range.location < $1.range.location }

        return accepted.map { h in
            let match = ns.substring(with: h.range)
            var f = PrivacyFlag(captureID: captureID, field: field, range: h.range, match: match, kind: h.kind,
                                context: context(ns, h.range), action: h.kind.defaultAction,
                                replacement: h.kind.placeholder)
            if let rule = rules.rules[f.ruleKey] {
                f.action = rule.action
                f.replacement = rule.replacement
                f.remembered = true
            }
            return f
        }
    }

    static func scanURL(_ s: String, captureID: UUID, rules: RedactionRules) -> PrivacyFlag? {
        guard let url = URL(string: s), url.scheme == "http" || url.scheme == "https" else { return nil }
        let kind: FlagKind
        var replacement = FlagKind.secretURL.placeholder
        if isInternal(url) {
            kind = .internalURL
        } else if hasSensitiveQuery(url) {
            kind = .secretURL
            var comps = URLComponents(url: url, resolvingAgainstBaseURL: false)
            comps?.query = nil
            comps?.fragment = nil
            replacement = comps?.string ?? replacement
        } else {
            return nil
        }
        var f = PrivacyFlag(captureID: captureID, field: .url, range: NSRange(location: 0, length: (s as NSString).length),
                            match: s, kind: kind, context: "Source link", action: kind.defaultAction,
                            replacement: replacement)
        if let rule = rules.rules[f.ruleKey] {
            f.action = rule.action
            f.replacement = rule.replacement
            f.remembered = true
        }
        return f
    }

    // MARK: Apply

    /// The shared version of one capture. The original stays untouched on disk.
    static func apply(_ flags: [PrivacyFlag], to c: Capture) -> Capture {
        var out = c
        let mine = flags.filter { $0.captureID == c.id && $0.action != .keep }
        out.text = applyField(c.text, mine.filter { $0.field == .text })
        if let t = c.title { out.title = applyField(t, mine.filter { $0.field == .title }).nonEmpty }
        if let f = mine.first(where: { $0.field == .url }) {
            out.url = f.action == .remove ? nil : f.replacement.nonEmpty
        }
        return out
    }

    private static func applyField(_ s: String, _ flags: [PrivacyFlag]) -> String {
        let m = NSMutableString(string: s)
        for f in flags.sorted(by: { $0.range.location > $1.range.location })
        where NSMaxRange(f.range) <= m.length {
            m.replaceCharacters(in: f.range, with: f.action == .remove ? "" : f.replacement)
        }
        return (m as String).replacingOccurrences(of: "  ", with: " ")
    }

    // MARK: Helpers

    private static let urlPattern = try! NSRegularExpression(pattern: #"https?://[^\s<>"'`)\]]+"#)

    private static let surnamePattern = try! NSRegularExpression(pattern: #"\G(?:[ \t]+[A-Z][\p{L}'\-]+){1,2}"#)
    private static let notSurnames: Set<String> = ["The", "I", "And", "From", "At", "In", "On", "To", "Is", "Was", "Here", "Thanks"]

    /// The name tagger often marks only the first name ("Jane" in "Jane Doe"); take the
    /// capitalized words right after it as the rest of the name.
    private static func extendSurname(_ r: NSRange, in ns: NSString) -> NSRange {
        let start = NSMaxRange(r)
        guard start < ns.length,
              let m = surnamePattern.firstMatch(in: ns as String, options: .anchored,
                                                range: NSRange(location: start, length: ns.length - start))
        else { return r }
        var end = start
        for word in ns.substring(with: m.range).split(separator: " ") {
            let w = String(word).trimmingCharacters(in: .whitespaces)
            if notSurnames.contains(w) { break }
            end = ns.range(of: w, range: NSRange(location: end, length: ns.length - end)).upperBound
        }
        return NSRange(location: r.location, length: end - r.location)
    }

    private static func trimTrailingPunctuation(_ r: NSRange, in ns: NSString) -> NSRange {
        var r = r
        while r.length > 1, let u = UnicodeScalar(ns.character(at: NSMaxRange(r) - 1)),
              ".,;:!?)]}>\"'".unicodeScalars.contains(u) {
            r.length -= 1
        }
        return r
    }

    private static func context(_ ns: NSString, _ r: NSRange) -> String {
        let start = max(0, r.location - 40)
        let end = min(ns.length, NSMaxRange(r) + 40)
        var s = ns.substring(with: NSRange(location: start, length: end - start)).singleLine
        if start > 0 { s = "…" + s }
        if end < ns.length { s += "…" }
        return s
    }

    static func isInternal(_ url: URL) -> Bool {
        guard let host = url.host?.lowercased() else { return false }
        if host == "localhost" || host.hasPrefix("127.") || host.hasPrefix("10.") || host.hasPrefix("192.168.") {
            return true
        }
        if host.hasPrefix("172."), let second = host.split(separator: ".").dropFirst().first.flatMap({ Int($0) }),
           (16...31).contains(second) { return true }
        return [".local", ".internal", ".corp", ".lan", ".intranet", ".home.arpa"].contains { host.hasSuffix($0) }
            || !host.contains(".")
    }

    static func hasSensitiveQuery(_ url: URL) -> Bool {
        let items = URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? []
        return items.contains { sensitiveQueryKeys.contains($0.name.lowercased()) }
    }

    static func luhn(_ s: String) -> Bool {
        let digits = s.compactMap { $0.wholeNumberValue }
        guard (13...19).contains(digits.count) else { return false }
        var sum = 0
        for (i, d) in digits.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }
}
