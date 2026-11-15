import Foundation
import FoundationModels
import NaturalLanguage

struct PackSummary {
    let id: UUID
    let name: String
    let samples: [String]
    let hosts: Set<String>
    let texts: [String]
}

/// Where a new capture should go. `packID == nil` means start a new pack called `name`.
struct SortDecision {
    var packID: UUID?
    var name: String
    var emoji: String?
    var engine: String
}

enum SortEngine: String, CaseIterable, Identifiable {
    case onDevice = "apple"
    case claude = "claude"
    var id: String { rawValue }
    var title: String { self == .onDevice ? "On-device (Apple Intelligence)" : "Claude (your API key)" }
}

enum SorterSettings {
    static let engineKey = "sortEngine"
    static let modelKey = "claudeModel"
    static let keychainAccount = "anthropic-api-key"
    static let defaultModel = "claude-opus-5-5"
    static let models: [(id: String, title: String)] = [
        ("claude-opus-5-5", "Claude Opus 5.5 (best)"),
        ("claude-sonnet-5-5", "Claude Sonnet 5.5"),
        ("claude-haiku-5-5", "Claude Haiku 5.5 (cheapest)"),
    ]

    static var engine: SortEngine {
        get { UserDefaults.standard.string(forKey: engineKey).flatMap(SortEngine.init) ?? .onDevice }
        set { UserDefaults.standard.set(newValue.rawValue, forKey: engineKey) }
    }
    static var model: String {
        get { UserDefaults.standard.string(forKey: modelKey) ?? defaultModel }
        set { UserDefaults.standard.set(newValue, forKey: modelKey) }
    }
    static var apiKey: String? {
        Keychain.get(keychainAccount) ?? ProcessInfo.processInfo.environment["ANTHROPIC_API_KEY"]?.nonEmpty
    }
}

// MARK: - On-device structured output

@Generable
struct OnDevicePackChoice {
    @Guide(description: "The exact name of the existing pack covering the same broad subject or task, or NEW if none does")
    var pack: String
    @Guide(description: "A 1-3 word name for the broad subject of this snippet, as if it were a new pack, for example 'Cars', 'Video Games' or 'Bug #42'")
    var topicName: String
    @Guide(description: "One emoji that represents the topic")
    var emoji: String
}

@Generable
struct OnDevicePackName {
    @Guide(description: "A 1-3 word name for the broad subject these snippets share")
    var name: String
    @Guide(description: "One emoji that represents the topic")
    var emoji: String
}

// MARK: - Sorter

@MainActor
final class Sorter {
    static let instructions = """
    You organize text snippets that a user captured from apps and websites into topic packs, \
    like folders of research. A pack is a broad subject or a task someone collects many snippets for. \
    Put a snippet in an existing pack when it is about the same broad subject or task, even if it covers a \
    different item: a different car model belongs in "Cars", a different game belongs in "Video Games". \
    Answer NEW only when no existing pack covers the subject. \
    Name packs after the broad subject in 1-3 words ("Video Games", not "Elden Ring"; "Cars", not "Toyota Supra"), \
    except for a specific task such as one bug report or one job application ("Bug #42", "Stripe Internship").
    """

    var appleModelAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    var appleModelStatus: String {
        switch SystemLanguageModel.default.availability {
        case .available: return "Ready"
        case .unavailable(let reason):
            switch reason {
            case .appleIntelligenceNotEnabled: return "Turn on Apple Intelligence in System Settings"
            case .deviceNotEligible: return "This Mac doesn't support Apple Intelligence"
            case .modelNotReady: return "Apple Intelligence is still downloading"
            @unknown default: return "Unavailable"
            }
        }
    }

    func prewarm() {
        guard appleModelAvailable else { return }
        LanguageModelSession(instructions: Self.instructions).prewarm()
    }

    /// `allowClaude: false` keeps the decision on this Mac (used for files you only opened).
    func decide(_ d: CaptureDraft, packs: [PackSummary], allowClaude: Bool = true) async -> SortDecision {
        let prompt = Self.sortPrompt(d, packs: packs)

        if allowClaude, SorterSettings.engine == .claude, let key = SorterSettings.apiKey {
            do {
                let json = try await ClaudeClient(apiKey: key, model: SorterSettings.model)
                    .structured(system: Self.instructions, prompt: prompt, schema: ClaudeClient.choiceSchema)
                return resolve(pack: json["pack"] as? String ?? "NEW",
                               topic: json["topic_name"] as? String ?? "",
                               emoji: json["emoji"] as? String, packs: packs, draft: d, engine: "Claude")
            } catch {
                NSLog("Shapr: Claude sort failed, falling back: \(error)")
            }
        }

        if appleModelAvailable {
            do {
                let r = try await LanguageModelSession(instructions: Self.instructions)
                    .respond(to: prompt, generating: OnDevicePackChoice.self)
                return resolve(pack: r.content.pack, topic: r.content.topicName, emoji: r.content.emoji,
                               packs: packs, draft: d, engine: "On-device")
            } catch {
                NSLog("Shapr: on-device sort failed, falling back: \(error)")
            }
        }

        return LocalSimilarity.decide(d, packs: packs)
    }

    /// A better name for a pack once it has a few captures.
    func name(for texts: [String]) async -> (name: String, emoji: String?)? {
        let joined = texts.prefix(8).enumerated()
            .map { "\($0.offset + 1). \($0.element.singleLine.truncated(300))" }.joined(separator: "\n")
        let prompt = "These snippets were collected into one pack:\n\(joined)\n\nName the pack."

        if SorterSettings.engine == .claude, let key = SorterSettings.apiKey,
           let json = try? await ClaudeClient(apiKey: key, model: SorterSettings.model)
               .structured(system: Self.instructions, prompt: prompt, schema: ClaudeClient.nameSchema),
           let n = (json["name"] as? String)?.nonEmpty {
            return (PackNaming.clean(n), PackNaming.cleanEmoji(json["emoji"] as? String))
        }
        if appleModelAvailable,
           let r = try? await LanguageModelSession(instructions: Self.instructions)
               .respond(to: prompt, generating: OnDevicePackName.self),
           let n = r.content.name.nonEmpty {
            return (PackNaming.clean(n), PackNaming.cleanEmoji(r.content.emoji))
        }
        return nil
    }

    private func resolve(pack: String, topic: String, emoji: String?, packs: [PackSummary],
                         draft: CaptureDraft, engine: String) -> SortDecision {
        let name = topic.nonEmpty.map(PackNaming.clean) ?? LocalSimilarity.keywordName(draft)
        // If the model says NEW but its topic name is already a pack, use that pack.
        let id = PackNaming.match(pack, in: packs)?.id
            ?? packs.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.id
        return SortDecision(packID: id, name: name,
                            emoji: PackNaming.cleanEmoji(emoji), engine: engine)
    }

    static func sortPrompt(_ d: CaptureDraft, packs: [PackSummary]) -> String {
        var s = "Existing packs:\n"
        if packs.isEmpty {
            s += "(none yet, so answer NEW)\n"
        } else {
            for p in packs.prefix(10) {
                s += "- \"\(p.name)\": " + p.samples.joined(separator: " | ") + "\n"
            }
        }
        var source: [String] = []
        if let h = d.host { source.append(h) } else if let a = d.appName { source.append(a) }
        if let t = d.title?.nonEmpty { source.append("\"\(t.singleLine.truncated(100))\"") }
        s += "\nNew snippet"
        if !source.isEmpty { s += " (from \(source.joined(separator: ", ")))" }
        s += ":\n\"\"\"\n\(d.text.truncated(1200))\n\"\"\"\n\n"
        s += "Which pack does it belong to? Use the pack name exactly as written above, or NEW."
        return s
    }
}

// MARK: - Naming helpers

enum PackNaming {
    static func clean(_ raw: String) -> String {
        var s = raw.singleLine
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "\"'“”‘’`.:;-_*#").union(.whitespaces))
        for prefix in ["Pack:", "Topic:", "Name:"] where s.lowercased().hasPrefix(prefix.lowercased()) {
            s = String(s.dropFirst(prefix.count)).trimmingCharacters(in: .whitespaces)
        }
        if s == s.lowercased() { s = s.capitalized }
        if s.count > 32 { s = String(s.prefix(32)).trimmingCharacters(in: .whitespaces) }
        return s.isEmpty ? "New Pack" : s
    }

    static func cleanEmoji(_ raw: String?) -> String? {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), let ch = t.first else { return nil }
        let isEmoji = ch.unicodeScalars.contains { $0.properties.isEmojiPresentation }
            || (ch.unicodeScalars.count > 1 && ch.unicodeScalars.first?.properties.isEmoji == true)
        return isEmoji ? String(ch) : nil
    }

    static func match(_ answer: String, in packs: [PackSummary]) -> PackSummary? {
        let a = normalize(answer)
        guard !a.isEmpty, a != "new" else { return nil }
        if let p = packs.first(where: { normalize($0.name) == a }) { return p }
        return packs.first {
            let n = normalize($0.name)
            return n.count >= 3 && (a.contains(n) || n.contains(a))
        }
    }

    private static func normalize(_ s: String) -> String {
        String(s.lowercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == " " })
            .trimmingCharacters(in: .whitespaces)
    }
}

// MARK: - Fallback when no language model is available

enum LocalSimilarity {
    private static let embedding = NLEmbedding.wordEmbedding(for: .english)

    static func vector(_ s: String) -> [Double]? {
        guard let emb = embedding else { return nil }
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = s
        var acc = [Double](repeating: 0, count: emb.dimension)
        var n = 0
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace]) { tag, r in
            if tag == .noun || tag == .verb || tag == .adjective, let v = emb.vector(for: s[r].lowercased()) {
                for i in v.indices { acc[i] += v[i] }
                n += 1
            }
            return true
        }
        return n == 0 ? nil : acc
    }

    static func cosine(_ a: [Double], _ b: [Double]) -> Double {
        var d = 0.0, na = 0.0, nb = 0.0
        for i in a.indices { d += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
        return na == 0 || nb == 0 ? 0 : d / (na.squareRoot() * nb.squareRoot())
    }

    static func decide(_ d: CaptureDraft, packs: [PackSummary]) -> SortDecision {
        let name = keywordName(d)
        guard let v = vector((d.title ?? "") + " " + d.text) else {
            return SortDecision(packID: nil, name: name, emoji: nil, engine: "Keywords")
        }
        var best: (UUID, Double)?
        for p in packs {
            let vs = p.texts.compactMap(vector)
            guard !vs.isEmpty else { continue }
            var c = [Double](repeating: 0, count: v.count)
            for x in vs { for i in x.indices { c[i] += x[i] } }
            var score = cosine(v, c)
            if let h = d.host, p.hosts.contains(h) { score += 0.2 }
            if score > (best?.1 ?? -1) { best = (p.id, score) }
        }
        let pick = (best?.1 ?? 0) >= 0.68 ? best?.0 : nil
        return SortDecision(packID: pick, name: name, emoji: nil, engine: "Keywords")
    }

    static func keywordName(_ d: CaptureDraft) -> String {
        let words = keywords((d.title ?? "") + ". " + d.text, limit: 2)
        return PackNaming.clean(words.isEmpty ? "New Pack" : words.joined(separator: " "))
    }

    static func keywords(_ s: String, limit: Int) -> [String] {
        let tagger = NLTagger(tagSchemes: [.lexicalClass, .nameType])
        tagger.string = s
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        tagger.enumerateTags(in: s.startIndex..<s.endIndex, unit: .word, scheme: .lexicalClass,
                             options: [.omitPunctuation, .omitWhitespace, .joinNames]) { tag, r in
            let w = String(s[r])
            guard tag == .noun, w.count > 2, !stopwords.contains(w.lowercased()) else { return true }
            let k = w.lowercased()
            counts[k, default: 0] += w.first?.isUppercase == true ? 2 : 1
            display[k] = display[k] ?? w
            return true
        }
        return counts.sorted { $0.value > $1.value }.prefix(limit).compactMap { display[$0.key]?.capitalized }
    }

    private static let stopwords: Set<String> = [
        "thing", "things", "way", "time", "year", "years", "people", "page", "article", "today", "wikipedia",
        "home", "menu", "search", "click", "use", "lot", "part", "number", "example", "something",
    ]
}
