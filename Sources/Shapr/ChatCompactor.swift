import Foundation

/// The whole conversation in as few tokens as it takes, for handing a chat to another AI.
/// Every message stays, in order, with a short code (U1, A2…) so the next AI can ask for any of them
/// in full. Your own messages are kept word for word. What goes is what the next AI doesn't need:
/// pleasantries, markdown decoration, code that a later message replaced, and the long middle of
/// older answers (the newest answers get the most room).
enum ChatCompactor {
    struct Result: Equatable {
        var text = ""
        var messages = 0
        /// Messages cut to fit (older answers, long pastes).
        var shortened = 0
        /// Messages left out altogether: only when a chat is too long to give each one a line.
        var omitted = 0
        var originalChars = 0

        /// Roughly four characters per token.
        var tokens: Int { (text.count + 3) / 4 }
        var originalTokens: Int { (originalChars + 3) / 4 }
        var complete: Bool { shortened == 0 && omitted == 0 }

        /// "All 42 messages · about 3,100 tokens, down from 18,400".
        var summary: String {
            let kept = messages - omitted
            let which = omitted == 0 ? "All \(messages) message\(messages == 1 ? "" : "s")" : "The last \(kept) of \(messages) messages"
            let size = "about \(tokens.formatted()) tokens"
            return originalTokens > tokens + tokens / 10 ? "\(which) · \(size), down from \(originalTokens.formatted())" : "\(which) · \(size)"
        }
    }

    /// "U1", "A2": the message's place in the chat, so "@shapr A2" can fetch it.
    static func label(_ index: Int, _ role: ChatTurn.Role) -> String {
        (role == .user ? "U" : role == .assistant ? "A" : "M") + "\(index + 1)"
    }

    /// The message a code like "A2" or "u7" names.
    static func index(ofLabel s: String, in chat: ChatTranscript) -> Int? {
        guard let m = s.range(of: #"^[UuAaMm](\d+)$"#, options: .regularExpression), m.lowerBound == s.startIndex,
              let n = Int(s.dropFirst()), n >= 1, n <= chat.turns.count else { return nil }
        return n - 1
    }

    // MARK: Cleaning one message

    private static func sub(_ s: String, _ pattern: String, _ with: String, caseInsensitive: Bool = false) -> String {
        s.replacingOccurrences(of: pattern, with: with, options: caseInsensitive ? [.regularExpression, .caseInsensitive] : .regularExpression)
    }

    static let closerPattern = #"^(let me know|feel free|i hope (this|that|it) helps|hope (this|that|it) helps|if you('d| would) like|if you want|would you like|do you want me to|want me to|is there anything else|i can also|happy to (help|explain|walk)|just (ask|let me know))\b"#
    static let openerPattern = #"^\s*((sure( thing)?|certainly|of course|absolutely|no problem|got it|okay|ok|alright|great|you'?re (absolutely |totally )?right|(great|good|excellent) question|happy to help|i'?d be (happy|glad) to help)[!.,:]+\s*)+"#

    /// Words unchanged for your messages (only blank lines go). An AI's message also loses its
    /// "Sure!" and "Let me know if…", and its bold, headings and rules.
    static func clean(_ text: String, role: ChatTurn.Role, keepOffer: Bool) -> String {
        var parts = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "```")
        for i in parts.indices where i % 2 == 0 {
            var p = parts[i]
            p = sub(p, #"(?m)[ \t]+$"#, "")
            if role != .user {
                p = p.replacingOccurrences(of: "**", with: "")
                p = sub(p, #"(?m)^\s*\|?\s*:?-{3,}:?\s*(\|\s*:?-{3,}:?\s*)*\|?\s*$\n?"#, "")
                p = sub(p, #"(?m)^\s*([*_]\s?){3,}\s*$\n?"#, "")
                p = sub(p, #"(?m)^#{1,6}\s+"#, "")
                p = sub(p, #"(?m)^(\s*)[*•]\s+"#, "$1- ")
                p = sub(p, #"(?m)(?<=\S)[ \t]{2,}"#, " ")
            }
            parts[i] = sub(p, #"\n{2,}"#, "\n")
        }
        guard role != .user else { return parts.joined(separator: "```").trimmingCharacters(in: .whitespacesAndNewlines) }

        if let first = parts.first {
            let trimmed = sub(first, openerPattern, "", caseInsensitive: true)
            if trimmed.count != first.count, let c = trimmed.first {
                parts[0] = c.uppercased() + trimmed.dropFirst()
            }
        }
        // An offer at the end matters only if you answered it ("yes, do that").
        if !keepOffer, let last = parts.indices.last, last % 2 == 0 {
            var lines = parts[last].components(separatedBy: "\n")
            while let l = lines.last {
                let t = l.trimmingCharacters(in: .whitespaces)
                if t.isEmpty { lines.removeLast(); continue }
                guard t.count <= 220, t.range(of: closerPattern, options: [.regularExpression, .caseInsensitive]) != nil else { break }
                lines.removeLast()
            }
            parts[last] = lines.joined(separator: "\n")
        }
        return parts.joined(separator: "```").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// "yes", "do the second one", "go ahead": a short reply that only makes sense with the offer before it.
    static func takesUpOffer(_ reply: String) -> Bool {
        let t = reply.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.count <= 60 && t.range(of: #"^(yes|yeah|yep|yup|sure|ok|okay|please|do it|do that|go ahead|go for it|sounds good|that works|no\b|nope|not now|both|the (first|second|third|last)|option|[1-9a-c][.)]?$)"#,
                                        options: [.regularExpression, .caseInsensitive]) != nil
    }

    private static func codeLines(_ block: String) -> Set<String> {
        Set(block.components(separatedBy: "\n").dropFirst().map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.count > 1 })
    }

    /// When an AI rewrites the same code in a later message, the earlier copy is only noise.
    static func dropReplacedCode(_ texts: inout [String], turns: [ChatTurn]) {
        var blocks: [(turn: Int, part: Int, lines: Set<String>)] = []
        for i in turns.indices where turns[i].role != .user {
            let parts = texts[i].components(separatedBy: "```")
            for p in parts.indices where p % 2 == 1 {
                let lines = codeLines(parts[p])
                if lines.count >= 4 { blocks.append((i, p, lines)) }
            }
        }
        var replaced: [Int: [Int: Int]] = [:]
        for (n, b) in blocks.enumerated() {
            guard let later = blocks[(n + 1)...].last(where: { o in
                o.turn > b.turn && Double(b.lines.intersection(o.lines).count) / Double(b.lines.union(o.lines).count) >= 0.6
            }) else { continue }
            replaced[b.turn, default: [:]][b.part] = later.turn
        }
        for (turn, map) in replaced {
            let parts = texts[turn].components(separatedBy: "```")
            var out = ""
            for p in parts.indices {
                if let later = map[p] {
                    out += "[code: an earlier version of what's in \(label(later, turns[later].role))]"
                } else if p % 2 == 1 {
                    out += "```" + parts[p] + "```"
                } else {
                    out += parts[p]
                }
            }
            texts[turn] = out
        }
    }

    // MARK: Shortening an answer

    static let keyPattern = #"\b(the answer is|final answer|so the (result|answer)|therefore|in conclusion|the fix is|the solution is|the (issue|problem|bug|error|cause) (is|was)|root cause|this works because|which gives|we get)\b"#

    /// An answer in `limit` characters: its conclusions first, then its code, then the first sentence of
    /// each paragraph, put back in their original order.
    static func shorten(_ text: String, to limit: Int, label: String) -> String {
        guard text.count > limit else { return text }
        struct Piece { let order: Int; let para: Int; let priority: Int; var text: String }
        var pieces: [Piece] = []
        var para = 0
        for (i, part) in text.components(separatedBy: "```").enumerated() {
            if i % 2 == 1 {
                pieces.append(Piece(order: pieces.count, para: para, priority: 1, text: "```" + part + "```"))
                para += 1
                continue
            }
            for line in part.components(separatedBy: "\n") {
                guard line.nonEmpty != nil else { continue }
                for (k, s) in ChatDigest.sentences(line).enumerated() {
                    let key = s.range(of: keyPattern, options: [.regularExpression, .caseInsensitive]) != nil
                    pieces.append(Piece(order: pieces.count, para: para, priority: key ? 0 : k == 0 ? 2 : 3, text: s))
                }
                para += 1
            }
        }
        var chosen: [Piece] = []
        var used = 0
        for var p in pieces.sorted(by: { ($0.priority, $0.order) < ($1.priority, $1.order) }) {
            let room = limit - used
            if p.text.count + 1 <= room {
                chosen.append(p)
                used += p.text.count + 1
            } else if p.priority == 1, room >= 160 {
                // The top of the code, and how to get the rest.
                var kept: [String] = []
                var size = 60
                for l in p.text.components(separatedBy: "\n") {
                    guard size + l.count + 1 <= room else { break }
                    kept.append(l)
                    size += l.count + 1
                }
                guard kept.count >= 3 else { continue }
                p.text = kept.joined(separator: "\n") + "\n… [rest: @shapr \(label)]\n```"
                chosen.append(p)
                used += p.text.count + 1
            } else if p.priority == 0, chosen.isEmpty, room >= 60 {
                p.text = String(p.text.prefix(room - 2)) + "…"
                chosen.append(p)
                used = limit
            }
        }
        chosen.sort { $0.order < $1.order }
        var out = ""
        var lastPara = -1
        for p in chosen {
            if !out.isEmpty { out += p.para == lastPara ? " " : "\n" }
            out += p.text
            lastPara = p.para
        }
        return out.isEmpty ? String(text.prefix(max(limit - 1, 1))) + "…" : out
    }

    /// A long message of yours: its start and its end (the question is usually at one of them).
    static func trim(_ text: String, to limit: Int) -> String {
        guard text.count > limit, limit > 60 else { return text.count > limit ? String(text.prefix(limit)) : text }
        let note = " […\((text.count - limit + 30).formatted()) characters left out…] "
        let room = limit - note.count
        let head = room * 3 / 5
        return String(text.prefix(head)) + note + String(text.suffix(room - head))
    }

    // MARK: The whole chat

    /// Every message of `chat` in at most `budget` characters.
    static func compact(_ chat: ChatTranscript, budget: Int) -> Result {
        let turns = chat.turns
        var result = Result(messages: turns.count, originalChars: turns.reduce(0) { $0 + $1.text.count })
        guard !turns.isEmpty else { return result }

        var texts: [String] = turns.indices.map { i in
            // The last message's offer stays too: the next AI may be asked to act on it.
            let answered = i + 1 < turns.count ? (turns[i + 1].role == .user && takesUpOffer(turns[i + 1].text)) : true
            return clean(turns[i].text, role: turns[i].role, keepOffer: answered)
        }
        dropReplacedCode(&texts, turns: turns)
        let labels = turns.indices.map { label($0, turns[$0].role) }
        let lastUser = turns.lastIndex { $0.role == .user }
        let lastOther = turns.lastIndex { $0.role != .user }
        let floor = 90

        /// How much of each message fits when messages before `start` are left out and your own are
        /// capped at `userCap`. nil when even one line each doesn't fit. `share` is what an older answer gets.
        func allocate(from start: Int, userCap: Int) -> (alloc: [Int], share: Int)? {
            var alloc = [Int](repeating: 0, count: turns.count)
            var fixed = start > 0 ? 90 : 0
            var flex: [(i: Int, len: Int, w: Double)] = []
            for i in start..<turns.count {
                let len = texts[i].count
                fixed += labels[i].count + 9
                if turns[i].role == .user {
                    let cap = i == lastUser ? max(userCap, min(1500, budget / 4)) : userCap
                    alloc[i] = min(len, cap)
                    fixed += alloc[i]
                } else {
                    flex.append((i, len, i == lastOther ? 4 : i >= turns.count - 4 ? 2 : 1))
                }
            }
            let room = budget - fixed
            func size(_ f: (i: Int, len: Int, w: Double), _ l: Double) -> Int { min(f.len, max(min(f.len, floor), Int(l * f.w))) }
            func total(_ l: Double) -> Int { flex.reduce(0) { $0 + size($1, l) } }
            guard room >= total(0) else { return nil }
            var lo = 0.0, hi = Double(flex.map(\.len).max() ?? 0)
            if total(hi) <= room {
                lo = hi
            } else {
                for _ in 0..<32 {
                    let mid = (lo + hi) / 2
                    if total(mid) <= room { lo = mid } else { hi = mid }
                }
            }
            for f in flex { alloc[f.i] = size(f, lo) }
            return (alloc, lo >= hi ? .max : Int(lo))
        }

        var start = 0
        var plan: [Int]?
        // Your messages whole if the answers still get real room; otherwise cap your long pastes first.
        var fallback: [Int]?
        for cap in [Int.max, 1200, 600, 300, 160] {
            guard let a = allocate(from: 0, userCap: cap) else { continue }
            if a.share >= 350 { plan = a.alloc; break }
            fallback = a.alloc
        }
        plan = plan ?? fallback
        if plan == nil {
            // Too long for a line each: leave out the oldest messages (the fewest that makes it fit).
            var lo = 1, hi = turns.count - 1
            while lo < hi {
                let mid = (lo + hi) / 2
                if allocate(from: mid, userCap: 160) != nil { hi = mid } else { lo = mid + 1 }
            }
            start = lo
            plan = allocate(from: start, userCap: 160)?.alloc ?? turns.indices.map { $0 < start ? 0 : min(texts[$0].count, max(40, budget - 120)) }
        }
        let alloc = plan ?? []

        var lines: [String] = []
        result.omitted = start
        for i in start..<turns.count {
            var t = texts[i]
            var cut = false
            if t.count > alloc[i] {
                cut = true
                t = turns[i].role == .user ? trim(t, to: alloc[i]) : shorten(t, to: alloc[i], label: labels[i])
                result.shortened += 1
            }
            lines.append("\(labels[i])\(cut ? " (cut)" : ""): \(t)")
        }
        // Never over: the newest messages win.
        while lines.count > 1, lines.reduce(0, { $0 + $1.count + 1 }) > budget - 90 {
            lines.removeFirst()
            result.omitted += 1
        }
        if result.omitted > 0 {
            lines.insert("[Messages 1–\(result.omitted) left out to fit. @shapr C has the whole chat.]", at: 0)
        }
        result.text = lines.joined(separator: "\n")
        if result.text.count > budget { result.text = String(result.text.suffix(budget)) }
        return result
    }
}
