import Foundation

// MARK: - Context packages (provider-independent)

public struct ContextItem: Identifiable, Sendable, Equatable {
    public var id: UUID { record.id }
    public var record: MemoryRecord
    /// Why it was picked, in plain words ("matches what you circled", "your rule").
    public var reason: String
    public var included = true
}

public struct ContextPackage: Sendable, Equatable {
    public var taskTitle: String?
    public var taskTitleProvenance: Provenance?
    public var request: String
    public var items: [ContextItem]
    public var budget: Int

    /// Markdown any AI can read: numbered items, each with how Shapr knows it.
    public func rendered(includeRequest: Bool = true, now: Date = Date()) -> String {
        var s = ""
        if let t = taskTitle {
            s += "## Current task: \(t)"
            if let p = taskTitleProvenance, !p.isFact { s += " (\(p.label), not confirmed)" }
            s += "\n\n"
        }
        if includeRequest, !request.isEmpty {
            s += "### What the user selected\n" + request.split(separator: "\n", omittingEmptySubsequences: false).map { "> " + $0 }.joined(separator: "\n") + "\n\n"
        }
        let used = items.filter(\.included)
        if !used.isEmpty {
            s += "### Context from their work\n"
            for (i, item) in used.enumerated() { s += "[\(i + 1)] " + Self.line(item.record, now: now) + "\n" }
            s += "\nTags: observed = read from an app the user allowed; you said / confirmed = the user's own words; "
            s += "inferred / unverified = Shapr's guess, not a fact.\n"
        }
        return s
    }

    static func line(_ r: MemoryRecord, now: Date) -> String {
        let when = r.evidence.last.map { FlowFormat.when($0.at, now: now) }
        let app = r.evidence.last?.appName
        let tag = [r.provenance.label, app, when].compactMap { $0 }.joined(separator: " · ")
        var s = "(\(r.kind.heading.lowercased()); \(tag)) \(r.text)"
        if r.occurrences > 1 { s += " — seen \(r.occurrences) times" }
        return s
    }

    public var characterCount: Int { rendered().count }
}

public enum FlowFormat {
    public static func when(_ d: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { f.dateFormat = "h:mm a" }
        else if now.timeIntervalSince(d) < 6 * 24 * 3600 { f.dateFormat = "EEE h:mm a" }
        else { f.dateFormat = "MMM d" }
        return f.string(from: d)
    }

    public static func day(_ d: Date, now: Date) -> String {
        let cal = Calendar.current
        if cal.isDate(d, inSameDayAs: now) { return "Earlier today" }
        if let y = cal.date(byAdding: .day, value: -1, to: now), cal.isDate(d, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = now.timeIntervalSince(d) < 6 * 24 * 3600 ? "EEEE" : "MMM d"
        return "On " + f.string(from: d)
    }
}

public enum MemoryRetrieval {
    /// Picks what's relevant to `query` from the task's memory, within `budget` characters.
    /// Records from apps the user has since blocked are never returned.
    public static func retrieve(query: String, kernel: MemoryKernel, taskID: UUID?, isBlocked: (String) -> Bool,
                                budget: Int = 4000, now: Date = Date()) -> ContextPackage {
        let task = taskID.flatMap(kernel.task)
        var pool: [MemoryRecord] = []
        var seenKeys = Set<UInt64>()
        func add(_ r: MemoryRecord) {
            guard r.isCurrent, r.kind != .source, seenKeys.insert(r.key).inserted else { return }
            guard !r.evidence.contains(where: { $0.kind != .capture && $0.kind != .note && isBlocked($0.bundleID) }) else { return }
            pool.append(r)
        }
        if let id = taskID {
            kernel.records(for: id).forEach(add)
            for ep in kernel.episodes.reversed() where ep.taskID == id { ep.records.forEach(add) }
        }
        // From other work: only the exact same error, so unrelated tasks never leak in.
        let q = Text.stems(query)
        let qErrors = Set(Salience.lines(in: query).filter { $0.kind == .error }.map { MemoryRecord.key(kind: .error, text: $0.text) })
        for r in kernel.records + kernel.episodes.flatMap(\.records) where r.taskID != taskID && r.kind == .error && qErrors.contains(r.key) {
            add(r)
        }

        // Inverse document frequency over the pool.
        var df: [String: Int] = [:]
        let stemsByID = Dictionary(uniqueKeysWithValues: pool.map { ($0.id, Text.stems($0.text)) })
        for s in stemsByID.values { for t in s { df[t, default: 0] += 1 } }
        let n = Double(max(pool.count, 1))
        func score(_ r: MemoryRecord) -> (Double, String) {
            let st = stemsByID[r.id] ?? []
            let shared = q.intersection(st)
            var s = shared.reduce(0.0) { $0 + log(1 + n / Double(df[$1] ?? 1)) }
            var why = shared.isEmpty ? "" : "matches what you selected"
            if r.taskID != taskID { why = "the same error came up in other work"; s += 3 }
            switch r.kind {
            case .instruction: s += 6; if why.isEmpty { why = "your rule" }
            case .goal: s += 5; if why.isEmpty { why = "the task's goal" }
            case .decision: s += 3; if why.isEmpty { why = "a decision so far" }
            case .openQuestion: s += 2; if why.isEmpty { why = "still open" }
            case .attempt: s += 2; if why.isEmpty { why = "already tried" }
            case .nextStep: s += 2; if why.isEmpty { why = "the next step" }
            case .error: s += 1; if why.isEmpty { why = "seen while working" }
            case .note, .source: if why.isEmpty { why = "from this task" }
            }
            if r.pinned { s += 1 }
            s += max(0, 2 - now.timeIntervalSince(r.lastSeen) / 3600 / 12) // fresher is better, gently
            return (s, why)
        }
        let ranked = pool.map { ($0, score($0)) }.sorted { $0.1.0 > $1.1.0 }
        var items: [ContextItem] = []
        var used = (task?.title.count ?? 0) + query.count + 300
        for (r, (_, why)) in ranked {
            let cost = ContextPackage.line(r, now: now).count + 8
            if used + cost > budget { continue } // instructions are ranked first, so they fit first
            used += cost
            items.append(ContextItem(record: r, reason: why))
        }
        return ContextPackage(taskTitle: task?.title, taskTitleProvenance: task?.titleProvenance,
                              request: Text.clip(query, max(200, budget / 3)), items: items, budget: budget)
    }
}

// MARK: - Summaries and "Continue where you left off"

public struct SummaryLine: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var text: String
    public var provenance: Provenance
    public var evidence: [EvidenceRef]
}

public struct TaskSummary: Sendable, Equatable {
    public var task: TaskState
    public var sections: [(heading: String, records: [MemoryRecord])]
    public var resume: [SummaryLine]

    public static func == (a: TaskSummary, b: TaskSummary) -> Bool { a.task == b.task && a.resume == b.resume }

    /// Every sentence is backed by a stored record; nothing is said about outcomes Shapr didn't see.
    public static func build(task: TaskState, records all: [MemoryRecord], now: Date = Date()) -> TaskSummary {
        let rs = all.filter { $0.isCurrent && $0.taskID == task.id }
        let order: [MemoryRecord.Kind] = [.goal, .instruction, .decision, .attempt, .error, .openQuestion, .nextStep, .note]
        let sections = order.compactMap { k -> (String, [MemoryRecord])? in
            let g = rs.filter { $0.kind == k }.sorted { $0.lastSeen > $1.lastSeen }
            return g.isEmpty ? nil : (k.heading, g)
        }
        var lines: [SummaryLine] = []
        let last = rs.map(\.lastSeen).max() ?? task.lastActivity
        let titleTag = task.titleProvenance.isFact ? "" : " (Shapr's name for it)"
        lines.append(SummaryLine(text: "\(FlowFormat.day(last, now: now)) you were working on \(task.title)\(titleTag).",
                                 provenance: task.titleProvenance, evidence: []))
        if let g = rs.first(where: { $0.kind == .goal }) {
            lines.append(SummaryLine(text: "Goal: \(g.text)", provenance: g.provenance, evidence: g.evidence))
        }
        let attempts = rs.filter { $0.kind == .attempt }.sorted { $0.lastSeen < $1.lastSeen }
        if !attempts.isEmpty {
            let shown = attempts.suffix(2).map { Self.lowerFirst($0.text) }
            lines.append(SummaryLine(text: "You \(shown.joined(separator: " and ")).", provenance: weakest(attempts.suffix(2)),
                                     evidence: attempts.suffix(2).flatMap { $0.evidence.suffix(1) }))
        }
        if let err = rs.filter({ $0.kind == .error }).max(by: { $0.lastSeen < $1.lastSeen }) {
            let gist = Text.clip(err.text, 90)
            // Same read: a terminal shows the command, then its output, so the error came after it.
            if let lastAttempt = attempts.last, err.lastSeen >= lastAttempt.lastSeen {
                lines.append(SummaryLine(text: "“\(gist)” was still showing at \(FlowFormat.when(err.lastSeen, now: now)), after that.",
                                         provenance: .observed, evidence: Array(err.evidence.suffix(1))))
            } else if let lastAttempt = attempts.last {
                lines.append(SummaryLine(text: "“\(gist)” was last seen before \(Self.lowerFirst(lastAttempt.text)). Shapr didn't see whether it's fixed.",
                                         provenance: .observed, evidence: Array(err.evidence.suffix(1))))
            } else {
                lines.append(SummaryLine(text: "Unresolved when you stopped: “\(gist)”" + (err.occurrences > 1 ? " (seen \(err.occurrences) times)." : "."),
                                         provenance: .observed, evidence: Array(err.evidence.suffix(1))))
            }
        } else if let q = rs.first(where: { $0.kind == .openQuestion }) {
            lines.append(SummaryLine(text: "Open question: \(q.text)", provenance: q.provenance, evidence: q.evidence))
        }
        if let next = rs.filter({ $0.kind == .nextStep }).max(by: { $0.lastSeen < $1.lastSeen }) {
            var step = next.text
            for p in ["next step:", "next:", "todo:", "to do:"] where step.lowercased().hasPrefix(p) {
                step = String(step.dropFirst(p.count)).trimmingCharacters(in: .whitespaces)
            }
            lines.append(SummaryLine(text: "Your next step was to \(lowerFirst(step)).", provenance: next.provenance, evidence: next.evidence))
        }
        return TaskSummary(task: task, sections: sections, resume: lines)
    }

    static func weakest<S: Sequence>(_ rs: S) -> Provenance where S.Element == MemoryRecord {
        rs.map(\.provenance).min() ?? .observed
    }

    /// "Ran `x`" → "ran `x`"; "I checked the credentials." → "checked the credentials". Acronyms stay.
    static func lowerFirst(_ s: String) -> String {
        var s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        while let last = s.last, last == "." { s.removeLast() }
        if s.hasPrefix("Ran `") { return "ran `" + s.dropFirst(5) }
        for p in ["I ", "I've ", "We ", "We've "] where s.hasPrefix(p) { s = String(s.dropFirst(p.count)) }
        guard let f = s.first else { return s }
        if let second = s.dropFirst().first, second.isUppercase { return s }
        return f.lowercased() + s.dropFirst()
    }

    /// The task to offer when a session starts: the most recent paused one with something to say.
    public static func resumeCandidate(kernel: MemoryKernel, now: Date = Date(), within: TimeInterval = 7 * 24 * 3600) -> TaskSummary? {
        let paused = kernel.tasks.filter { $0.status == .paused && now.timeIntervalSince($0.lastActivity) < within }
            .sorted { $0.lastActivity > $1.lastActivity }
        for t in paused {
            var rs = kernel.records(for: t.id)
            if rs.isEmpty, let ep = kernel.episodes.last(where: { $0.taskID == t.id }) { rs = ep.records }
            if rs.contains(where: { $0.kind != .source && $0.kind != .note }) {
                return build(task: t, records: rs, now: now)
            }
        }
        return nil
    }
}

// MARK: - Simulate: evidence-grounded scenario exploration (not prediction)

public struct ScenarioLink: Sendable, Equatable, Identifiable {
    public var id: UUID { record.id }
    public var record: MemoryRecord
    public var why: String
}

public struct ScenarioPath: Sendable, Equatable {
    public var title: String
    public var consistentWith: [ScenarioLink] = []
    public var possibleTensions: [ScenarioLink] = []
    public var triedBefore: [ScenarioLink] = []
    public var assumptions: [String] = []
    public var questions: [ScenarioLink] = []
    public var hasEvidence: Bool { !(consistentWith.isEmpty && possibleTensions.isEmpty && triedBefore.isEmpty && questions.isEmpty) }
}

public struct ScenarioComparison: Sendable, Equatable {
    public var selection: String
    public var paths: [ScenarioPath]
    public var openForBoth: [ScenarioLink]
    public static let disclaimer = "Scenario exploration from your saved work — not a prediction. Nothing here was run or measured."
}

public enum ScenarioExplorer {
    private static let negations = ["don't", "do not", "never", "avoid", "without", "no ", "not ", "stop ", "remove", "drop "]

    static func negated(_ s: String) -> Bool { let t = " " + s.lowercased(); return negations.contains { t.contains($0) } }

    /// Links each path to the stored records it touches. Wording-based and deliberately cautious:
    /// "possible tension" means "check this", never "this will fail".
    public static func compare(selection: String, paths: [String], records: [MemoryRecord]) -> ScenarioComparison {
        let current = records.filter { $0.isCurrent && $0.kind != .source }
        var used = Set<UUID>()
        let selStems = Text.stems(selection)
        let out = paths.map { title -> ScenarioPath in
            var p = ScenarioPath(title: title)
            let own = Text.stems(title)
            let ps = own.union(selStems)
            for r in current {
                let rs = Text.stems(r.text)
                // Rules and decisions are judged on the path's own words; the selection only links evidence.
                let judged = [.instruction, .decision, .goal].contains(r.kind) ? own : ps
                let o = Text.overlap(judged, rs)
                guard o.shared >= 1, o.score >= 0.2 else { continue }
                let link = { (why: String) in ScenarioLink(record: r, why: why) }
                switch r.kind {
                case .instruction, .decision, .goal:
                    if negated(r.text) != negated(title) {
                        p.possibleTensions.append(link(r.kind == .instruction ? "your rule may rule this out" : "may go against an earlier decision"))
                    } else {
                        p.consistentWith.append(link(r.kind == .goal ? "serves the goal" : "in line with what you decided"))
                    }
                    used.insert(r.id)
                case .attempt:
                    p.triedBefore.append(link("something similar was tried")); used.insert(r.id)
                case .error:
                    p.questions.append(link("would this path change this error?")); used.insert(r.id)
                case .openQuestion:
                    p.questions.append(link("still open")); used.insert(r.id)
                case .nextStep, .note:
                    p.consistentWith.append(link("related note")); used.insert(r.id)
                case .source: break
                }
            }
            for r in current where (r.provenance == .inferred || r.provenance == .hypothesis) && p.consistentWith.contains(where: { $0.record.id == r.id }) {
                p.assumptions.append("Relies on “\(Text.clip(r.text, 80))”, which Shapr inferred and you haven't confirmed.")
            }
            if !p.hasEvidence { p.assumptions.append("Shapr has nothing saved about this path; everything about it is open.") }
            return p
        }
        let open = current.filter { ($0.kind == .openQuestion) && !used.contains($0.id) }.map { ScenarioLink(record: $0, why: "open either way") }
        return ScenarioComparison(selection: selection, paths: out, openForBoth: open)
    }
}

// MARK: - Suggestions: rare, grounded, dismissible

public struct Suggestion: Sendable, Equatable, Identifiable {
    public var id = UUID()
    public var title: String
    public var detail: String
    public var taskID: UUID?
    public var evidence: [EvidenceRef]
}

public final class SuggestionEngine {
    public var mode: AssistanceMode = .quiet
    private var lastShown: Date?
    private var shownThisSession = 0
    private var shownKeys = Set<UInt64>()

    public init() {}

    public func newSession() { shownThisSession = 0; shownKeys.removeAll() }

    /// After an observation was kept. Returns at most one suggestion, and usually none.
    public func consider(kernel: MemoryKernel, taskID: UUID?, wasPaused: Bool, now: Date) -> Suggestion? {
        guard mode != .quiet, let tid = taskID else { return nil }
        let (gap, cap): (TimeInterval, Int) = mode == .balanced ? (20 * 60, 3) : (5 * 60, 8)
        guard shownThisSession < cap, lastShown.map({ now.timeIntervalSince($0) >= gap }) ?? true else { return nil }

        // An error from an earlier session is back, and that session recorded what was tried.
        let freshErrors = kernel.records(for: tid).filter { $0.kind == .error && now.timeIntervalSince($0.lastSeen) < 5 }
        for err in freshErrors where !shownKeys.contains(err.key) {
            for ep in kernel.episodes.reversed() where ep.records.contains(where: { $0.key == err.key }) {
                let tried = ep.records.filter { $0.kind == .attempt }.sorted { $0.lastSeen < $1.lastSeen }
                guard let t = tried.last else { continue }
                shownKeys.insert(err.key)
                return shown(Suggestion(title: "You've seen this error before",
                                        detail: "\(FlowFormat.day(ep.endedAt, now: now)): \(Text.clip(err.text, 70)). Then you \(TaskSummary.lowerFirst(t.text)).",
                                        taskID: tid, evidence: Array(err.evidence.suffix(1)) + Array(t.evidence.suffix(1))), now)
            }
        }
        // Proactive only: back on a paused task.
        if mode == .proactive, wasPaused, let task = kernel.task(tid) {
            var h = FNV1a(); h.add("resume" + tid.uuidString)
            if shownKeys.insert(h.value).inserted {
                return shown(Suggestion(title: "Back on \(task.title)?", detail: "Shapr has your earlier attempts and open questions for it.",
                                        taskID: tid, evidence: []), now)
            }
        }
        return nil
    }

    private func shown(_ s: Suggestion, _ now: Date) -> Suggestion {
        lastShown = now
        shownThisSession += 1
        return s
    }
}

// MARK: - Instrumentation

/// Counters and timings, so resource use is measured rather than guessed.
public final class FlowMetrics: @unchecked Sendable {
    private let lock = NSLock()
    private var counters: [String: Int] = [:]
    private var timings: [String: [Double]] = [:]

    public init() {}

    public func count(_ name: String, by n: Int = 1) {
        lock.lock(); counters[name, default: 0] += n; lock.unlock()
    }

    public func record(_ name: String, ms: Double) {
        lock.lock()
        var a = timings[name, default: []]
        a.append(ms)
        if a.count > 200 { a.removeFirst(a.count - 200) }
        timings[name] = a
        lock.unlock()
    }

    public func time(_ name: String, since start: DispatchTime) {
        record(name, ms: Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000)
    }

    public func counter(_ name: String) -> Int { lock.lock(); defer { lock.unlock() }; return counters[name] ?? 0 }

    public struct Timing: Sendable { public var count: Int; public var averageMs: Double; public var p95Ms: Double }

    public func timing(_ name: String) -> Timing? {
        lock.lock(); defer { lock.unlock() }
        guard let a = timings[name], !a.isEmpty else { return nil }
        let s = a.sorted()
        return Timing(count: a.count, averageMs: a.reduce(0, +) / Double(a.count), p95Ms: s[min(s.count - 1, Int(Double(s.count) * 0.95))])
    }

    public var report: String {
        lock.lock()
        let c = counters.sorted { $0.key < $1.key }
        let names = timings.keys.sorted()
        lock.unlock()
        var lines = c.map { "\($0.key): \($0.value)" }
        for n in names { if let t = timing(n) { lines.append(String(format: "%@: %d runs, avg %.3f ms, p95 %.3f ms", n, t.count, t.averageMs, t.p95Ms)) } }
        return lines.joined(separator: "\n")
    }
}
