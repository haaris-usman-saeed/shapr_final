import Foundation

// MARK: - From a chat to saved progress, without an AI

/// Turns a conversation into a checkpoint on this Mac. Your own words are kept exactly: the rules you
/// gave ("don't use numpy", "the prof wants it as a table") are never paraphrased. The AI's long
/// answers are shortened, except code and final answers.
enum ChatDigest {
    static func sentences(_ s: String) -> [String] {
        var out: [String] = []
        for line in withoutCode(s).components(separatedBy: "\n") where line.nonEmpty != nil {
            line.enumerateSubstrings(in: line.startIndex..., options: .bySentences) { sub, _, _, _ in
                if let t = sub?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty { out.append(t) }
            }
        }
        return out
    }

    static func withoutCode(_ s: String) -> String {
        s.replacingOccurrences(of: #"```[\s\S]*?```"#, with: "\n", options: .regularExpression)
    }

    private static func matches(_ s: String, _ pattern: String) -> Bool {
        s.range(of: pattern, options: [.regularExpression, .caseInsensitive]) != nil
    }

    static let rulePattern = #"\b(don'?t|do not|never|avoid|without|not allowed|can'?t use|cannot use|shouldn'?t|should not|no more than|must|have to|has to|needs? to be|make sure|always|only use|only|exactly|at most|at least|keep it|in (the )?format|format (it|as)|instead of|prefer|i want (it|you|the)|i'd like (it|you)|wants? (it|the|us|you|answers|everything)|please (use|write|keep|make|explain|show|stick)|stick to|word limit|words or less|in (python|java|swift|c\+\+|javascript|typescript|latex|markdown|bullet points|a table))\b"#
    static let negation = #"\b(don'?t|do not|never|avoid|without|not|no|can'?t|cannot|shouldn'?t|instead of)\b"#

    /// Sentences from your messages that tell the AI how to work, word for word, oldest first.
    static func rules(from t: ChatTranscript) -> [String] {
        var out: [String] = []
        var seen = Set<String>()
        for turn in t.userTurns {
            // Long pastes are material, not instructions; only their first lines can be.
            let text = turn.text.count > 1500 ? String(turn.text.prefix(400)) : turn.text
            for s in sentences(text) where s.count >= 8 && s.count <= 260 && matches(s, rulePattern) {
                let key = s.lowercased().singleLine
                if seen.insert(key).inserted { out.append(s.singleLine) }
            }
        }
        return Array(out.prefix(12))
    }

    static func checkpoint(from t: ChatTranscript, previous: Checkpoint? = nil) -> Checkpoint {
        var cp = Checkpoint()
        let users = t.userTurns
        let firstUser = users.first.map { sentences(String($0.text.prefix(1500))) } ?? []
        cp.title = t.title ?? firstUser.first.map { $0.singleLine.truncated(60) } ?? previous?.title
        cp.goal = firstUser.first.map { $0.singleLine.truncated(220) } ?? previous?.goal ?? ""

        func pick(_ turns: [ChatTurn], _ pattern: String, limit: Int) -> [Checkpoint.Point] {
            var out: [Checkpoint.Point] = []
            var seen = Set<String>()
            for turn in turns.reversed() {
                for s in sentences(String(turn.text.prefix(3000))).reversed() where s.count >= 10 && s.count <= 260 && matches(s, pattern) {
                    if seen.insert(s.lowercased()).inserted { out.append(Checkpoint.Point(text: s.singleLine)) }
                    if out.count >= limit { return out.reversed() }
                }
            }
            return out.reversed()
        }
        let assistants = t.turns.filter { $0.role == .assistant }
        cp.decisions = pick(users, #"\b(let'?s (go with|use|do)|we'?ll use|i'?ll use|going with|decided|i chose|we chose|settled on|stick with)\b"#, limit: 3)
            + pick(assistants, #"\b(the answer is|final answer|so the (result|answer)|therefore|in conclusion|the fix is|the solution is|the (issue|problem|bug) (is|was)|root cause|this works because)\b"#, limit: 3)
        cp.tried = pick(users, #"\b(i tried|tried|didn'?t work|doesn'?t work|does not work|not working|still (get|getting|fails|failing|broken|wrong|doesn'?t)|same error|got (an |this |the )?error|it says|gives me|failed)\b"#, limit: 5)

        if let last = t.turns.last, last.role == .user, let s = sentences(last.text).first {
            cp.openProblems = [Checkpoint.Point(text: s.singleLine.truncated(240))]
            cp.nextStep = "Answer my last message: " + s.singleLine.truncated(200)
        } else if let lastUser = t.lastUser, let s = sentences(lastUser.text).first {
            if let next = t.lastAssistant.flatMap({ a in
                sentences(a.text).last { matches($0, #"^(next|now|then|after that|once that|your next step|the next step)\b"#) }
            }) {
                let lead = #"^(next|now|then|after that|once that'?s done)\s*[,:]?\s*"#
                var step = next.singleLine.replacingOccurrences(of: lead, with: "", options: [.regularExpression, .caseInsensitive])
                step = step.prefix(1).uppercased() + step.dropFirst()
                cp.nextStep = step.truncated(240)
            } else {
                cp.nextStep = "Continue from my last request: " + s.singleLine.truncated(200)
            }
        }
        if cp.nextStep.isEmpty { cp.nextStep = previous?.nextStep ?? "" }

        var rules = previous?.rules ?? []
        for r in Self.rules(from: t) where !rules.contains(where: { $0.text.lowercased() == r.lowercased() }) {
            rules.append(Checkpoint.Point(text: r))
        }
        cp.rules = rules
        cp.conversation = t
        cp.engine = "Shapr, from \(t.turns.count) message\(t.turns.count == 1 ? "" : "s") in \(t.service)"
        return cp
    }

    /// The AI's answer, shorter: code and final lines kept whole, otherwise the first sentence of each paragraph.
    static func condense(_ text: String, limit: Int) -> String {
        guard text.count > limit else { return text }
        var out: [String] = []
        var used = 0
        let parts = text.components(separatedBy: "```")
        for (i, part) in parts.enumerated() {
            let isCode = i % 2 == 1
            if isCode {
                let block = "```" + part + "```"
                if used + block.count <= limit { out.append(block); used += block.count }
                else { out.append("```\n[code shortened: ask @shapr C for the full answer]\n```"); used += 60 }
                continue
            }
            for para in part.components(separatedBy: "\n\n") {
                guard let p = para.nonEmpty else { continue }
                let first = sentences(p).first ?? p
                let piece = first.count > 300 ? first.truncated(300) : first
                guard used + piece.count <= limit else { break }
                out.append(piece)
                used += piece.count + 2
            }
        }
        return out.joined(separator: "\n\n")
    }
}

// MARK: - The handoff: what the next AI gets

/// Something Shapr can hand the next AI when it asks: a capture (S1, S2…) or the earlier chat (C).
struct HandoffItem: Identifiable, Hashable {
    enum Kind: Hashable { case capture, chat }
    let id: String
    let title: String
    let text: String
    let kind: Kind
}

struct Handoff {
    var text: String
    var items: [HandoffItem]
    var budget: Int
    var targetName: String
    var askBack: Bool
    var readBack: Bool
    /// The earlier chat as it went in: every message, compacted. nil when there was no chat.
    var chat: ChatCompactor.Result? = nil
    /// Roughly four characters per token.
    var tokens: Int { (text.count + 3) / 4 }
    var fits: Bool { text.count <= budget }
    /// A line the watcher looks for to find the handoff in the new chat.
    static let marker = "Saved by Shapr"
}

enum HandoffBuilder {
    struct Target: Equatable {
        let name: String
        /// Characters, chosen to fit comfortably in the free version.
        let budget: Int
        let forCode: Bool
        var sizeNote: String { forCode ? "sized for \(name)" : "sized for free \(name)" }
    }

    static func target(for name: String, code: Bool = false) -> Target {
        if code { return Target(name: name, budget: 40_000, forCode: true) }
        switch name {
        case "ChatGPT": return Target(name: name, budget: 12_000, forCode: false)
        case "Claude": return Target(name: name, budget: 20_000, forCode: false)
        case "Gemini": return Target(name: name, budget: 20_000, forCode: false)
        case "DeepSeek": return Target(name: name, budget: 16_000, forCode: false)
        case "Perplexity", "Copilot": return Target(name: name, budget: 8_000, forCode: false)
        default: return Target(name: name, budget: 12_000, forCode: false)
        }
    }

    struct Options {
        var askBack = true
        var readBack = true
        var includeEvidence = true
        var includeTabs = true
    }

    /// Everything Shapr can hand over on request, with stable codes.
    static func items(pack: Pack?, checkpoint cp: Checkpoint) -> [HandoffItem] {
        var out: [HandoffItem] = []
        for (i, c) in (pack?.captures ?? []).enumerated() {
            out.append(HandoffItem(id: "S\(i + 1)", title: c.displayTitle.singleLine.truncated(60), text: c.text, kind: .capture))
        }
        if let chat = cp.conversation {
            out.append(HandoffItem(id: "C", title: "the full earlier chat in \(chat.service) (\(chat.turns.count) messages)",
                                   text: chat.plainText, kind: .chat))
        }
        return out
    }

    static func build(pack: Pack?, checkpoint cp: Checkpoint, target: Target, options: Options = Options()) -> Handoff {
        let all = items(pack: pack, checkpoint: cp)
        let task = cp.title?.nonEmpty ?? pack?.name ?? "my project"
        let from = cp.conversation?.service
        let saved = cp.created.formatted(date: .abbreviated, time: .shortened)

        // Always included: what it's for, the rules, what's settled, and how to ask for more.
        var head = "I'm continuing “\(task)”" + (from.map { " from a chat in \($0)" } ?? "") + ". Here's everything you need to pick up exactly where it left off. (\(Handoff.marker), \(saved).)\n"
        if let g = cp.goal.nonEmpty { head += "\nGoal: \(g)" }
        if let n = cp.nextStep.nonEmpty { head += "\nNext step: \(n)" }
        head += "\n"
        let rules = cp.rules ?? []
        if !rules.isEmpty {
            head += "\nMy rules (in my own words; follow them exactly):\n" + rules.map { "- “\($0.text)”" }.joined(separator: "\n") + "\n"
        }
        func list(_ title: String, _ points: [Checkpoint.Point]) -> String {
            points.isEmpty ? "" : "\n\(title):\n" + points.map { "- \($0.text)" }.joined(separator: "\n") + "\n"
        }
        // What was decided, tried and left open: said once here only when the chat below had to be
        // shortened. When every message is there in full, repeating them would only spend tokens.
        let digest = list("Already decided", cp.decisions)
            + list("Already tried (don't suggest these again)", cp.tried)
            + list("Still open", cp.openProblems)

        var tail = ""
        if options.readBack {
            tail += "\nStart your reply with these three lines so I can check nothing got lost, then carry on with the next step:\nGoal: …\nRules: …\nNext: …\n"
        }

        let budget = target.budget
        var body: [String] = []
        var included = Set<String>()
        func size() -> Int { head.count + body.joined().count + tail.count + 400 }

        // The whole chat, every message in order, in as few tokens as it takes. My messages word for
        // word; the AI's without the filler, older answers shortened first. It gets the room that's
        // left after a share for the pack's notes.
        var compacted: ChatCompactor.Result?
        if let chat = cp.conversation, !chat.turns.isEmpty {
            let forNotes = options.includeEvidence && !(pack?.captures.isEmpty ?? true) ? min(budget / 4, 3200) : 0
            let intro = 330
            var room = budget - size() - intro - forNotes - (options.askBack ? 500 : 0)
            var r = ChatCompactor.compact(chat, budget: max(room, 500))
            if !r.complete {
                room -= digest.count
                r = ChatCompactor.compact(chat, budget: max(room, 500))
                if !r.complete { head += digest }
            }
            compacted = r
            var title = "\nThe chat so far, every message in order (U = me, A = \(chat.service))"
            if r.shortened > 0 {
                let example = chat.turns.indices.last { chat.turns[$0].role != .user }.map { ChatCompactor.label($0, chat.turns[$0].role) } ?? "A2"
                title += ". “(cut)” marks one I shortened: write @shapr and its code on its own line, like “@shapr \(example)”, to get it in full"
            }
            body.append(title + ":\n" + r.text + "\n")
        } else {
            head += digest
        }

        // The most relevant parts of the pack, one entry per capture.
        if options.includeEvidence, let pack, !pack.captures.isEmpty {
            let query = [cp.title ?? "", cp.goal, cp.nextStep, cp.openProblems.map(\.text).joined(separator: " "),
                         cp.decisions.map(\.text).joined(separator: " "), cp.conversation?.lastUser?.text.prefix(600).description ?? ""]
                .joined(separator: " ")
            let found = PackAssist.excerpts(for: query, in: pack, kind: target.forCode ? .debug : .general, limit: 6)
            var order: [UUID] = []
            var pieces: [UUID: [PackAssist.Excerpt]] = [:]
            for e in found {
                if pieces[e.captureID] == nil { order.append(e.captureID) }
                pieces[e.captureID, default: []].append(e)
            }
            var notes = ""
            for id in order.prefix(4) {
                guard let idx = pack.captures.firstIndex(where: { $0.id == id }) else { continue }
                let c = pack.captures[idx]
                let code = "S\(idx + 1)"
                let text = (pieces[id] ?? []).sorted { $0.index < $1.index }.map(\.text).joined(separator: "\n…\n")
                let body = String(text.prefix(1200)) + (text.count > 1200 ? "…" : "")
                let where_ = c.host.map { " · \($0)" } ?? ""
                let piece = "\n[\(code)] \(c.displayTitle.singleLine.truncated(70))\(where_)\n"
                    + (c.looksLikeCode || target.forCode ? "```\n\(body)\n```\n" : body + "\n")
                guard size() + notes.count + piece.count <= budget else { break }
                notes += piece
                if text.count <= 1200, text.count >= c.text.trimmingCharacters(in: .whitespacesAndNewlines).count - 2 { included.insert(code) }
            }
            if !notes.isEmpty { body.append("\nRelevant notes from my pack:" + notes) }
        }

        let tabs = cp.tabs.filter(\.keep)
        if options.includeTabs, !tabs.isEmpty {
            let pages = "\nPages I had open:\n" + tabs.prefix(12).map { "- \($0.title?.nonEmpty ?? $0.url): \($0.url)" }.joined(separator: "\n") + "\n"
            if size() + pages.count <= budget { body.append(pages) }
        }

        // What Shapr can hand over on request.
        var more = ""
        if options.askBack {
            // The full chat is only "more" when the copy above isn't already all of it.
            let rest = all.filter { !included.contains($0.id) && !($0.kind == .chat && compacted?.complete == true) }
            if !rest.isEmpty {
                var lines: [String] = []
                var used = 0
                for it in rest.reversed() { // newest captures first if space runs out
                    let l = "\(it.id): \(it.title)"
                    if size() + more.count + used + l.count > budget + 300, it.kind == .capture { continue }
                    lines.insert(l, at: 0)
                    used += l.count + 3
                }
                let hidden = rest.count - lines.count
                more = "\nShapr has more if you need it:\n" + lines.joined(separator: "\n")
                    + (hidden > 0 ? "\n(+ \(hidden) more; ask by topic)" : "") + "\n"
                    + "If you need any of it, write @shapr and the code or what you need on its own line, like “@shapr \(rest.first!.id)” or “@shapr the error from earlier”, and I'll paste it in. Don't guess at anything that's in this list.\n"
            }
        }

        func assemble() -> String {
            (head + body.joined() + more + tail).replacingOccurrences(of: "\n\n\n", with: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        }
        var text = assemble()
        // Never more than the target handles well: drop the optional parts, last first.
        while text.count > budget, !body.isEmpty {
            body.removeLast()
            text = assemble()
        }
        return Handoff(text: text, items: all, budget: budget, targetName: target.name,
                       askBack: options.askBack && !more.isEmpty, readBack: options.readBack,
                       chat: body.isEmpty ? nil : compacted)
    }

    // MARK: Answering "@shapr …"

    /// The requests in an AI's reply, like "@shapr S3" or "@shapr the error from earlier".
    static func requests(in reply: String) -> [String] {
        var out: [String] = []
        for line in reply.components(separatedBy: "\n") {
            guard let r = line.range(of: #"@shapr\b[:\s]*"#, options: [.regularExpression, .caseInsensitive]) else { continue }
            var q = String(line[r.upperBound...]).trimmingCharacters(in: .whitespaces)
            q = q.trimmingCharacters(in: CharacterSet(charactersIn: "`*_“”\"'.,;:()[]"))
            if let q = q.nonEmpty, q.count <= 160, !out.contains(q) { out.append(q) }
        }
        return out
    }

    /// What to paste for a request: the item with that code, a part of the earlier chat, or the best
    /// matches for a topic.
    static func answer(_ request: String, handoff: Handoff, pack: Pack?, checkpoint cp: Checkpoint) -> (title: String, text: String)? {
        let q = request.trimmingCharacters(in: .whitespaces)
        let partSize = max(4000, handoff.budget - 1500)
        // "C", "C2": the earlier chat, in parts that fit.
        if let m = q.range(of: #"^[Cc](\d*)$"#, options: .regularExpression), m.lowerBound == q.startIndex,
           let chat = handoff.items.first(where: { $0.id == "C" }) {
            let n = Int(q.dropFirst()) ?? 1
            let parts = stride(from: 0, to: chat.text.count, by: partSize).map { start -> String in
                let a = chat.text.index(chat.text.startIndex, offsetBy: start)
                let b = chat.text.index(a, offsetBy: min(partSize, chat.text.count - start))
                return String(chat.text[a..<b])
            }
            guard n >= 1, n <= parts.count else { return nil }
            let more = n < parts.count ? "\n\n(Part \(n) of \(parts.count). Write @shapr C\(n + 1) for the next part.)" : ""
            return ("\(chat.title)" + (parts.count > 1 ? ", part \(n) of \(parts.count)" : ""),
                    "Here's the earlier chat" + (parts.count > 1 ? " (part \(n) of \(parts.count))" : "") + ", from Shapr:\n\n" + parts[n - 1] + more)
        }
        // "A7", "U3": one message of the earlier chat, in full.
        if let chat = cp.conversation, let i = ChatCompactor.index(ofLabel: q, in: chat) {
            let t = chat.turns[i]
            let code = ChatCompactor.label(i, t.role)
            let body = String(t.text.prefix(partSize))
            let cut = t.text.count > partSize ? "\n\n(Shortened to fit. Ask about a specific part if you need more.)" : ""
            let who = t.role == .user ? "my message" : "\(chat.service)'s message"
            return ("\(code): \(who) \(i + 1) of \(chat.turns.count)", "Here's \(code) in full (\(who) \(i + 1) in the earlier chat), from Shapr:\n\n" + body + cut)
        }
        if let it = handoff.items.first(where: { $0.id.caseInsensitiveCompare(q.split(separator: " ").first.map(String.init) ?? "") == .orderedSame }) {
            let body = String(it.text.prefix(partSize))
            let cut = it.text.count > partSize ? "\n\n(Shortened to fit. Ask about a specific part if you need more.)" : ""
            return ("\(it.id): \(it.title)", "Here's \(it.id) (\(it.title)), from Shapr:\n\n" + body + cut)
        }
        // A topic: search the pack and the earlier chat together.
        var captures = pack?.captures ?? []
        if let chat = cp.conversation {
            for (i, t) in chat.turns.enumerated() {
                captures.append(Capture(id: UUID(), text: t.text, capturedAt: chat.read, title: "\(t.role == .user ? "My" : chat.service + "'s") message \(i + 1) in the earlier chat", fileName: "chat-\(i)"))
            }
        }
        guard !captures.isEmpty else { return nil }
        let meta = PackMeta(id: pack?.id ?? UUID(), name: pack?.name ?? "chat", emoji: nil, created: Date(), autoNamed: false)
        let pool = Pack(meta: meta, folder: pack?.folder ?? FileManager.default.temporaryDirectory, captures: captures)
        let found = PackAssist.excerpts(for: q, in: pool, kind: .general, limit: 3).filter { $0.score > 0.1 }
        guard !found.isEmpty else { return nil }
        var text = "Here's what I have on “\(q)”, from Shapr:\n"
        for e in found where text.count + e.text.count < partSize {
            text += "\n— \(e.title.singleLine.truncated(80))\n\(e.text)\n"
        }
        return ("“\(q.truncated(40))”", text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

// MARK: - Read-back: did the new AI get everything?

enum ReadBack {
    struct Lines: Equatable { var goal: String?; var rules: String?; var next: String? }
    struct Result: Equatable {
        var missed: [String]
        var total: Int
        var allCovered: Bool { missed.isEmpty }
    }

    /// The "Goal: / Rules: / Next:" lines at the start of the reply, if the AI wrote them.
    static func parse(_ reply: String) -> Lines? {
        var l = Lines()
        var current: WritableKeyPath<Lines, String?>?
        for raw in reply.components(separatedBy: "\n").prefix(40) {
            let line = raw.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "*#-• "))
            func value(after label: String) -> String? {
                guard line.lowercased().hasPrefix(label) else { return nil }
                return String(line.dropFirst(label.count)).trimmingCharacters(in: CharacterSet(charactersIn: ":*  ")).trimmingCharacters(in: .whitespaces)
            }
            if let v = value(after: "goal") { l.goal = v; current = \.goal; continue }
            if let v = value(after: "rules") ?? value(after: "rule") { l.rules = v; current = \.rules; continue }
            if let v = value(after: "next step") ?? value(after: "next") { l.next = v; current = \.next; continue }
            // Rules are often a short list under the label.
            if current == \Lines.rules, !line.isEmpty, l.next == nil { l.rules = (l.rules ?? "") + "; " + line; continue }
            if line.isEmpty, current != nil, l.goal != nil, l.next != nil { break }
        }
        let found = [l.goal, l.rules, l.next].compactMap { $0 }.count
        return found >= 2 ? l : nil
    }

    /// Which saved facts the read-back left out (or flipped, like "use numpy" for "don't use numpy").
    static func check(_ lines: Lines, against cp: Checkpoint, reply: String) -> Result {
        var missed: [String] = []
        var total = 0
        if let g = cp.goal.nonEmpty {
            total += 1
            if !covers(lines.goal ?? "", g) && !covers(reply, g, strict: true) { missed.append("Goal: \(g)") }
        }
        let rulesText = lines.rules ?? ""
        for r in cp.rules ?? [] {
            total += 1
            let segments = rulesText.components(separatedBy: CharacterSet(charactersIn: ";\n•")).flatMap { $0.components(separatedBy: ", ") }
            let best = segments.max { overlap($0, r.text) < overlap($1, r.text) } ?? ""
            let negated = r.text.range(of: ChatDigest.negation, options: [.regularExpression, .caseInsensitive]) != nil
            let keptNegation = !negated || best.range(of: ChatDigest.negation, options: [.regularExpression, .caseInsensitive]) != nil
            if !(covers(rulesText, r.text) && keptNegation) { missed.append("Rule: “\(r.text)”") }
        }
        if let n = cp.nextStep.nonEmpty {
            total += 1
            if !covers(lines.next ?? "", n) && !covers(reply, n, strict: true) { missed.append("Next step: \(n)") }
        }
        return Result(missed: missed, total: total)
    }

    /// The share of `fact`'s important words that `text` mentions (prefix match, so "matrices" ≈ "matrix").
    private static let filler: Set<String> = ["don", "doesn", "didn", "won", "isn", "aren", "can", "cannot", "never", "not",
                                              "avoid", "without", "make", "sure", "want", "need", "please", "always"]

    static func overlap(_ text: String, _ fact: String) -> Double {
        let want = Set(PackAssist.tokens(fact)).subtracting(filler)
        guard !want.isEmpty else { return 1 }
        let have = PackAssist.tokens(text)
        let hits = want.filter { w in have.contains { h in h == w || (h.count >= 5 && w.count >= 5 && h.prefix(5) == w.prefix(5)) } }
        return Double(hits.count) / Double(want.count)
    }

    static func covers(_ text: String, _ fact: String, strict: Bool = false) -> Bool {
        guard !text.isEmpty else { return false }
        return overlap(text, fact) >= (strict ? 0.75 : 0.5)
    }

    static func followUp(_ result: Result) -> String {
        "Before you go on, you missed \(result.missed.count == 1 ? "this" : "these") from before:\n"
            + result.missed.map { "- \($0)" }.joined(separator: "\n")
            + "\nPlease take \(result.missed.count == 1 ? "it" : "them") into account and continue."
    }
}
