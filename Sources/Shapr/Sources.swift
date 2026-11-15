import AppKit
import CryptoKit
import os

let sourceLog = Logger(subsystem: "app.shapr.Shapr", category: "sources")

// MARK: - Model

/// Something that keeps a pack up to date by itself: a folder, a GitHub repo, a Notion page, a web page,
/// or a page or email thread that refreshes whenever you open it.
struct PackSource: Codable, Identifiable, Hashable {
    enum Kind: String, Codable, CaseIterable {
        /// A folder on this Mac, watched for changes.
        case folder
        /// "owner/repo": README, open issues and pull requests, recent commits.
        case github
        /// A Notion page, through your own Notion integration token.
        case notion
        /// A public web page, fetched every hour.
        case web
        /// A page that needs your login (Gmail, Google Docs…): read from the screen whenever you open it.
        case page
        /// An Apple Mail thread (by subject): new messages are added when you open them.
        case mail
    }

    var id = UUID()
    var kind: Kind
    /// Folder path, "owner/repo", page URL, or the thread's subject.
    var location: String
    var title: String
    var added = Date()
    /// Last time Shapr checked it successfully (or read it, for pages and threads).
    var lastChecked: Date?
    /// Last time something in it changed.
    var lastChanged: Date?
    var lastError: String?
    var itemCount = 0

    var symbol: String {
        switch kind {
        case .folder: return "folder"
        case .github: return "chevron.left.forwardslash.chevron.right"
        case .notion: return "doc.richtext"
        case .web: return "globe"
        case .page: return "macwindow"
        case .mail: return "envelope"
        }
    }

    var kindTitle: String {
        switch kind {
        case .folder: return "Folder"
        case .github: return "GitHub repo"
        case .notion: return "Notion page"
        case .web: return "Web page"
        case .page: return "Page you open"
        case .mail: return "Mail thread"
        }
    }

    /// Pages that need your login and Mail threads only update when you open them.
    var updatesWhenOpen: Bool { kind == .page || kind == .mail }

    /// "Updated 4 min ago", or a warning when it failed or hasn't been seen for a while.
    func status(now: Date = Date()) -> (text: String, stale: Bool) {
        let rel = { (d: Date) in d.formatted(.relative(presentation: .named, unitsStyle: .abbreviated)) }
        if let e = lastError { return ("Couldn't update: \(e)", true) }
        guard let checked = lastChecked else {
            return (updatesWhenOpen ? "Updates when you open it" : "Not updated yet", updatesWhenOpen ? false : true)
        }
        let age = now.timeIntervalSince(checked)
        if updatesWhenOpen {
            return age > 7 * 86_400 ? ("Not opened since \(rel(checked)), may be out of date", true)
                                    : ("Read \(rel(checked)) · updates when you open it", false)
        }
        let limit: TimeInterval = kind == .folder ? 86_400 : 3 * 3600
        return age > limit ? ("Last updated \(rel(checked))", true) : ("Updated \(rel(checked))", false)
    }

    /// What kind of source a link is: a repo, a Notion page, a page that needs your login, or a public page.
    static func from(link raw: String) -> PackSource? {
        let s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("/") || s.hasPrefix("~") {
            let path = (s as NSString).expandingTildeInPath
            var dir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &dir), dir.boolValue else { return nil }
            return PackSource(kind: .folder, location: path, title: (path as NSString).lastPathComponent)
        }
        guard let u = URL(string: s.hasPrefix("http") ? s : "https://" + s), let host = u.host?.lowercased(), host.contains(".") else { return nil }
        if let repo = GitHubSource.repo(from: u) {
            return PackSource(kind: .github, location: repo, title: repo)
        }
        if host.hasSuffix("notion.so") || host.hasSuffix("notion.site") {
            guard NotionSource.pageID(from: u.absoluteString) != nil else { return nil }
            return PackSource(kind: .notion, location: u.absoluteString, title: "Notion page")
        }
        let title = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return PackSource(kind: needsLogin(host) ? .page : .web, location: u.absoluteString,
                          title: host == "mail.google.com" ? "Gmail thread" : title)
    }

    /// Sites that show a login page to anyone but you, so Shapr reads them from your screen instead.
    static func needsLogin(_ host: String) -> Bool {
        let h = host.lowercased()
        let exact = ["mail.google.com", "docs.google.com", "drive.google.com", "calendar.google.com", "outlook.live.com",
                     "outlook.office.com", "outlook.office365.com", "app.slack.com", "linear.app", "app.asana.com",
                     "teams.microsoft.com", "web.whatsapp.com", "mail.yahoo.com", "app.hubspot.com", "figma.com", "www.figma.com",
                     "canvas.instructure.com", "classroom.google.com", "onedrive.live.com"]
        return exact.contains(h) || h.hasSuffix(".atlassian.net") || h.hasSuffix(".sharepoint.com")
            || h.hasSuffix(".instructure.com") || h.hasSuffix(".slack.com") || h.hasSuffix(".zendesk.com")
    }
}

/// One item from a source, ready to save.
struct SourceItem {
    let key: String
    let rev: String
    let draft: CaptureDraft
}

/// What a check found: the items that changed, and every item that still exists (nil = unknown, keep all).
struct SourceScan {
    var changed: [SourceItem] = []
    var present: Set<String>?
    var title: String?
}

struct SourceError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

enum SourceHash {
    static func of(_ s: String) -> String {
        SHA256.hash(data: Data(s.utf8)).prefix(10).map { String(format: "%02x", $0) }.joined()
    }
}

enum SourceHTTP {
    static func get(_ url: URL, headers: [String: String] = [:], timeout: TimeInterval = 20) async throws -> (Data, Int) {
        var req = URLRequest(url: url, timeoutInterval: timeout)
        let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
        req.setValue("Shapr/\(version) (Mac)", forHTTPHeaderField: "User-Agent")
        for (k, v) in headers { req.setValue(v, forHTTPHeaderField: k) }
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            return (data, (resp as? HTTPURLResponse)?.statusCode ?? 0)
        } catch let e as URLError where e.code == .notConnectedToInternet || e.code == .networkConnectionLost {
            throw SourceError("You're offline")
        } catch let e as URLError where e.code == .timedOut {
            throw SourceError("It took too long to answer")
        }
    }
}

// MARK: - Folder

enum FolderSource {
    static let skipDirs: Set<String> = ["node_modules", ".git", "build", "dist", "DerivedData", "Pods", ".build", "venv",
                                        ".venv", "__pycache__", "target", ".next", "out", "vendor", ".cache"]
    static let maxFiles = 300

    /// Reads the files that changed since `known` (relative path → "mtime-size").
    static func scan(path: String, known: [String: String]) async throws -> SourceScan {
        let root = URL(fileURLWithPath: path, isDirectory: true)
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            throw SourceError("The folder was moved or deleted")
        }
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey, .isRegularFileKey]
        guard let en = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys,
                                                      options: [.skipsHiddenFiles, .skipsPackageDescendants]) else {
            throw SourceError("Shapr can't open the folder")
        }
        var files: [(url: URL, rel: String, mod: Date, size: Int)] = []
        let allowed = FileTypes.text.union(FileTypes.documents)
        let base = root.standardizedFileURL.path
        while let url = en.nextObject() as? URL {
            let v = try? url.resourceValues(forKeys: Set(keys))
            if v?.isDirectory == true {
                if skipDirs.contains(url.lastPathComponent) || en.level > 4 { en.skipDescendants() }
                continue
            }
            guard v?.isRegularFile == true, allowed.contains(url.pathExtension.lowercased()) else { continue }
            let size = v?.fileSize ?? 0
            let docLimit = FileTypes.documents.contains(url.pathExtension.lowercased()) ? 30_000_000 : 2_000_000
            guard size > 0, size <= docLimit else { continue }
            var rel = url.standardizedFileURL.path
            if rel.hasPrefix(base + "/") { rel.removeFirst(base.count + 1) }
            files.append((url, rel, v?.contentModificationDate ?? Date(), size))
        }
        files.sort { $0.mod > $1.mod }
        files = Array(files.prefix(maxFiles))
        var scan = SourceScan(present: Set(files.map(\.rel)), title: root.lastPathComponent)
        for f in files {
            let rev = "\(Int(f.mod.timeIntervalSince1970))-\(f.size)"
            guard known[f.rel] != rev else { continue }
            let text = await FileText.extract(f.url)
            scan.changed.append(SourceItem(key: f.rel, rev: rev, draft: CaptureDraft(
                text: text.nonEmpty ?? "File: \(f.rel)", capturedAt: f.mod, appName: "Folder",
                title: f.rel, url: f.url.absoluteString)))
        }
        return scan
    }
}

// MARK: - GitHub

enum GitHubSource {
    /// "https://github.com/acme/app/issues/4" → "acme/app".
    static func repo(from u: URL) -> String? {
        guard u.host?.lowercased() == "github.com" else { return nil }
        let parts = u.path.split(separator: "/").map(String.init)
        let reserved: Set<String> = ["orgs", "settings", "notifications", "search", "marketplace", "explore", "topics", "login", "new"]
        guard parts.count >= 2, !reserved.contains(parts[0].lowercased()) else { return nil }
        let name = parts[1].hasSuffix(".git") ? String(parts[1].dropLast(4)) : parts[1]
        return "\(parts[0])/\(name)"
    }

    static func scan(repo: String, token: String?, known: [String: String]) async throws -> SourceScan {
        let api = "https://api.github.com/repos/\(repo)"
        var headers = ["Accept": "application/vnd.github+json", "X-GitHub-Api-Version": "2022-11-28"]
        if let token { headers["Authorization"] = "Bearer \(token)" }
        func json(_ path: String) async throws -> Any? {
            guard let url = URL(string: api + path) else { return nil }
            let (data, status) = try await SourceHTTP.get(url, headers: headers)
            switch status {
            case 200: return try JSONSerialization.jsonObject(with: data)
            case 404: return nil
            case 401: throw SourceError("GitHub refused the token. Check it in Settings → Connections")
            case 403, 429:
                throw SourceError(token == nil ? "GitHub's hourly limit for apps without a token was reached. Add a token in Settings → Connections, or wait an hour"
                                               : "GitHub's rate limit was reached; Shapr tries again later")
            default: throw SourceError("GitHub answered with error \(status)")
            }
        }
        guard let info = try await json("") as? [String: Any] else {
            throw SourceError(token == nil ? "Repo not found. If it's private, add a GitHub token in Settings → Connections" : "Repo not found")
        }
        var readme: String?
        if let url = URL(string: api + "/readme") {
            var h = headers
            h["Accept"] = "application/vnd.github.raw+json"
            let (data, status) = try await SourceHTTP.get(url, headers: h)
            if status == 200 { readme = String(data: data, encoding: .utf8) }
        }
        let issues = try await json("/issues?state=open&per_page=30&sort=updated") as? [[String: Any]] ?? []
        let commits = try await json("/commits?per_page=15") as? [[String: Any]] ?? []
        var scan = SourceScan()
        let items = self.items(repo: repo, info: info, readme: readme, issues: issues, commits: commits)
        scan.present = Set(items.map(\.key))
        scan.changed = items.filter { known[$0.key] != $0.rev }
        scan.title = info["full_name"] as? String ?? repo
        return scan
    }

    /// The repo's README (with its description), each open issue and pull request, and recent commits.
    static func items(repo: String, info: [String: Any], readme: String?, issues: [[String: Any]], commits: [[String: Any]]) -> [SourceItem] {
        let name = info["full_name"] as? String ?? repo
        let page = info["html_url"] as? String ?? "https://github.com/\(repo)"
        var out: [SourceItem] = []
        var about = ""
        if let d = (info["description"] as? String)?.nonEmpty { about += d + "\n\n" }
        if let topics = info["topics"] as? [String], !topics.isEmpty { about += "Topics: " + topics.joined(separator: ", ") + "\n\n" }
        let readmeText = String((readme ?? "").prefix(60_000))
        if !(about + readmeText).trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            let text = about + readmeText
            out.append(SourceItem(key: "readme", rev: SourceHash.of(text), draft: CaptureDraft(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines), appName: "GitHub", title: "\(name) README", url: page)))
        }
        for i in issues {
            guard let n = i["number"] as? Int, let title = i["title"] as? String else { continue }
            let isPR = i["pull_request"] != nil
            var text = (isPR ? "Pull request" : "Issue") + " #\(n): \(title)\n"
            var meta: [String] = ["open"]
            if let u = (i["user"] as? [String: Any])?["login"] as? String { meta.append("by \(u)") }
            let labels = (i["labels"] as? [[String: Any]] ?? []).compactMap { $0["name"] as? String }
            if !labels.isEmpty { meta.append("labels: " + labels.joined(separator: ", ")) }
            if let c = i["comments"] as? Int, c > 0 { meta.append("\(c) comment\(c == 1 ? "" : "s")") }
            text += meta.joined(separator: " · ") + "\n\n"
            text += String(((i["body"] as? String) ?? "").prefix(8000))
            let updated = (i["updated_at"] as? String) ?? SourceHash.of(text)
            out.append(SourceItem(key: "issue-\(n)", rev: updated, draft: CaptureDraft(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                capturedAt: (i["updated_at"] as? String).flatMap(CaptureFile.date) ?? Date(),
                appName: "GitHub", title: (isPR ? "PR" : "Issue") + " #\(n) · \(title)", url: i["html_url"] as? String)))
        }
        let lines: [String] = commits.compactMap { c in
            guard let sha = c["sha"] as? String, let commit = c["commit"] as? [String: Any],
                  let msg = (commit["message"] as? String)?.firstLine else { return nil }
            let author = ((commit["author"] as? [String: Any])?["name"] as? String) ?? ""
            let date = (((commit["author"] as? [String: Any])?["date"] as? String) ?? "").prefix(10)
            return "- \(sha.prefix(7)) \(msg) (\(author), \(date))"
        }
        if let first = commits.first?["sha"] as? String, !lines.isEmpty {
            out.append(SourceItem(key: "commits", rev: first, draft: CaptureDraft(
                text: "Recent commits on the default branch:\n" + lines.joined(separator: "\n"),
                appName: "GitHub", title: "Recent commits in \(name)", url: page + "/commits")))
        }
        return out
    }
}

// MARK: - Notion

enum NotionSource {
    static let version = "2022-06-28"

    /// The page ID at the end of a Notion link, as a UUID string.
    static func pageID(from link: String) -> String? {
        let tail = link.split(separator: "?").first.map(String.init) ?? link
        let candidates = tail.replacingOccurrences(of: "-", with: "").lowercased()
        guard let r = candidates.range(of: #"[0-9a-f]{32}(?=[^0-9a-f]*$)"#, options: .regularExpression) else { return nil }
        let h = Array(candidates[r])
        let parts = [h[0..<8], h[8..<12], h[12..<16], h[16..<20], h[20..<32]].map { String($0) }
        return parts.joined(separator: "-")
    }

    static func scan(link: String, token: String?, knownRev: String?) async throws -> SourceScan {
        guard let id = pageID(from: link) else { throw SourceError("That isn't a Notion page link") }
        guard let token else {
            throw SourceError("Add a Notion token in Settings → Connections")
        }
        let headers = ["Authorization": "Bearer \(token)", "Notion-Version": version]
        func get(_ path: String) async throws -> [String: Any] {
            let (data, status) = try await SourceHTTP.get(URL(string: "https://api.notion.com/v1/" + path)!, headers: headers)
            switch status {
            case 200: return (try JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]
            case 401: throw SourceError("Notion refused the token. Check it in Settings → Connections")
            case 403, 404: throw SourceError("Notion won't share this page yet. In Notion, open the page's ••• menu → Connections and add your Shapr integration")
            case 429: throw SourceError("Notion asked Shapr to slow down; it tries again later")
            default: throw SourceError("Notion answered with error \(status)")
            }
        }
        let page = try await get("pages/\(id)")
        let edited = page["last_edited_time"] as? String ?? ""
        let title = self.title(of: page) ?? "Notion page"
        if !edited.isEmpty, edited == knownRev { return SourceScan(changed: [], present: ["page"], title: title) }

        var total = 0
        func children(_ blockID: String, depth: Int) async throws -> [String] {
            var lines: [String] = []
            var cursor: String?
            repeat {
                let q = "blocks/\(blockID)/children?page_size=100" + (cursor.map { "&start_cursor=\($0)" } ?? "")
                let res = try await get(q)
                for b in res["results"] as? [[String: Any]] ?? [] {
                    total += 1
                    if let l = line(b, depth: depth) { lines.append(l) }
                    let type = b["type"] as? String ?? ""
                    if b["has_children"] as? Bool == true, depth < 3, total < 600,
                       !["child_page", "child_database"].contains(type), let cid = b["id"] as? String {
                        lines += try await children(cid, depth: depth + 1)
                    }
                }
                cursor = res["has_more"] as? Bool == true ? res["next_cursor"] as? String : nil
            } while cursor != nil && total < 600
            return lines
        }
        let body = try await children(id, depth: 0).joined(separator: "\n")
        let text = ("# " + title + "\n\n" + body).trimmingCharacters(in: .whitespacesAndNewlines)
        let item = SourceItem(key: "page", rev: edited.nonEmpty ?? SourceHash.of(text), draft: CaptureDraft(
            text: String(text.prefix(200_000)), capturedAt: CaptureFile.date(edited) ?? Date(), appName: "Notion",
            title: title, url: page["url"] as? String ?? link))
        return SourceScan(changed: [item], present: ["page"], title: title)
    }

    static func title(of page: [String: Any]) -> String? {
        for (_, v) in page["properties"] as? [String: Any] ?? [:] {
            guard let p = v as? [String: Any], p["type"] as? String == "title" else { continue }
            return richText(p["title"]).nonEmpty
        }
        return nil
    }

    static func richText(_ any: Any?) -> String {
        (any as? [[String: Any]] ?? []).compactMap { $0["plain_text"] as? String }.joined()
    }

    /// One Notion block as a line of Markdown.
    static func line(_ b: [String: Any], depth: Int) -> String? {
        let type = b["type"] as? String ?? ""
        let d = b[type] as? [String: Any] ?? [:]
        let t = richText(d["rich_text"])
        let indent = String(repeating: "  ", count: depth)
        switch type {
        case "paragraph": return t.isEmpty ? "" : indent + t
        case "heading_1": return "\n# " + t
        case "heading_2": return "\n## " + t
        case "heading_3": return "\n### " + t
        case "bulleted_list_item", "toggle": return indent + "- " + t
        case "numbered_list_item": return indent + "1. " + t
        case "to_do": return indent + (d["checked"] as? Bool == true ? "- [x] " : "- [ ] ") + t
        case "quote": return "> " + t
        case "callout":
            let icon = (d["icon"] as? [String: Any])?["emoji"] as? String
            return "> " + [icon, t].compactMap { $0 }.joined(separator: " ")
        case "code": return "```" + (d["language"] as? String ?? "") + "\n" + t + "\n```"
        case "divider": return "---"
        case "equation": return d["expression"] as? String
        case "child_page": return "Page: " + (d["title"] as? String ?? "")
        case "child_database": return "Database: " + (d["title"] as? String ?? "")
        case "bookmark", "embed", "link_preview": return (d["url"] as? String).map { indent + $0 }
        case "table_row": return "| " + (d["cells"] as? [Any] ?? []).map { richText($0) }.joined(separator: " | ") + " |"
        case "image", "file", "pdf", "video", "audio":
            let cap = richText(d["caption"])
            return "[\(type)" + (cap.isEmpty ? "" : ": \(cap)") + "]"
        default: return t.nonEmpty.map { indent + $0 }
        }
    }
}

// MARK: - Public web pages

enum WebSource {
    static func scan(link: String, knownRev: String?) async throws -> SourceScan {
        guard let url = URL(string: link) else { throw SourceError("That isn't a web address") }
        let (data, status) = try await SourceHTTP.get(url, headers: ["Accept": "text/html,text/plain;q=0.9,*/*;q=0.5"])
        guard status == 200 else {
            throw SourceError(status == 401 || status == 403 ? "The page needs you to sign in. Open it in your browser to update it" : "The site answered with error \(status)")
        }
        let raw = String(data: data, encoding: .utf8) ?? String(decoding: data, as: UTF8.self)
        let isHTML = raw.range(of: "<html", options: .caseInsensitive) != nil || raw.range(of: "<body", options: .caseInsensitive) != nil
        let text = isHTML ? HTMLText.text(raw) : raw
        let title = isHTML ? HTMLText.title(raw) : nil
        guard text.count >= 40 else { throw SourceError("The page had no readable text") }
        if HTMLText.looksLikeLogin(text) { throw SourceError("The page needs you to sign in. Open it in your browser to update it") }
        let rev = SourceHash.of(text)
        guard rev != knownRev else { return SourceScan(present: ["page"], title: title) }
        return SourceScan(changed: [SourceItem(key: "page", rev: rev, draft: CaptureDraft(
            text: String(text.prefix(200_000)), appName: "Web", title: title ?? url.host, url: link))],
                          present: ["page"], title: title)
    }
}

/// Readable text from HTML: the main content when the page marks it, without scripts, menus or markup.
enum HTMLText {
    static func title(_ html: String) -> String? {
        guard let r = html.range(of: #"(?is)<title[^>]*>(.*?)</title>"#, options: .regularExpression) else { return nil }
        let inner = html[r].replacingOccurrences(of: #"(?is)</?title[^>]*>"#, with: "", options: .regularExpression)
        return decode(inner).singleLine.nonEmpty
    }

    static func text(_ html: String) -> String {
        var s = html
        for tag in ["head", "script", "style", "noscript", "svg", "template", "iframe"] {
            s = s.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?s)<!--.*?-->"#, with: " ", options: .regularExpression)
        var found = false
        for tag in ["main", "article"] {
            if let r = s.range(of: "(?is)<\(tag)\\b.*?</\(tag)>", options: .regularExpression), s[r].count > 400 {
                s = String(s[r])
                found = true
                break
            }
        }
        // Docs sites mark the content with role="main" on a div: start there.
        if !found, let r = s.range(of: #"(?i)<\w+[^>]*\brole=["']main["']"#, options: .regularExpression) {
            s = String(s[r.lowerBound...])
        }
        for tag in ["nav", "footer", "aside", "form"] {
            s = s.replacingOccurrences(of: "(?is)<\(tag)\\b.*?</\(tag)>", with: " ", options: .regularExpression)
        }
        s = s.replacingOccurrences(of: #"(?i)<li\b[^>]*>"#, with: "\n- ", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<h([1-6])\b[^>]*>"#, with: "\n\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)<(br|/p|/div|/h[1-6]|/tr|/section|/blockquote|/pre|/table)\b[^>]*>"#, with: "\n", options: .regularExpression)
        s = s.replacingOccurrences(of: #"(?i)</t[dh]>"#, with: " | ", options: .regularExpression)
        // Inline tags (bold, links…) vanish without a gap; anything else becomes a space.
        s = s.replacingOccurrences(of: #"(?i)</?(a|b|i|em|strong|span|code|small|sup|sub|u|mark|abbr|time|label)\b[^>]*>"#, with: "", options: .regularExpression)
        s = s.replacingOccurrences(of: #"<[^>]+>"#, with: " ", options: .regularExpression)
        s = decode(s)
        let lines = s.split(separator: "\n", omittingEmptySubsequences: false).map {
            $0.replacingOccurrences(of: #"[ \t\x{00A0}]+"#, with: " ", options: .regularExpression).trimmingCharacters(in: .whitespaces)
        }
        var out: [String] = []
        for l in lines {
            if l.isEmpty || l == "-" { if out.last?.isEmpty == false { out.append("") } } else { out.append(l) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func decode(_ s: String) -> String {
        var out = s
        let named = ["&nbsp;": " ", "&amp;": "&", "&lt;": "<", "&gt;": ">", "&quot;": "\"", "&#39;": "'", "&apos;": "'",
                     "&mdash;": "—", "&ndash;": "–", "&hellip;": "…", "&rsquo;": "’", "&lsquo;": "‘", "&rdquo;": "”", "&ldquo;": "“"]
        for (k, v) in named { out = out.replacingOccurrences(of: k, with: v) }
        guard out.contains("&#") else { return out }
        let re = try! NSRegularExpression(pattern: #"&#(x?)([0-9a-fA-F]+);"#)
        var result = ""
        var last = out.startIndex
        for m in re.matches(in: out, range: NSRange(out.startIndex..., in: out)) {
            guard let r = Range(m.range, in: out), let hex = Range(m.range(at: 1), in: out), let num = Range(m.range(at: 2), in: out) else { continue }
            result += out[last..<r.lowerBound]
            let value = UInt32(out[num], radix: out[hex].isEmpty ? 10 : 16)
            if let v = value, let u = Unicode.Scalar(v) { result.unicodeScalars.append(u) }
            last = r.upperBound
        }
        result += out[last...]
        return result
    }

    static func looksLikeLogin(_ text: String) -> Bool {
        text.count < 1500 && text.range(of: #"(?i)\b(sign in|log in|login)\b"#, options: .regularExpression) != nil
            && text.range(of: #"(?i)\b(password|email|continue with)\b"#, options: .regularExpression) != nil
    }
}

// MARK: - Pages and threads you open

enum PageText {
    /// The readable text of the page in front: its main content when the page marks one.
    static func read(pid: pid_t) -> (url: String?, title: String?, text: String)? {
        let info = ChatReader.pageInfo(pid: pid)
        guard let root = ChatReader.snapshot(pid: pid, budget: 2.0, maxNodes: 25_000) else { return nil }
        let main = findMain(root) ?? root
        let text = tidy(ChatReader.text(of: main))
        return (info.url, info.title, text)
    }

    static func findMain(_ root: ChatReader.Node) -> ChatReader.Node? {
        var queue = [root]
        var i = 0
        while i < queue.count {
            let n = queue[i]
            i += 1
            if n.subrole == "AXLandmarkMain" { return n }
            queue.append(contentsOf: n.children)
        }
        return nil
    }

    static func tidy(_ s: String) -> String {
        var out: [String] = []
        for raw in s.split(separator: "\n", omittingEmptySubsequences: false) {
            let l = raw.trimmingCharacters(in: .whitespaces)
            if l.isEmpty { if out.last?.isEmpty == false { out.append("") } } else if out.last != l { out.append(l) }
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Two addresses for the same page or thread. Gmail threads match on the thread ID, whichever
    /// label or search you opened them from.
    static func samePage(_ a: String, _ b: String) -> Bool {
        if let ga = gmailThread(a), let gb = gmailThread(b) { return ga == gb }
        guard let na = PackRouter.normalizedURL(a), let nb = PackRouter.normalizedURL(b) else { return false }
        return na == nb
    }

    static func gmailThread(_ url: String) -> String? {
        guard let u = URL(string: url), u.host == "mail.google.com", let f = u.fragment else { return nil }
        guard let last = f.split(separator: "/").last.map(String.init), last.count >= 16, last.allSatisfy({ $0.isLetter || $0.isNumber }) else { return nil }
        return last
    }
}

enum MailThread {
    /// "Re: Fwd: Q3 plan" → "q3 plan".
    static func normalize(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespaces)
        while let r = s.range(of: #"^(?i)(re|fw|fwd|aw|wg|sv|vs)\s*(\[\d+\])?\s*:\s*"#, options: .regularExpression) {
            s.removeSubrange(r)
        }
        return s.lowercased().split(whereSeparator: \.isWhitespace).joined(separator: " ")
    }

    struct Message { let id: String; let subject: String; let sender: String; let date: Date?; let content: String }

    /// The message selected in Apple Mail: just its ID and subject (fast).
    @MainActor
    static func selectedHeader() -> (id: String, subject: String)? {
        let script = """
        tell application id "com.apple.mail"
          set s to selection
          if (count of s) = 0 then return {}
          set m to item 1 of s
          return {message id of m, subject of m}
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err), out.numberOfItems >= 2,
              let id = out.atIndex(1)?.stringValue, let subject = out.atIndex(2)?.stringValue else { return nil }
        return (id, subject)
    }

    /// The whole selected message.
    @MainActor
    static func selectedMessage() -> Message? {
        let script = """
        tell application id "com.apple.mail"
          set s to selection
          if (count of s) = 0 then return {}
          set m to item 1 of s
          return {message id of m, subject of m, sender of m, ((date received of m) as «class isot» as string), content of m}
        end tell
        """
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err), out.numberOfItems >= 5,
              let id = out.atIndex(1)?.stringValue else { return nil }
        let iso = DateFormatter()
        iso.locale = Locale(identifier: "en_US_POSIX")
        iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
        return Message(id: id, subject: out.atIndex(2)?.stringValue ?? "", sender: out.atIndex(3)?.stringValue ?? "",
                       date: out.atIndex(4)?.stringValue.flatMap(iso.date(from:)),
                       content: String((out.atIndex(5)?.stringValue ?? "").prefix(40_000)))
    }
}

// MARK: - Keeping them up to date

/// Checks every pack's sources: folders when they change, repos, Notion and web pages every half hour,
/// and pages or Mail threads whenever you have them open.
@MainActor
final class SourceSync: ObservableObject {
    private let store: PackStore
    @Published private(set) var syncing: Set<UUID> = []
    private var timer: Timer?
    private var pageTimer: Timer?
    private var folderWatchers: [UUID: PackWatcher] = [:]
    private var folderPending: Set<UUID> = []
    private var lastRead: [UUID: Date] = [:]
    private var frontSince: (key: String, at: Date)?

    static let githubAccount = "github-token"
    static let notionAccount = "notion-token"

    init(store: PackStore) { self.store = store }

    func start() {
        DispatchQueue.main.asyncAfter(deadline: .now() + 6) { [weak self] in self?.syncAll() }
        timer = Timer.scheduledTimer(withTimeInterval: 30 * 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncAll(remoteOnly: true) }
        }
        pageTimer = Timer.scheduledTimer(withTimeInterval: 4, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkOpenPage() }
        }
        refreshWatchers()
    }

    // MARK: Adding

    /// Links a source to a pack and reads it right away.
    @discardableResult
    func add(_ source: PackSource, to packID: UUID) -> PackSource {
        var all = store.sources(for: packID)
        if let same = all.first(where: { $0.kind == source.kind && $0.location == source.location }) {
            sync(same.id, in: packID)
            return same
        }
        all.append(source)
        store.saveSources(all, for: packID)
        refreshWatchers()
        if source.updatesWhenOpen {
            checkOpenPage(force: source.id)
        } else {
            sync(source.id, in: packID)
        }
        return source
    }

    func remove(_ sourceID: UUID, from packID: UUID, removeItems: Bool) {
        store.removeSource(sourceID, from: packID, removeItems: removeItems)
        folderWatchers[sourceID] = nil
    }

    func syncAll(remoteOnly: Bool = false) {
        for (pid, s) in store.allSources() where !s.updatesWhenOpen && (!remoteOnly || s.kind != .folder) {
            sync(s.id, in: pid)
        }
    }

    /// Checks one source now ("Update now", a folder change, the half-hourly timer).
    func sync(_ sourceID: UUID, in packID: UUID) {
        guard !syncing.contains(sourceID), let initial = store.sources(for: packID).first(where: { $0.id == sourceID }) else { return }
        if initial.updatesWhenOpen { checkOpenPage(force: sourceID); return }
        syncing.insert(sourceID)
        let known = knownRevs(sourceID, in: packID)
        let github = Keychain.get(Self.githubAccount)
        let notion = Keychain.get(Self.notionAccount)
        Task {
            defer { syncing.remove(sourceID) }
            var src = initial
            do {
                let scan: SourceScan
                switch src.kind {
                case .folder: scan = try await FolderSource.scan(path: src.location, known: known)
                case .github: scan = try await GitHubSource.scan(repo: src.location, token: github, known: known)
                case .notion: scan = try await NotionSource.scan(link: src.location, token: notion, knownRev: known["page"])
                case .web: scan = try await WebSource.scan(link: src.location, knownRev: known["page"])
                case .page, .mail: return
                }
                let changed = apply(scan, source: &src, packID: packID)
                sourceLog.notice("synced \(src.kind.rawValue, privacy: .public) source: \(changed) change(s)")
            } catch {
                src.lastError = (error as? SourceError)?.message ?? error.localizedDescription
                sourceLog.error("source sync failed: \(src.lastError ?? "", privacy: .public)")
            }
            // Re-read in case it was renamed or removed while checking.
            guard store.sources(for: packID).contains(where: { $0.id == sourceID }) else { return }
            store.updateSource(src, in: packID)
        }
    }

    /// Saves what changed and records the check. Returns how many captures changed.
    @discardableResult
    private func apply(_ scan: SourceScan, source src: inout PackSource, packID: UUID) -> Int {
        var n = 0
        for item in scan.changed where store.upsertSourceItem(packID: packID, sourceID: src.id, key: item.key, rev: item.rev, draft: item.draft) != .unchanged {
            n += 1
        }
        if let present = scan.present { n += store.removeSourceItems(packID: packID, sourceID: src.id, keep: present) }
        src.lastChecked = Date()
        src.lastError = nil
        if n > 0 { src.lastChanged = Date() }
        if let t = scan.title?.nonEmpty, src.kind != .mail { src.title = t }
        src.itemCount = store.pack(packID)?.captures.filter { $0.sourceID == src.id.uuidString }.count ?? 0
        return n
    }

    private func knownRevs(_ sourceID: UUID, in packID: UUID) -> [String: String] {
        let sid = sourceID.uuidString
        var out: [String: String] = [:]
        for c in store.pack(packID)?.captures ?? [] where c.sourceID == sid {
            if let k = c.sourceKey, let r = c.sourceRev { out[k] = r }
        }
        return out
    }

    // MARK: Folders

    private func refreshWatchers() {
        let folders = store.allSources().filter { $0.source.kind == .folder }
        let ids = Set(folders.map(\.source.id))
        for id in folderWatchers.keys where !ids.contains(id) { folderWatchers[id] = nil }
        for (pid, s) in folders where folderWatchers[s.id] == nil {
            folderWatchers[s.id] = PackWatcher(path: s.location) { [weak self] in
                MainActor.assumeIsolated { self?.folderChanged(s.id, packID: pid) }
            }
        }
    }

    /// Waits for a burst of saves to settle before reading the folder again.
    private func folderChanged(_ id: UUID, packID: UUID) {
        guard !folderPending.contains(id) else { return }
        folderPending.insert(id)
        DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
            self?.folderPending.remove(id)
            self?.sync(id, in: packID)
        }
    }

    // MARK: Pages and threads you open

    /// When a linked page or Mail thread is in front, reads it (at most once a minute, after it's been
    /// in front for a few seconds so it has loaded).
    func checkOpenPage(force: UUID? = nil) {
        guard let app = NSWorkspace.shared.frontmostApplication, let bid = app.bundleIdentifier else { return }
        let open = store.allSources().filter { $0.source.updatesWhenOpen }
        guard !open.isEmpty else { return }
        if bid == "com.apple.mail" {
            checkMail(open.filter { $0.source.kind == .mail }, force: force)
        } else if ChatReader.browserIDs.contains(bid) || CaptureService.isBrowser(bid) {
            checkBrowser(app, open.filter { $0.source.kind == .page }, force: force)
        }
    }

    private func due(_ id: UUID, force: UUID?) -> Bool {
        force == id || Date().timeIntervalSince(lastRead[id] ?? .distantPast) > 60
    }

    private func checkBrowser(_ app: NSRunningApplication, _ pages: [(packID: UUID, source: PackSource)], force: UUID?) {
        guard !pages.isEmpty, CaptureService.isTrusted else { return }
        let pid = app.processIdentifier
        Task {
            let info = await Task.detached { ChatReader.pageInfo(pid: pid) }.value
            guard let url = info.url else { return }
            let matches = pages.filter { PageText.samePage($0.source.location, url) && due($0.source.id, force: force) }
            guard !matches.isEmpty else { frontSince = nil; return }
            // Give a page you just opened a moment to load.
            if force == nil {
                if frontSince?.key != url { frontSince = (url, Date()); return }
                guard Date().timeIntervalSince(frontSince!.at) >= 3 else { return }
            }
            for m in matches { lastRead[m.source.id] = Date() }
            guard let page = await Task.detached(operation: { PageText.read(pid: pid) }).value, page.text.count >= 40 else { return }
            for (packID, s) in matches {
                var src = s
                let draft = CaptureDraft(text: String(page.text.prefix(200_000)), appName: app.localizedName,
                                         bundleID: app.bundleIdentifier, title: page.title?.nonEmpty ?? src.title, url: src.location)
                let scan = SourceScan(changed: [SourceItem(key: "page", rev: SourceHash.of(page.text), draft: draft)], present: ["page"],
                                      title: src.title == "Gmail thread" || src.title.contains(".") ? page.title?.nonEmpty.map { cleanTitle($0) } : nil)
                apply(scan, source: &src, packID: packID)
                store.updateSource(src, in: packID)
            }
        }
    }

    private func cleanTitle(_ t: String) -> String {
        t.replacingOccurrences(of: #"\s+[-–|]\s+[^-–|]*(Gmail|Mail|Outlook|Google Docs)[^-–|]*$"#, with: "", options: .regularExpression)
            .truncated(80)
    }

    private func checkMail(_ threads: [(packID: UUID, source: PackSource)], force: UUID?) {
        guard !threads.isEmpty, let head = MailThread.selectedHeader() else { return }
        let subject = MailThread.normalize(head.subject)
        let matches = threads.filter { MailThread.normalize($0.source.location) == subject }
        guard !matches.isEmpty else { return }
        for (packID, s) in matches {
            let have = store.pack(packID)?.captures.contains { $0.sourceID == s.id.uuidString && $0.sourceKey == head.id } ?? false
            guard !have || force == s.id, let m = MailThread.selectedMessage() else {
                var src = s
                src.lastChecked = Date()
                src.lastError = nil
                store.updateSource(src, in: packID)
                continue
            }
            var src = s
            let text = "From: \(m.sender)\n" + (m.date.map { "Date: \($0.formatted(date: .abbreviated, time: .shortened))\n" } ?? "") + "\n" + m.content
            let draft = CaptureDraft(text: text, capturedAt: m.date ?? Date(), appName: "Mail", bundleID: "com.apple.mail",
                                     title: "\(m.subject) · \(m.sender.replacingOccurrences(of: #"\s*<[^>]+>"#, with: "", options: .regularExpression))")
            apply(SourceScan(changed: [SourceItem(key: m.id, rev: SourceHash.of(text), draft: draft)], present: nil), source: &src, packID: packID)
            store.updateSource(src, in: packID)
        }
    }

    // MARK: From the screen

    /// A source for what's in front: the page in a browser (repo, Notion page, login page or public page),
    /// or the thread selected in Apple Mail.
    func sourceForFront(_ app: NSRunningApplication?) async -> PackSource? {
        guard let app, let bid = app.bundleIdentifier else { return nil }
        if bid == "com.apple.mail" {
            guard let head = MailThread.selectedHeader() else { return nil }
            let subject = head.subject.nonEmpty ?? "Mail thread"
            return PackSource(kind: .mail, location: subject, title: subject.truncated(60))
        }
        let pid = app.processIdentifier
        let info = await Task.detached { ChatReader.pageInfo(pid: pid) }.value
        guard let url = info.url, var src = PackSource.from(link: url) else { return nil }
        if src.kind == .page || src.kind == .web, let t = info.title?.nonEmpty { src.title = cleanTitle(t) }
        return src
    }
}

extension CaptureService {
    static func isBrowser(_ bundleID: String) -> Bool {
        ["com.apple.Safari", "com.apple.SafariTechnologyPreview", "com.google.Chrome", "com.google.Chrome.beta", "com.brave.Browser",
         "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
         "org.mozilla.firefox"].contains(bundleID)
    }
}
