import AppKit
import ApplicationServices

/// One message in an AI chat.
struct ChatTurn: Codable, Hashable {
    enum Role: String, Codable { case user, assistant, unknown }
    var role: Role
    var text: String
}

/// A conversation read off the screen of an AI chat (ChatGPT, Claude, Gemini…), kept word for word.
struct ChatTranscript: Codable, Hashable {
    /// "ChatGPT", "Claude", "Gemini"…
    var service: String
    var url: String?
    var title: String?
    var read = Date()
    var turns: [ChatTurn]

    var userTurns: [ChatTurn] { turns.filter { $0.role == .user } }
    var lastAssistant: ChatTurn? { turns.last { $0.role == .assistant } }
    var lastUser: ChatTurn? { turns.last { $0.role == .user } }
    var hasRoles: Bool { turns.contains { $0.role != .unknown } }

    /// "Me:" / "ChatGPT:" lines, for search and for the full copy Shapr hands over on request.
    var plainText: String {
        turns.map { t in
            let who = t.role == .user ? "Me" : t.role == .assistant ? service : "Chat"
            return "\(who): \(t.text)"
        }.joined(separator: "\n\n")
    }
}

/// Reads the conversation in an AI chat window through Accessibility, in document order.
/// It never clicks, scrolls, types or touches the clipboard. Not tied to the main actor, so the
/// (sometimes slow) walk of a long chat runs off the main thread.
enum ChatReader {
    /// A lightweight copy of the part of the Accessibility tree that matters, so parsing can be tested
    /// without a real browser.
    struct Node {
        var role: String
        var subrole: String? = nil
        var classes: [String] = []
        var text: String? = nil
        var children: [Node] = []
    }

    // MARK: Which chats

    struct Service { let name: String; let newChatURL: String; let desktopBundleID: String? }

    static let services: [Service] = [
        Service(name: "ChatGPT", newChatURL: "https://chatgpt.com/", desktopBundleID: "com.openai.chat"),
        Service(name: "Claude", newChatURL: "https://claude.ai/new", desktopBundleID: "com.anthropic.claudefordesktop"),
        Service(name: "Gemini", newChatURL: "https://gemini.google.com/app", desktopBundleID: nil),
    ]

    static func service(named name: String) -> Service? { services.first { $0.name == name } }

    /// The AI chat service for a site or app, if it is one.
    static func service(url: String?, bundleID: String?) -> String? {
        let host = url.flatMap { URL(string: $0)?.host?.lowercased() } ?? ""
        func hostIs(_ h: String) -> Bool { host == h || host.hasSuffix("." + h) }
        if hostIs("chatgpt.com") || hostIs("chat.openai.com") || bundleID == "com.openai.chat" { return "ChatGPT" }
        if hostIs("claude.ai") || bundleID == "com.anthropic.claudefordesktop" { return "Claude" }
        if hostIs("gemini.google.com") { return "Gemini" }
        if hostIs("perplexity.ai") { return "Perplexity" }
        if hostIs("chat.deepseek.com") { return "DeepSeek" }
        if hostIs("copilot.microsoft.com") { return "Copilot" }
        return nil
    }

    // MARK: Reading a live window

    /// Takes a snapshot of the front window's page in `pid`, within `budget` seconds.
    static func snapshot(pid: pid_t, budget: TimeInterval = 2.5, maxNodes: Int = 40_000, skipMessages: Bool = false) -> Node? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Chromium and Electron apps (Chrome, Arc, the Claude app) only build their full tree for
        // assistive apps that ask for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) else { return nil }
        let web = findWebArea(in: window)
        let deadline = Date().addingTimeInterval(budget)
        var count = 0
        return copy(web ?? window, deadline: deadline, count: &count, maxNodes: maxNodes, depth: 0,
                    skipMessages: skipMessages, web: web != nil)
    }

    /// Reads the conversation in `app`'s front window.
    static func read(pid: pid_t, service: String, url: String?, title: String?) -> ChatTranscript? {
        guard let root = snapshot(pid: pid) else { return nil }
        let turns = parse(root, service: service)
        guard !turns.isEmpty else { return nil }
        return ChatTranscript(service: service, url: url, title: cleanTitle(title, service: service), turns: turns)
    }

    struct PageInfo { var url: String?; var title: String? }

    /// The page's address and the window title, straight from Accessibility (no AppleScript).
    static func pageInfo(pid: pid_t) -> PageInfo {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) else { return PageInfo() }
        var info = PageInfo(title: attr(window, kAXTitleAttribute))
        if let web = findWebArea(in: window) {
            if let u: URL = attr(web, "AXURL") { info.url = u.absoluteString }
            else if let u: NSURL = attr(web, "AXURL") { info.url = u.absoluteString }
            if info.title?.nonEmpty == nil { info.title = attr(web, kAXTitleAttribute) }
        }
        return info
    }

    /// A conversation page: not settings, a project list, or Claude Code inside the Claude app.
    /// Native chat apps (no address) count.
    static func isChatPage(_ url: String?) -> Bool {
        guard let url else { return true }
        guard let u = URL(string: url), let host = u.host?.lowercased() else { return false }
        let p = u.path.lowercased()
        switch host {
        case "claude.ai": return p.isEmpty || p == "/" || p.hasPrefix("/chat") || p.hasPrefix("/new") || p.hasPrefix("/project")
        case "chatgpt.com", "chat.openai.com": return p.isEmpty || p == "/" || p.hasPrefix("/c/") || p.hasPrefix("/g/")
        case "gemini.google.com": return p.hasPrefix("/app") || p.hasPrefix("/gem")
        default: return true
        }
    }

    static let browserIDs: Set<String> = ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome",
                                          "company.thebrowser.Browser", "com.brave.Browser", "com.microsoft.edgemac", "com.vivaldi.Vivaldi"]

    /// Only browsers and the AI desktop apps can be AI chats; everything else is skipped without a look.
    static func mightBeChat(bundleID: String?) -> Bool {
        guard let b = bundleID else { return false }
        return browserIDs.contains(b) || services.contains { $0.desktopBundleID == b }
    }

    /// A fast guess (a few Accessibility calls) at whether the front app shows an AI chat: walks up from
    /// the focused element to the page and reads its address. For the ⌥⇧Space panel, which must open at once.
    static func quickService(pid: pid_t, bundleID: String?) -> String? {
        guard mightBeChat(bundleID: bundleID) else { return nil }
        if let b = bundleID, let s = services.first(where: { $0.desktopBundleID == b }) { return s.name }
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.1)
        guard var el: AXUIElement = attr(app, kAXFocusedUIElementAttribute) else { return nil }
        for _ in 0..<40 {
            if (attr(el, kAXRoleAttribute) as String?) == "AXWebArea" {
                let u: URL? = attr(el, "AXURL")
                return service(url: u?.absoluteString, bundleID: bundleID)
            }
            guard let parent: AXUIElement = attr(el, kAXParentAttribute) else { break }
            el = parent
        }
        return nil
    }

    /// True when the cursor is already in a text box (cheap; checked before searching the page for one).
    static func composerFocused(pid: pid_t) -> Bool {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.2)
        guard let focused: AXUIElement = attr(app, kAXFocusedUIElementAttribute) else { return false }
        return ["AXTextArea", "AXTextField"].contains((attr(focused, kAXRoleAttribute) as String?) ?? "")
    }

    /// The chat's message box: the last editable text area on the page.
    private static func composer(pid: pid_t) -> AXUIElement? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        guard let window: AXUIElement = attr(app, kAXFocusedWindowAttribute) ?? attr(app, kAXMainWindowAttribute) else { return nil }
        let root = findWebArea(in: window) ?? window
        var found: AXUIElement?
        var stack = [root]
        var seen = 0
        while let el = stack.popLast(), seen < 20_000 {
            seen += 1
            let role: String? = attr(el, kAXRoleAttribute)
            if role == "AXTextArea" || role == "AXTextField" {
                var settable = DarwinBoolean(false)
                AXUIElementIsAttributeSettable(el, kAXFocusedAttribute as CFString, &settable)
                if settable.boolValue { found = el; break }
                continue
            }
            if role == "AXButton" || role == "AXImage" { continue }
            // Depth first, last child first: the message box is near the end of the page.
            let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
            stack += kids
        }
        return found
    }

    /// Puts the cursor in the chat's message box. True if it's there.
    @discardableResult
    static func focusComposer(pid: pid_t) -> Bool {
        if composerFocused(pid: pid) { return true }
        guard let box = composer(pid: pid) else { return false }
        AXUIElementSetAttributeValue(box, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        return true
    }

    /// What's typed in the message box now (to check a paste landed before pressing Return).
    static func composerText(pid: pid_t) -> String? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        if let focused: AXUIElement = attr(app, kAXFocusedUIElementAttribute),
           ["AXTextArea", "AXTextField"].contains((attr(focused, kAXRoleAttribute) as String?) ?? ""),
           let v: String = attr(focused, kAXValueAttribute) {
            return v
        }
        return composer(pid: pid).flatMap { attr($0, kAXValueAttribute) }
    }

    /// The page in a window. Some apps (the Claude and ChatGPT desktop apps) nest the chat page inside an
    /// outer one, so prefer a page on an AI chat site, then the biggest page.
    private static func findWebArea(in root: AXUIElement) -> AXUIElement? {
        var areas: [AXUIElement] = []
        var queue = [root]
        var head = 0
        while head < queue.count, head < 6000 {
            let el = queue[head]; head += 1
            if (attr(el, kAXRoleAttribute) as String?) == "AXWebArea" {
                areas.append(el)
                if areas.count >= 6 { break }
            }
            queue += (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []
        }
        guard areas.count > 1 else { return areas.first }
        if let chat = areas.first(where: { el in
            let u: URL? = attr(el, "AXURL")
            return service(url: u?.absoluteString, bundleID: nil) != nil
        }) { return chat }
        func size(_ el: AXUIElement) -> CGFloat {
            guard let v: AXValue = attr(el, kAXSizeAttribute) else { return 0 }
            var sz = CGSize.zero
            AXValueGetValue(v, .cgSize, &sz)
            return sz.width * sz.height
        }
        func childCount(_ el: AXUIElement) -> Int { ((attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []).count }
        return areas.max { (size($0), childCount($0)) < (size($1), childCount($1)) }
    }

    private static let keys = [kAXRoleAttribute, kAXSubroleAttribute, "AXDOMClassList", kAXValueAttribute, kAXChildrenAttribute] as CFArray

    /// Controls whose text isn't part of the conversation: buttons, menus, and (on web pages) the message box.
    private static let skipRoles: Set<String> = ["AXButton", "AXPopUpButton", "AXMenuButton", "AXMenu", "AXMenuBar",
                                                 "AXComboBox", "AXSearchField", "AXImage", "AXToolbar"]
    private static let fieldRoles: Set<String> = ["AXTextArea", "AXTextField"]

    private static func copy(_ el: AXUIElement, deadline: Date, count: inout Int, maxNodes: Int, depth: Int,
                             skipMessages: Bool, web: Bool) -> Node {
        count += 1
        var values: CFArray?
        var node = Node(role: "")
        if AXUIElementCopyMultipleAttributeValues(el, keys, [], &values) == .success, let arr = values as? [Any], arr.count == 5 {
            node.role = arr[0] as? String ?? ""
            node.subrole = arr[1] as? String
            node.classes = arr[2] as? [String] ?? []
            if node.role == "AXStaticText" || node.role == "AXHeading" { node.text = arr[3] as? String }
            if fieldRoles.contains(node.role) {
                // Native chat apps show messages in read-only text views; on a web page it's the message box.
                guard !web else { return Node(role: "AXGroup") }
                node.role = "AXStaticText"
                node.text = arr[3] as? String
                return node
            }
            let pruned = skipRoles.contains(node.role)
                || skipMessages && (hint(node) != nil || node.subrole == "AXDocumentArticle")
            if node.role != "AXStaticText", !pruned, depth < 80, count < maxNodes, Date() < deadline,
               let kids = arr[4] as? [AXUIElement] {
                for k in kids {
                    guard count < maxNodes, Date() < deadline else { break }
                    node.children.append(copy(k, deadline: deadline, count: &count, maxNodes: maxNodes, depth: depth + 1,
                                              skipMessages: skipMessages, web: web))
                }
            }
        }
        return node
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    static func cleanTitle(_ title: String?, service: String) -> String? {
        guard var t = title?.nonEmpty else { return nil }
        for suffix in [" - ChatGPT", " | ChatGPT", " - Claude", " | Claude", " - Gemini", " | Gemini", " - Google Gemini"] where t.hasSuffix(suffix) {
            t = String(t.dropLast(suffix.count))
        }
        let generic = ["chatgpt", "claude", "gemini", "new chat", "google gemini"]
        return generic.contains(t.lowercased()) ? nil : t
    }

    // MARK: Parsing

    /// Class names that mark a message, from the chat sites' own pages.
    static let userClasses = ["font-user-message", "user-message", "user-query", "query-text", "user-query-container",
                              "user-message-bubble-color", "human-message"]
    static let assistantClasses = ["font-claude-response", "font-claude-message", "model-response", "model-response-text",
                                   "markdown", "prose", "response-content", "assistant-message", "message-content-assistant"]

    /// Visually hidden labels some chats put before each message ("You said:", "ChatGPT said:").
    static func speakerLabel(_ s: String) -> ChatTurn.Role? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard t.count <= 28 else { return nil }
        if t.range(of: #"^(you said|you wrote|you sent|you|me)\s*:?$"#, options: .regularExpression) != nil { return .user }
        if t.range(of: #"^(chatgpt|claude|gemini|copilot|perplexity|deepseek|assistant|the assistant)( said| responded| wrote| replied)?\s*:?$"#,
                   options: .regularExpression) != nil { return .assistant }
        return nil
    }

    /// The same labels at the start of a line that goes on with the message ("You said: build all of it").
    static func speakerPrefix(_ s: String) -> (role: ChatTurn.Role, rest: String)? {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        let patterns: [(String, ChatTurn.Role)] = [
            (#"^(you said|you wrote|you sent)\s*:\s*"#, .user),
            (#"^(chatgpt|claude|gemini|copilot|perplexity|deepseek|the assistant)( said| responded| wrote| replied)\s*:\s*"#, .assistant),
        ]
        for (p, role) in patterns {
            if let r = t.range(of: p, options: [.regularExpression, .caseInsensitive]) { return (role, String(t[r.upperBound...])) }
        }
        return speakerLabel(t).map { ($0, "") }
    }

    static func hint(_ n: Node) -> ChatTurn.Role? {
        let cls = n.classes.map { $0.lowercased() }
        if cls.contains(where: { c in userClasses.contains(c) }) { return .user }
        if cls.contains(where: { c in assistantClasses.contains(c) }) { return .assistant }
        return nil
    }

    static func isCode(_ n: Node) -> Bool {
        n.classes.contains { $0.hasPrefix("language-") || $0 == "hljs" || $0 == "code-block" || $0 == "code-block__code" }
    }

    /// The readable text of a subtree: paragraphs on their own lines, inline pieces joined, code fenced.
    static func text(of n: Node) -> String {
        if n.role == "AXStaticText" { return n.text ?? "" }
        if isCode(n) {
            let body = n.children.map(text(of:)).joined()
            return body.isEmpty ? "" : "\n```\n" + body.trimmingCharacters(in: .newlines) + "\n```\n"
        }
        if n.role == "AXHeading", n.children.isEmpty { return n.text ?? "" }
        // A paragraph with inline bits (links, bold, inline code) mixes text runs with small groups.
        let inline = n.children.contains { $0.role == "AXStaticText" }
        let parts = n.children.map(text(of:)).filter { !$0.isEmpty }
        let joined = inline ? parts.joined() : parts.joined(separator: "\n")
        return joined
    }

    /// The conversation's messages, oldest first.
    static func parse(_ root: Node, service: String) -> [ChatTurn] {
        var turns: [ChatTurn] = []

        func add(_ role: ChatTurn.Role, _ raw: String) {
            let t = tidy(raw)
            guard !t.isEmpty else { return }
            if let last = turns.last, last.role == role, role != .unknown {
                turns[turns.count - 1].text += "\n\n" + t
            } else {
                turns.append(ChatTurn(role: role, text: t))
            }
        }

        func walk(_ n: Node) {
            if let r = hint(n) {
                add(r, text(of: n))
                return
            }
            // ChatGPT and Claude: each turn is an article that starts with a hidden "You said:" heading.
            if n.subrole == "AXDocumentArticle" || n.role == "AXArticle" {
                let lines = text(of: n).components(separatedBy: "\n")
                let first = lines.first ?? ""
                if let (r, preview) = speakerPrefix(first), !n.children.contains(where: containsHint) {
                    // The heading may hold the whole message ("You said: build all of it") or just the label.
                    let rest = lines.dropFirst().joined(separator: "\n")
                    add(r, rest.nonEmpty ?? preview)
                    return
                }
            }
            // Skip the hidden speaker labels themselves.
            if n.role == "AXHeading" || n.role == "AXStaticText" {
                let t = n.text ?? text(of: n)
                if speakerLabel(t) != nil || n.role == "AXHeading" && speakerPrefix(t) != nil { return }
            }
            for c in n.children { walk(c) }
        }
        walk(root)

        // No message markers at all: fall back to "You said:" labels in the page text.
        if turns.isEmpty {
            var role: ChatTurn.Role = .unknown
            var buf: [String] = []
            var sawLabel = false
            func flush() { if !buf.isEmpty { add(role, buf.joined(separator: "\n")); buf = [] } }
            for line in text(of: root).components(separatedBy: "\n") {
                if let r = speakerLabel(line) { flush(); role = r; sawLabel = true; continue }
                if sawLabel { buf.append(line) }
            }
            flush()
        }
        // Still nothing recognisable (a native app, or a site that changed its page): keep the text as one
        // block, so at least nothing is lost.
        if turns.isEmpty, let all = tidy(text(of: root)).nonEmpty, all.count >= 40 {
            turns = [ChatTurn(role: .unknown, text: String(all.suffix(60_000)))]
        }
        return turns
    }

    private static func containsHint(_ n: Node) -> Bool {
        hint(n) != nil || n.children.contains { containsHint($0) }
    }

    static func tidy(_ s: String) -> String {
        var lines: [String] = []
        var blank = 0
        for l in s.components(separatedBy: "\n") {
            let t = l.replacingOccurrences(of: "\u{00A0}", with: " ").trimmingCharacters(in: .whitespaces)
            if t.isEmpty { blank += 1; if blank == 1, !lines.isEmpty { lines.append("") }; continue }
            blank = 0
            // Buttons that end up in the text ("Copy code", "Edit", "Retry").
            if ["copy", "copy code", "edit", "retry", "share", "regenerate", "good response", "bad response", "read aloud"].contains(t.lowercased()) { continue }
            lines.append(t)
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: Out of messages

    /// Banners free plans show when you run out ("You've hit the Free plan limit", "You're out of free
    /// messages until 4 PM"). Only short pieces of page text outside the messages count, so a chat
    /// *about* rate limits doesn't trigger it.
    static func limitNotice(in root: Node) -> String? {
        var found: String?
        func walk(_ n: Node) {
            // Messages, lists, quotes and code are content (a chat can talk about limits); banners aren't.
            guard found == nil, hint(n) == nil, n.subrole != "AXDocumentArticle", !isCode(n),
                  !["AXList", "AXTable", "AXOutline"].contains(n.role), n.subrole != "AXBlockquote" else { return }
            if n.role == "AXStaticText" || n.role == "AXHeading", let s = n.text, isLimitNotice(s) { found = s.singleLine; return }
            n.children.forEach(walk)
        }
        walk(root)
        return found
    }

    static func isLimitNotice(_ s: String) -> Bool {
        guard s.count <= 320 else { return false }
        let t = s.lowercased().replacingOccurrences(of: "’", with: "'")
        // A real banner talks to you or says when it resets ("You're out of free messages until 3 PM").
        // A bare heading like "Out of messages." is someone writing about limits, not a limit.
        let addressed = #"\b(you|you're|you've|you are|you have|your|until|resets?|upgrade|try again)\b"#
        guard t.range(of: addressed, options: .regularExpression) != nil else { return false }
        let patterns = [
            #"out of (free )?messages"#,
            #"(hit|reached) (the |your |our )?(free plan |free |daily |usage |message |current usage |weekly )?(limit|cap)"#,
            #"(usage|message) (limit|cap) (reached|for)"#,
            #"limit (will )?resets?( at| in| on)"#,
            #"you've used (all|up) (of )?your (free )?(messages|responses|chats)"#,
            #"upgrade (to (plus|pro|go|advanced))? ?to (keep|continue) (chatting|using)"#,
        ]
        return patterns.contains { t.range(of: $0, options: .regularExpression) != nil }
    }

    /// Cheap check for a limit banner on the front window of `pid` (a small, quick walk).
    static func limitNotice(pid: pid_t) -> String? {
        guard let root = snapshot(pid: pid, budget: 0.6, maxNodes: 6000, skipMessages: true) else { return nil }
        return limitNotice(in: root)
    }

    // MARK: Debugging on a real page

    /// `Shapr --probe-chat`: prints what Shapr reads from the frontmost AI chat, after 3 seconds
    /// (so you can switch to it).
    static func probe(wait: TimeInterval = 3, bundleID: String? = nil) -> String {
        var out: [String] = []
        let target: NSRunningApplication?
        if let bundleID {
            target = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
        } else {
            Thread.sleep(forTimeInterval: wait)
            target = NSWorkspace.shared.frontmostApplication
        }
        guard let app = target else { return "That app isn't running" }
        let started = Date()
        let info = pageInfo(pid: app.processIdentifier)
        out.append("App: \(app.localizedName ?? "?") (\(app.bundleIdentifier ?? "?")) · trusted: \(AXIsProcessTrusted())")
        out.append("Page: \(info.url ?? "no URL") · \(info.title ?? "no title")")
        guard let root = snapshot(pid: app.processIdentifier) else { out.append("Couldn't read the window"); return out.joined(separator: "\n") }
        var nodes = 0, classed = 0, articles = 0
        func count(_ n: Node) {
            nodes += 1
            if !n.classes.isEmpty { classed += 1 }
            if n.subrole == "AXDocumentArticle" { articles += 1 }
            n.children.forEach(count)
        }
        count(root)
        out.append("Read \(nodes) elements (\(classed) with class names, \(articles) articles) in \(Int(Date().timeIntervalSince(started) * 1000)) ms")
        let turns = parse(root, service: service(url: info.url, bundleID: app.bundleIdentifier) ?? "AI")
        out.append("\(turns.count) messages: \(turns.filter { $0.role == .user }.count) yours, \(turns.filter { $0.role == .assistant }.count) the AI's, \(turns.filter { $0.role == .unknown }.count) unknown")
        for t in turns.prefix(16) { out.append("[\(t.role.rawValue)] \(t.text.singleLine.truncated(160))") }
        if let n = limitNotice(in: root) { out.append("Limit notice: \(n)") }
        // Short label-like lines ("You said:"), to tune speaker detection.
        var labels: [String: Int] = [:]
        func findLabels(_ n: Node, _ path: String) {
            if n.role == "AXStaticText" || n.role == "AXHeading", let t = (n.text ?? text(of: n)).nonEmpty, t.count <= 40,
               t.lowercased().contains("said") || t.lowercased().contains("respond") || t.lowercased().hasPrefix("you") {
                labels[t + " [" + path + "]", default: 0] += 1
            }
            for c in n.children { findLabels(c, n.role.replacingOccurrences(of: "AX", with: "") + (n.subrole.map { "/" + $0 } ?? "") + (n.classes.isEmpty ? "" : "." + n.classes.prefix(3).joined(separator: "."))) }
        }
        findLabels(root, "")
        out.append("Label-like lines: " + labels.sorted { $0.value > $1.value }.prefix(12).map { "“\($0.key)”×\($0.value)" }.joined(separator: " "))
        // Which class names show up most, to tune the message markers.
        var freq: [String: Int] = [:]
        func classes(_ n: Node) { for c in n.classes { freq[c, default: 0] += 1 }; n.children.forEach(classes) }
        classes(root)
        out.append("Common classes: " + freq.sorted { $0.value > $1.value }.prefix(40).map { "\($0.key)×\($0.value)" }.joined(separator: " "))
        return out.joined(separator: "\n")
    }
}
