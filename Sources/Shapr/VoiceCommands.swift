import Foundation
import FoundationModels
import NaturalLanguage

/// What you can say while holding ⌥V. One key for everything: a command runs (several in a row if you
/// say "then"), a question is answered, and anything else is saved as a voice note.
enum VoiceCommand: Equatable {
    case draft(String)
    case ask(String, pack: String?)
    case use
    case scoop(pack: String?)
    /// A picture of your screen with its text read off it, saved to a pack ("get the context of my screen").
    case addScreen(pack: String?)
    case screenshot
    case fill
    case saveProgress
    case resume
    case continueIn(String)
    case equip(String)
    case autoSort
    case newPack(String?)
    case keepUpdated(pack: String?)
    case library
    case settings
    case wheel
    case quick
    case help
    /// Answer or explain what's on your screen, with a pack ("answer this using my MAT223 pack").
    case screen(String, pack: String?)
    /// The pack as a map of what's in it.
    case map(pack: String?)
    case openPack(String)
    case share(pack: String?)
    case copyPack(pack: String?)
    /// Take back the last thing saved, or move it.
    case undo
    case moveLast(pack: String)
    case rename(pack: String?, to: String)
    /// Types your words where the cursor is, as they are.
    case type(String)
    case openApp(String)
    case web(String)
    /// Stop reading aloud.
    case stop
    case note(String)

    static let examples = [
        "“Add this”", "“What does this mean?”", "“Answer this using my MAT223 pack”", "“Draft a reply saying I'll send it Friday”",
        "“Fill this form”", "“Switch to Acme, then add this”", "“Continue in Claude”", "“Show me the map of Acme”", "“Undo that”",
    ]

    var isNote: Bool { if case .note = self { return true } else { return false } }

    /// Ends in something you look at or finish yourself, so nothing should run straight after it.
    var opensPanel: Bool {
        switch self {
        case .scoop, .addScreen, .equip, .autoSort, .newPack, .keepUpdated, .undo, .moveLast, .rename, .copyPack, .type, .openApp, .web, .stop, .note:
            return false
        default:
            return true
        }
    }

    /// Carries your own words to the end of the sentence, so an "and" inside it is yours, not a new step.
    private var carriesText: Bool {
        switch self {
        case .draft, .ask, .screen, .note, .type, .web, .rename, .newPack: return true
        default: return false
        }
    }

    // MARK: Several steps in one breath

    /// What you said as steps, in order: "switch to Acme, then add this" is two. "Then" always starts a
    /// new step; "and" only does when both sides are things Shapr does (so "a reply saying yes and
    /// thanks" stays one draft).
    static func plan(_ raw: String, packs: [String]) -> [VoiceCommand] {
        // "Take a screenshot and add it to Acme" is one thing, not two.
        let whole = parse(raw, packs: packs)
        if case .addScreen = whole, raw.range(of: screenshotAndAdd, options: [.regularExpression, .caseInsensitive]) != nil { return [whole] }
        let splits: [(pattern: String, loose: Bool)] = [
            (#"[,;.]?\s+(and then|then|after that|and after that|and afterwards|afterwards|and next)\b[,]?\s+"#, false),
            (#"[.!?;]\s+"#, true),
            (#"[,]?\s+and( also)?\s+"#, true),
        ]
        for split in splits {
            guard let re = try? NSRegularExpression(pattern: split.pattern, options: [.caseInsensitive]) else { continue }
            for m in re.matches(in: raw, range: NSRange(raw.startIndex..., in: raw)) {
                guard let r = Range(m.range, in: raw) else { continue }
                let left = String(raw[..<r.lowerBound]), right = String(raw[r.upperBound...])
                guard left.count >= 3, right.count >= 3 else { continue }
                let first = parse(left, packs: packs)
                guard !first.isNote, !(split.loose && first.carriesText) else { continue }
                let rest = plan(right, packs: packs)
                guard !rest.contains(where: \.isNote) else { continue }
                return Array(([first] + rest).prefix(4))
            }
        }
        return [whole]
    }

    static let screenshotAndAdd = #"\b(take|grab|make|get) (a )?(screenshot|screen ?shot|picture|photo)( of (my|the|this)( whole| entire)? (screen|window|display|page))?,? and (then )?(add|save|put|keep|read|store|remember)\b"#

    // MARK: Parsing

    /// `packs`: your pack names, so "switch to Acme" and "ask Bug 42 …" find the right one.
    static func parse(_ raw: String, packs: [String]) -> VoiceCommand {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let isQuestion = s.hasSuffix("?")
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;"))
        // Fillers people say before a command.
        let filler = #"^(hey |hi |ok |okay |um+ |uh+ |so |alright |shapr[,.]? |shaper[,.]? |please |can you |could you |would you |will you |i want to |i'd like to |i need to |let's |go ahead and |now )"#
        while let r = s.range(of: filler, options: [.regularExpression, .caseInsensitive]) { s.removeSubrange(r) }
        s = s.replacingOccurrences(of: #"[,]? please$"#, with: "", options: [.regularExpression, .caseInsensitive])
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " .!?,;:"))
        guard !s.isEmpty else { return .note(raw) }
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        func rest(after p: String) -> String {
            guard let r = s.range(of: p, options: [.regularExpression, .caseInsensitive]) else { return "" }
            return String(s[r.upperBound...]).trimmingCharacters(in: CharacterSet(charactersIn: " ,:;.-"))
        }

        if has(#"^(stop|stop (talking|reading|speaking)|be quiet|quiet|never ?mind|cancel( that)?)$"#) { return .stop }
        if has(#"^(undo|undo (that|it|this|the last (one|capture|thing|note))|take (that|it) back|(remove|delete) (that|it|the last (one|capture|thing|note)))$"#) { return .undo }
        if has(#"^(move|put|send) (that|it|the last (one|capture|thing|note)) (to|into|in) "#), let p = trailingPack(t, packs: packs) { return .moveLast(pack: p) }
        if has(#"^rename\b"#) {
            let body = rest(after: #"^rename( (this|the|my)( current| equipped)? pack| it| this)?"#)
            if let r = body.range(of: #"^to\s+"#, options: [.regularExpression, .caseInsensitive]) {
                let name = String(body[r.upperBound...])
                if !name.isEmpty { return .rename(pack: nil, to: name) }
            } else if let r = body.range(of: #"\s+to\s+"#, options: [.regularExpression, .caseInsensitive]),
                      let p = matchPack(String(body[..<r.lowerBound]).replacingOccurrences(of: #"^(the |my )|( pack)$"#, with: "", options: [.regularExpression, .caseInsensitive]), in: packs) {
                let name = String(body[r.upperBound...])
                if !name.isEmpty { return .rename(pack: p, to: name) }
            }
        }
        if has(#"^(type|type out|type in)\b"#) {
            let body = rest(after: #"^(type out|type in|type)\b[,:]?"#)
            if !body.isEmpty { return .type(body) }
        }
        if has(#"^(search (the )?(web|internet|google)( for)?|search online( for)?|google|look up online)\b"#) {
            let q = rest(after: #"^(search (the )?(web|internet|google)( for)?|search online( for)?|google|look up online)\b"#)
            if !q.isEmpty { return .web(q) }
        }
        if has(#"^((show|open|see|view|draw)( me)?( the| a| my)? )?(map|graph|mind ?map)\b"#) { return .map(pack: packNamed(in: t, packs: packs)) }
        if has(#"^share\b"#) { return .share(pack: packNamed(in: t, packs: packs)) }
        if has(#"^copy( (this|the|my))?( .+)? (pack|notes)\b"#) || has(#"^copy .+ (for|to) (claude|chat ?gpt|gemini|an? ai|ai)\b"#) {
            return .copyPack(pack: packNamed(in: t, packs: packs))
        }

        if has(#"^(show (me )?(the |my )?options|what can i do here|show (me )?(the )?menu|options)$"#) { return .quick }
        if has(#"^(what can (i|you) (say|do)|help( me)?$|show (me )?(the )?commands|voice commands)"#) { return .help }

        // "Get the context of this chat", "remember this conversation", "use this page as context": save
        // what's in front of you (the whole chat, the page, or the window), maybe into a named pack.
        let thing = #"(chat|chats|conversation|convo|thread|discussion|messages|page|screen|display|desktop|window|tab|article|doc|document|pdf|email|message|site|website|video|slide|slides|post|file|code|answer|response)"#
        let whole = #"( whole| entire| full| current)?"#
        let dest = #"( (to|into|in|for) .+)?$"#
        // Saying "my screen" means the screen itself: a picture of it, read.
        let wantsScreen = has(#"\b(my|the|this|whole|entire|current) (screen|display|desktop)\b"#)
        if has(screenshotAndAdd) { return .addScreen(pack: trailingPack(t, packs: packs)) }
        if has(#"^(get|grab|take|pull|capture|collect|import|load|fetch|pick up|bring in)( in)?( all)?( of)?( the)? (context|content|contents|info|information|text|everything)( (of|from|in|on|out of) (this|that|the|my)\#(whole)( [a-z0-9]+)??( \#(thing))?)?\#(dest)"#)
            || has(#"^(remember|learn|take in|ingest|absorb) (this|that|the|my)\#(whole)( [a-z0-9]+)?? \#(thing)( as (context|a note|notes|reference))?\#(dest)"#)
            || has(#"^use (this|that|the|my)\#(whole)( [a-z0-9]+)?? \#(thing) (as|for) (context|reference)\#(dest)"#) {
            return wantsScreen ? .addScreen(pack: trailingPack(t, packs: packs)) : .scoop(pack: trailingPack(t, packs: packs))
        }

        // Notes you say on purpose.
        if has(#"^(take|make|add|write|jot)( down)? (a |an )?(quick )?note\b"#) || has(#"^note\b"#) {
            let body = rest(after: #"^((take|make|add|write|jot)( down)? (a |an )?(quick )?note|note)\b( that)?[,:]?"#)
            return .note(body.isEmpty ? raw : body)
        }
        if has(#"^(remember|remind me to)\b"#) { return .note(s) }

        // Another AI.
        if let r = t.range(of: #"^(continue|move|carry|take|switch|open|send|finish)( this| the)?( chat| conversation)?( over)? (in|to|into|on) (chat ?gpt|claude|gemini)\b"#, options: .regularExpression) {
            let said = String(t[r])
            return .continueIn(said.contains("claude") ? "Claude" : said.contains("gemini") ? "Gemini" : "ChatGPT")
        }

        if has(#"^(auto ?fill|fill)\b"#) { return .fill }

        if has(#"^((take|grab|make) (a )?)?(screenshot|screen ?shot|screen capture|screen grab)\b"#)
            || has(#"^(circle|capture (the |my )?screen|capture (an |the |part of the )?(area|screen|region))\b"#) { return .screenshot }

        // Answer, solve or explain what's on screen ("answer this using my MAT223 pack", "what's on my screen?").
        if isScreenRequest(t) { return .screen(s, pack: mentionedPack(t, packs: packs)) }

        if has(#"^(save|update|record) (my |the )?(progress|place)\b"#) || has(#"^(checkpoint|save where i am)\b"#) { return .saveProgress }
        if has(#"^(resume|pick up where|continue where|carry on where|continue my work|where was i|where did i leave off)"#) { return .resume }

        // Keep a page, thread or repo up to date in a pack.
        if has(#"^(keep|follow|watch|track|sync)( this| the)?( page| thread| repo| repository| doc| document| email| site| tab)?\b.*\b(updated|up to date|in sync|synced|live)\b"#)
            || has(#"^(follow|watch|track) (this|the) (page|thread|repo|repository|doc|document|site)\b"#) {
            return .keepUpdated(pack: trailingPack(t, packs: packs))
        }

        if has(#"^(use (this|it|that) with|help me with (this|that)|what does my pack say about (this|that)|connect (this|that))\b"#) { return .use }

        // Save the selection, or what's on screen when nothing is selected, maybe into a named pack.
        if has(#"^(save|scoop|capture|grab|clip|keep|add|store)( this| that| it| the selection| the text| what i selected| the selected text| selection)\b"#)
            || has(#"^(add|save|keep|put|store|clip|grab)( (this|that|it|these|the|my))?\#(whole)( ([a-z0-9]+ )?(\#(thing)|link))?( as (context|a note|notes|reference))?( (to|into|in) .+)?$"#)
            || has(#"^(add|save|keep|get|grab|store|remember) what'?s on (my |the )?(screen|display)\b"#) {
            return wantsScreen || has(#"what'?s on (my |the )?(screen|display)\b"#)
                ? .addScreen(pack: trailingPack(t, packs: packs)) : .scoop(pack: trailingPack(t, packs: packs))
        }


        if has(#"^(make|create|start|new|add|open)( me)?( a)?( new)? pack\b"#) {
            let name = rest(after: #"^(make|create|start|new|add|open)( me)?( a)?( new)? pack\b( (called|named|for))?"#)
            return .newPack(name.isEmpty ? nil : name)
        }

        if has(#"^((turn on |switch (back )?to |go back to |use )?auto[ -]?sort|unequip|(switch|go) back to auto)\b"#) { return .autoSort }

        if has(#"^(open|show|go to)( me)?( the| my)? (library|packs)\b"#) { return .library }
        if has(#"^(open |show )?(the )?(settings|preferences)\b"#) { return .settings }
        if has(#"^((open|show) (the )?wheel|the wheel|(switch|change|pick) (a |the )?packs?)$"#) { return .wheel }

        // "Open MAT223" is a pack; "open Safari" is an app.
        if has(#"^(open|launch|start)( up)? "#) {
            let name = rest(after: #"^(open|launch|start)( up)?( the| my)?"#)
                .replacingOccurrences(of: #"\s+(pack|notes|app)$"#, with: "", options: [.regularExpression, .caseInsensitive])
            if let p = matchPack(name, in: packs) { return .openPack(p) }
            if has(#"^(open|launch|start) "#), !name.isEmpty, name.split(separator: " ").count <= 3 { return .openApp(name) }
        }

        // "Tell me…", "explain…", "summarize…" are questions for your packs.
        if has(#"^(tell me|explain|summari[sz]e|remind me (what|when|who|where|how|why|about)|give me (a )?(summary|rundown)|what's|whats)\b"#)
            || has(#"^(show me|find|list) (?!(the |my )?(library|packs|settings|wheel|options|menu)\b)"#) {
            return .ask(s, pack: nil)
        }

        // "switch to Acme", "equip Bug 42", "use the Acme pack"
        if let r = t.range(of: #"^(switch|change|equip|use|go|move)( over)?( to)?( the)?( pack)? "#, options: .regularExpression) {
            let name = String(t[r.upperBound...]).replacingOccurrences(of: #"\s+pack$"#, with: "", options: .regularExpression)
            if let p = matchPack(name, in: packs) { return .equip(p) }
        }

        // Drafting where you're typing.
        if has(#"^(draft|write|compose|reply|respond|answer (this|that|it|them|her|him)|write back)\b"#) {
            var i = rest(after: #"^(draft|write|compose|reply|respond|answer|write back)\b"#)
            i = i.replacingOccurrences(of: #"^(a |an )?(quick |short )?(reply|email|message|response|comment|answer|draft)?((to )?(this|that|it|them|her|him|the email|the message)( email| message)? ?)?(back)?[,:]?\s*"#,
                                       with: "", options: [.regularExpression, .caseInsensitive])
            i = i.replacingOccurrences(of: #"^(saying|that says|to say|telling (them|her|him)|and say)\s+"#, with: "", options: [.regularExpression, .caseInsensitive])
            return .draft(i.trimmingCharacters(in: .whitespaces))
        }

        // "Ask Acme when the proposal is due", "search my packs for the invoice"
        if has(#"^(ask|search|look up|find out|check)\b"#) {
            var q = rest(after: #"^(ask|search|look up|find out|check)\b"#)
            var pack: String?
            if let r = q.range(of: #"^(my |all )?(packs?|notes|shapr)\b( for| about)?"#, options: [.regularExpression, .caseInsensitive]) {
                q.removeSubrange(r)
            } else {
                let words = q.split(separator: " ").map(String.init)
                for n in stride(from: min(4, words.count - 1), through: 1, by: -1) {
                    let lead = words.prefix(n).joined(separator: " ").replacingOccurrences(of: #"^the "#, with: "", options: [.regularExpression, .caseInsensitive])
                    if let p = matchPack(lead, in: packs, exactOnly: true) {
                        pack = p
                        q = words.dropFirst(n).joined(separator: " ")
                        q = q.replacingOccurrences(of: #"^(pack\s+)?(for |about )?"#, with: "", options: [.regularExpression, .caseInsensitive])
                        break
                    }
                }
            }
            q = q.trimmingCharacters(in: CharacterSet(charactersIn: " ,:"))
            return .ask(q.isEmpty ? s : q, pack: pack)
        }

        // A question goes to Ask; anything else is a note.
        if isQuestion || has(#"^(what|when|where|who|whom|whose|why|how|which|did|does|is|are|was|were)\b"#) {
            return .ask(s + (isQuestion ? "?" : ""), pack: nil)
        }
        return .note(raw.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "Answer this", "solve this question", "use my MAT223 pack to answer this", "what's on my screen", "what does this mean".
    /// An email or message to answer is a draft, not this.
    static func isScreenRequest(_ t: String) -> Bool {
        func has(_ p: String) -> Bool { t.range(of: p, options: .regularExpression) != nil }
        if has(#"(screen ?shot|screen capture|capture (the |my )?screen)"#) { return false }
        // "Add what's on my screen" saves it; it isn't a question.
        if has(#"^(add|save|keep|put|store|clip|grab|remember)\b"#) { return false }
        if has(#"^(get|pull|collect|capture) (what'?s on|everything on|all of|(the )?(context|content|contents|text|info) (of|from|on))\b"#) { return false }
        // "Summarize this page", "translate this to French", "explain this email": about what's in front of you.
        if has(#"^(summari[sz]e|translate|explain|tl;?dr|give me (a |the )?(summary|gist|tl;?dr) of)( (this|that|it|the))?( (page|article|screen|doc|document|pdf|paper|post|thread|video|tab|site|website|email|message|paragraph|text))?( for me)?( (in|to|into) [a-z]+)?$"#) { return true }
        if has(#"\b(email|message|text|comment|tweet|post|dm|reply|them|her|him)\b"#) { return false }
        if has(#"\b(on|from|using|use|with|read|look at|see|check) (my |the )?screen\b"#) || has(#"\bwhat'?s on (my |the )?screen\b"#)
            || has(#"\bwhat i'?m (looking at|seeing|working on)\b"#) { return true }
        let nouns = #"( question| questions| problem| problems| exercise| quiz| one| part| homework| assignment| equation| proof| page| error| code| graph| chart| diagram| table| paragraph| passage| slide)?"#
        if has(#"^(answer|solve|do|work out|figure out|complete|finish|check|explain|help me (with|answer|solve|do|understand))( this| that| it| these| those| the)?"# + nouns
               + #"( for me| on (my |the )?screen)?( (using|with|from|in|by using) (my |the )?.+)?$"#) { return true }
        if has(#"^use (my |the )?.+? (pack|notes) to (answer|solve|explain|do|work out|check)\b"#) { return true }
        return has(#"^(what('s| is| does) (this|that)( mean| say| error| question)?|what am i looking at|is this (right|correct)|how do i (solve|do|answer) (this|it))\b"#)
    }

    /// "… using my MAT223 pack", "use the Acme pack to …", "… with my Acme notes", "… in Acme"
    static func mentionedPack(_ t: String, packs: [String]) -> String? {
        for p in [#"\b(?:using|with|from|in|by using) (?:my |the )?(.+?)(?: pack| notes)?(?: to .*)?$"#, #"^use (?:my |the )?(.+?) (?:pack|notes) to "#] {
            guard let re = try? NSRegularExpression(pattern: p),
                  let m = re.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)), let r = Range(m.range(at: 1), in: t) else { continue }
            let words = t[r].split(separator: " ").map(String.init)
            // Try the longest run of words that names a pack ("my mat223 pack notes" → "mat223").
            for n in stride(from: min(4, words.count), through: 1, by: -1) {
                if let name = matchPack(words.prefix(n).joined(separator: " "), in: packs) { return name }
            }
        }
        return nil
    }

    /// Sounds like asking Shapr to do something (not dictating a note), so it's worth working out which command.
    static func looksLikeRequest(_ raw: String) -> Bool {
        let t = raw.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        if t.range(of: #"^(remember|note|take a note|remind me to)\b"#, options: .regularExpression) != nil { return false }
        if t.range(of: #"^(please|can you|could you|would you|will you|i want|i'd like|i need|help me|let's|get|show|open|make|create|start|put|move|send|copy|share|go|set|turn|switch|change|use|do|bring|pull up|give|check|look|take|grab|hey|ok|okay|shapr)\b"#,
                   options: .regularExpression) != nil || t.contains(" for me") { return true }
        // Starts with a verb ("translate this", "compare these two"): an instruction, not something to remember.
        let tagger = NLTagger(tagSchemes: [.lexicalClass])
        tagger.string = t
        return tagger.tag(at: t.startIndex, unit: .word, scheme: .lexicalClass).0 == .verb
    }

    /// A pack named anywhere in what you said ("show me the map of my acme pack").
    static func packNamed(in t: String, packs: [String]) -> String? {
        let said = " " + normalize(t) + " "
        return packs.filter { !normalize($0).isEmpty && said.contains(" " + normalize($0) + " ") }
            .max { normalize($0).count < normalize($1).count }
    }

    /// "… in the Acme pack", "… to Acme"
    private static func trailingPack(_ t: String, packs: [String]) -> String? {
        guard let r = t.range(of: #"\b(in|into|to|for)( the)? (.+?)( pack)?$"#, options: .regularExpression) else { return nil }
        let tail = String(t[r]).replacingOccurrences(of: #"^(in|into|to|for)( the)? "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"^(my|our) "#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #" (pack|notes)$"#, with: "", options: .regularExpression)
        return matchPack(tail, in: packs)
    }

    static func normalize(_ s: String) -> String {
        s.lowercased().unicodeScalars.map { CharacterSet.alphanumerics.contains($0) && $0.isASCII ? String($0) : " " }.joined()
            .split(separator: " ").joined(separator: " ")
    }

    /// The pack you meant: an exact name (ignoring case, emoji and punctuation), else the one pack that
    /// contains what you said.
    static func matchPack(_ said: String, in packs: [String], exactOnly: Bool = false) -> String? {
        let n = normalize(said)
        guard !n.isEmpty else { return nil }
        if let exact = packs.first(where: { normalize($0) == n }) { return exact }
        guard !exactOnly, n.count >= 3 else { return nil }
        let partial = packs.filter { let p = normalize($0); return !p.isEmpty && (p.hasPrefix(n + " ") || p.contains(" " + n) || n.contains(p)) }
        return partial.count == 1 ? partial[0] : nil
    }

    /// What Shapr shows it heard.
    var label: String {
        switch self {
        case .draft: return "Drafting a reply"
        case .ask: return "Asking your packs"
        case .use: return "Using this with your pack"
        case .scoop(let p): return p.map { "Saving to \($0)" } ?? "Saving this"
        case .addScreen(let p): return p.map { "Reading your screen into \($0)" } ?? "Saving what's on your screen"
        case .screenshot: return "Circle what you want"
        case .fill: return "Filling this form"
        case .saveProgress: return "Saving progress"
        case .resume: return "Continuing where you left off"
        case .continueIn(let s): return "Continuing in \(s)"
        case .equip(let p): return "Switching to \(p)"
        case .autoSort: return "Auto-sort on"
        case .newPack: return "New pack"
        case .keepUpdated: return "Keeping this updated"
        case .library: return "Opening the library"
        case .settings: return "Opening Settings"
        case .wheel: return "Opening the wheel"
        case .quick: return "What you can do here"
        case .screen: return "Reading your screen"
        case .map(let p): return p.map { "Opening the map of \($0)" } ?? "Opening the map"
        case .openPack(let p): return "Opening \(p)"
        case .share(let p): return p.map { "Sharing \($0)" } ?? "Sharing this pack"
        case .copyPack(let p): return p.map { "Copying \($0)" } ?? "Copying this pack"
        case .undo: return "Taking that back"
        case .moveLast(let p): return "Moving it to \(p)"
        case .rename(_, let n): return "Renaming to \(n)"
        case .type: return "Typing"
        case .openApp(let a): return "Opening \(a)"
        case .web(let q): return "Searching for \(q)"
        case .stop: return "Stopping"
        case .help: return "What you can say"
        case .note: return "Voice note"
        }
    }
}

// MARK: - Understanding other phrasings (Apple Intelligence, on this Mac)

@Generable
struct VoiceIntentChoice {
    @Guide(description: "What the user wants Shapr to do", .anyOf(["draft", "ask", "use", "save_selection", "screenshot", "fill_form",
                                                                  "save_progress", "resume", "continue_in_chatgpt", "continue_in_claude",
                                                                  "continue_in_gemini", "switch_pack", "auto_sort", "new_pack", "keep_updated",
                                                                  "open_library", "open_settings", "open_wheel", "show_options", "answer_screen",
                                                                  "save_screen", "show_map", "open_pack", "share_pack", "copy_pack", "undo", "move_last",
                                                                  "rename_pack", "type_text", "open_app", "web_search", "stop", "note"]))
    var action: String
    @Guide(description: "The name of a pack the user mentioned, copied exactly from the list of packs, or an empty string")
    var pack: String
    @Guide(description: "For draft: what the message should say. For ask: the question. For new_pack and rename_pack: the new name. For type_text: the words to type. For open_app: the app's name. For web_search: what to search for. Otherwise an empty string.")
    var text: String
}

@Generable
struct VoicePlanChoice {
    @Guide(description: "The steps to do, in the order they were said. Usually one; at most three.", .maximumCount(3))
    var steps: [VoiceIntentChoice]
}

/// When the words don't match a known command, the on-device model picks one (or decides it's a note).
enum VoiceIntent {
    static let instructions = """
    You turn what someone said to Shapr, a Mac app that collects notes into "packs", into the steps to do, in order. \
    Most requests are one step. Each step is exactly one action:
    draft (write a reply or message where they're typing), ask (a question their notes can answer), use (use what's on \
    screen with their pack), save_selection (save the text they selected, or the chat, page or window they're on, to a \
    pack), save_screen (take a picture of their screen, read it, and save it to a pack), screenshot (let them circle part \
    of the screen), fill_form, save_progress, resume (continue earlier work), continue_in_chatgpt, continue_in_claude, \
    continue_in_gemini, switch_pack (to a pack by name), auto_sort, new_pack, keep_updated (keep this page updated in a pack), \
    open_library, open_settings, open_wheel, show_options, answer_screen (answer, solve, summarize, translate or explain \
    what's on their screen), show_map (the pack drawn as a map), open_pack, share_pack, copy_pack (copy a pack to paste into \
    an AI), undo (take back the last thing saved), move_last (move the last thing saved to a pack), rename_pack, type_text \
    (type their words where the cursor is), open_app, web_search, stop (stop reading aloud), \
    note (they're dictating something to remember, not asking Shapr to act).
    If you're unsure, choose note.
    """

    /// The steps the on-device model makes of what you said, or nil when it's a note (or the model isn't there).
    @MainActor
    static func plan(_ text: String, packs: [String]) async -> [VoiceCommand]? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let prompt = "Packs: \(packs.prefix(30).joined(separator: ", "))\nThey said: \"\(text)\""
        let result: VoicePlanChoice? = await withTaskGroup(of: VoicePlanChoice?.self) { g in
            g.addTask { @MainActor in
                try? await LanguageModelSession(instructions: instructions).respond(to: prompt, generating: VoicePlanChoice.self).content
            }
            g.addTask { try? await Task.sleep(for: .seconds(6)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        return result.flatMap { steps($0, packs: packs, said: text) }
    }

    /// The model's steps as commands. If any step isn't something Shapr does, nothing runs (it's a note).
    static func steps(_ plan: VoicePlanChoice, packs: [String], said: String) -> [VoiceCommand]? {
        let mapped = plan.steps.prefix(3).map { map($0, packs: packs, said: said) }
        guard !mapped.isEmpty, !mapped.contains(where: { $0 == nil }) else { return nil }
        return mapped.compactMap { $0 }
    }

    @MainActor
    static func classify(_ text: String, packs: [String]) async -> VoiceCommand? {
        guard case .available = SystemLanguageModel.default.availability else { return nil }
        let prompt = "Packs: \(packs.prefix(30).joined(separator: ", "))\nThey said: \"\(text)\""
        let result: VoiceIntentChoice? = await withTaskGroup(of: VoiceIntentChoice?.self) { g in
            g.addTask { @MainActor in
                try? await LanguageModelSession(instructions: instructions).respond(to: prompt, generating: VoiceIntentChoice.self).content
            }
            g.addTask { try? await Task.sleep(for: .seconds(5)); return nil }
            let first = await g.next() ?? nil
            g.cancelAll()
            return first
        }
        return result.flatMap { map($0, packs: packs, said: text) }
    }

    /// The model's choice as a command. A pack it names must really exist; otherwise nothing happens.
    static func map(_ c: VoiceIntentChoice, packs: [String], said: String) -> VoiceCommand? {
        let pack = c.pack.nonEmpty.flatMap { VoiceCommand.matchPack($0, in: packs) }
        let text = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
        switch c.action {
        case "draft": return .draft(text)
        case "ask": return .ask(text.isEmpty ? said : text, pack: pack)
        case "use": return .use
        case "save_selection": return .scoop(pack: pack)
        case "save_screen": return .addScreen(pack: pack)
        case "screenshot": return .screenshot
        case "fill_form": return .fill
        case "save_progress": return .saveProgress
        case "resume": return .resume
        case "continue_in_chatgpt": return .continueIn("ChatGPT")
        case "continue_in_claude": return .continueIn("Claude")
        case "continue_in_gemini": return .continueIn("Gemini")
        case "switch_pack": return pack.map { .equip($0) }
        case "auto_sort": return .autoSort
        case "new_pack": return .newPack(text.isEmpty ? nil : text)
        case "keep_updated": return .keepUpdated(pack: pack)
        case "open_library": return .library
        case "open_settings": return .settings
        case "open_wheel": return .wheel
        case "show_options": return .quick
        case "answer_screen": return .screen(text.isEmpty ? said : text, pack: pack)
        case "show_map": return .map(pack: pack)
        case "open_pack": return pack.map { .openPack($0) }
        case "share_pack": return .share(pack: pack)
        case "copy_pack": return .copyPack(pack: pack)
        case "undo": return .undo
        case "move_last": return pack.map { .moveLast(pack: $0) }
        case "rename_pack": return text.isEmpty ? nil : .rename(pack: pack, to: text)
        case "type_text": return text.isEmpty ? nil : .type(text)
        case "open_app": return text.isEmpty ? nil : .openApp(text)
        case "web_search": return .web(text.isEmpty ? said : text)
        case "stop": return .stop
        default: return nil
        }
    }
}
