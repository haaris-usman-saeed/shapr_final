import Foundation

/// Apps Shapr Flow never observes, whatever the user grants: password managers, the system's
/// login and authentication prompts, and Shapr itself.
public enum SensitiveApps {
    public static let neverObserved: Set<String> = [
        "com.1password.1password", "com.agilebits.onepassword7", "com.agilebits.onepassword-osx",
        "com.bitwarden.desktop", "com.lastpass.LastPass", "com.dashlane.Dashlane", "com.keepassxc.keepassxc",
        "com.apple.keychainaccess", "com.apple.Passwords",
        "com.apple.SecurityAgent", "com.apple.loginwindow", "com.apple.LocalAuthentication.UIAgent",
        "com.apple.CoreAuthUI", "com.apple.ScreenSaver.Engine", "com.apple.UserNotificationCenter",
        "app.shapr.Shapr",
    ]

    public static func isNeverObserved(_ bundleID: String) -> Bool {
        neverObserved.contains(bundleID) || bundleID.lowercased().contains("password")
    }

    /// Window titles that mean "don't read this": private browsing, password and sign-in dialogs.
    public static func titleIsPrivate(_ title: String?) -> Bool {
        guard let t = title?.lowercased() else { return false }
        return ["private browsing", "incognito", "inprivate", "password", "passcode", "sign in", "log in",
                "two-factor", "verification code", "keychain"].contains { t.contains($0) }
    }
}

/// Removes secrets from text before it is kept anywhere. Detection is pattern-based and can miss
/// things; it is a second line of defence behind app authorization, not a guarantee.
public enum Redactor {
    public static let mark = "[redacted]"

    private static let patterns: [NSRegularExpression] = [
        // Private keys
        #"-----BEGIN [A-Z ]*PRIVATE KEY-----[\s\S]*?-----END [A-Z ]*PRIVATE KEY-----"#,
        // Provider tokens
        #"\b(sk-[A-Za-z0-9_\-]{16,}|sk-ant-[A-Za-z0-9_\-]{16,}|gh[pousr]_[A-Za-z0-9]{20,}|github_pat_[A-Za-z0-9_]{20,}|xox[abprs]-[A-Za-z0-9\-]{10,}|AKIA[0-9A-Z]{16}|AIza[0-9A-Za-z_\-]{30,}|glpat-[A-Za-z0-9_\-]{16,})"#,
        // JWTs
        #"\beyJ[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}\.[A-Za-z0-9_\-]{8,}"#,
        // Credentials in connection strings: scheme://user:password@host
        #"(?<=://)[^\s/:@]+:[^\s/@]+(?=@)"#,
        // key=value secrets
        #"(?i)\b(password|passwd|pwd|secret|api[_-]?key|access[_-]?token|auth[_-]?token|client[_-]?secret|private[_-]?key|token)\b\s*[:=]\s*["']?[^\s"',;]{4,}"#,
        // Bearer headers
        #"(?i)\bbearer\s+[A-Za-z0-9_\-\.=]{12,}"#,
        // Long hex/base64 blobs that look like keys
        #"\b(?=[A-Za-z0-9+/_\-]*[0-9])(?=[A-Za-z0-9+/_\-]*[A-Za-z])[A-Za-z0-9+/_\-]{40,}={0,2}"#,
        // US SSNs
        #"\b\d{3}-\d{2}-\d{4}\b"#,
    ].map { try! NSRegularExpression(pattern: $0) }

    private static let digits = try! NSRegularExpression(pattern: #"\b(?:\d[ -]?){13,19}\b"#)

    public static func scrub(_ text: String) -> (text: String, count: Int) {
        var s = text
        var n = 0
        for re in patterns {
            let range = NSRange(s.startIndex..., in: s)
            let matches = re.matches(in: s, range: range)
            guard !matches.isEmpty else { continue }
            n += matches.count
            s = re.stringByReplacingMatches(in: s, range: range, withTemplate: mark)
        }
        // Card numbers: only digit runs that pass the Luhn check.
        let range = NSRange(s.startIndex..., in: s)
        for m in digits.matches(in: s, range: range).reversed() {
            guard let r = Range(m.range, in: s) else { continue }
            let ds = s[r].compactMap(\.wholeNumberValue)
            if ds.count >= 13, luhn(ds) { s.replaceSubrange(r, with: mark); n += 1 }
        }
        return (s, n)
    }

    static func luhn(_ ds: [Int]) -> Bool {
        var sum = 0
        for (i, d) in ds.reversed().enumerated() {
            if i % 2 == 1 { let x = d * 2; sum += x > 9 ? x - 9 : x } else { sum += d }
        }
        return sum % 10 == 0
    }
}

/// Deterministic, explainable rules for what is worth remembering. No model, no made-up confidence.
public enum Salience {
    public struct Line: Equatable, Sendable {
        public enum Kind: String, Sendable { case error, command }
        public var kind: Kind
        public var text: String
    }

    private static let errorWords = try! NSRegularExpression(pattern:
        #"(?i)(\berror\b|\bexception\b|traceback|\bfatal\b|\bpanic\b|\bfailed\b|\bfailure\b|refused|\bdenied\b|\btimed? ?out\b|cannot |can't |could not|couldn't|unable to|not found|undefined|\bnull\b.*\b(reference|pointer)|segmentation fault|ECONN[A-Z]+|ENOENT|EADDRINUSE|\b[45]\d\d (bad|not|internal|service|unauthori|forbidden))"#)
    private static let noise = try! NSRegularExpression(pattern:
        #"(?i)^(errors?|warnings?|problems?|output|debug console|0 errors?.*|no errors.*|error lens.*|errors? and warnings?)$"#)
    private static let prompt = try! NSRegularExpression(pattern: #"^(?:[\w.@-]+[:\s][^\n$%#>]{0,80})?[$%#❯>]\s+(\S.{1,200})$"#)

    /// The lines worth keeping from a window's text: error messages and recent shell commands.
    /// Everything else is dropped before anything is stored.
    public static func lines(in text: String, maxLines: Int = 5) -> [Line] {
        var errors: [Line] = []
        var commands: [Line] = []
        var seen = Set<String>()
        let all = text.split(whereSeparator: \.isNewline).suffix(4000)
        for raw in all {
            let line = raw.trimmingCharacters(in: .whitespaces)
            guard line.count >= 6, line.count <= 400 else { continue }
            let range = NSRange(line.startIndex..., in: line)
            if let m = prompt.firstMatch(in: line, range: range), let r = Range(m.range(at: 1), in: line) {
                let cmd = String(line[r]).trimmingCharacters(in: .whitespaces)
                if cmd.count >= 2, seen.insert("c" + cmd).inserted { commands.append(Line(kind: .command, text: cmd)) }
                continue
            }
            guard noise.firstMatch(in: line, range: range) == nil,
                  errorWords.firstMatch(in: line, range: range) != nil else { continue }
            let key = FlowText.normalized(line, maskNumbers: true)
            if seen.insert("e" + key).inserted { errors.append(Line(kind: .error, text: line)) }
        }
        // The most recent ones: the bottom of a terminal or log is the newest.
        return Array(errors.suffix(maxLines)) + Array(commands.suffix(3))
    }

    /// What kind of statement the user made, from its wording. Used for Threads ("remember this").
    public static func classify(_ text: String) -> MemoryRecord.Kind {
        let t = text.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        func has(_ words: [String]) -> Bool { words.contains { t.contains($0) } }
        if has(["don't ", "do not ", "never ", "always ", "must ", "must not", "make sure", "only use", "avoid "]) { return .instruction }
        if has(["we decided", "decided to", "decision:", "let's use", "lets use", "going with", "we'll use", "we will use", "switch to", "chose ", "settled on"]) { return .decision }
        if has(["next step", "next:", "todo:", "to do:", "then i'll", "i need to", "need to check"]) { return .nextStep }
        if has(["i tried", "tried ", "i checked", "checked ", "restarted", "i changed", "attempted", "reinstalled", "i ran", "already "]) { return .attempt }
        if t.hasSuffix("?") || has(["why does", "why is", "how do", "is it ", "should we", "which "]) { return .openQuestion }
        if !lines(in: text, maxLines: 1).filter({ $0.kind == .error }).isEmpty { return .error }
        if has(["goal:", "i'm trying to", "im trying to", "i am trying to", "trying to get", "the goal is"]) { return .goal }
        return .note
    }

    /// Words that suggest an observed command is an attempt to fix something.
    public static func looksLikeAttempt(_ command: String) -> Bool {
        let c = command.lowercased()
        // Changing something, not just re-running it: "npm run dev" reproduces an error, it doesn't fix it.
        return ["restart", "migrate", "install", "reset", "export ", "set ", "psql ", "brew services", "docker run",
                "docker compose up", "docker-compose up", "systemctl", "service ", "kill", "chmod", "chown", "git checkout",
                "git pull", "git stash", "git revert", "git reset", "source ", "createdb", "dropdb", "rm -rf node_modules",
                "npm ci", "cp .env", "mv "].contains { c.contains($0) }
    }
}
