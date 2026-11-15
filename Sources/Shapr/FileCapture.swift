import AppKit
import ApplicationServices
import OSLog
import PDFKit

/// `log stream --predicate 'subsystem == "app.shapr.Shapr"'` shows what Shapr did with circled links.
let fileLog = Logger(subsystem: "app.shapr.Shapr", category: "files")

/// Which files Shapr will save as context. Documents, data, text and images only: never apps,
/// installers or scripts, and nothing is ever opened or run.
enum FileTypes {
    static let documents: Set<String> = ["pdf", "doc", "docx", "rtf", "odt", "pages", "pptx", "key", "xlsx", "numbers", "epub", "webarchive"]
    static let text: Set<String> = ["txt", "md", "markdown", "csv", "tsv", "json", "xml", "yaml", "yml", "log", "html", "htm",
                                    "py", "js", "ts", "tsx", "jsx", "swift", "java", "kt", "c", "h", "cpp", "hpp", "cs", "go",
                                    "rs", "rb", "php", "sql", "ipynb", "tex", "bib", "srt", "vtt"]
    static let images: Set<String> = ["png", "jpg", "jpeg", "gif", "webp", "heic", "tiff", "bmp"]
    static let blocked: Set<String> = ["app", "dmg", "pkg", "mpkg", "exe", "msi", "bat", "cmd", "command", "tool", "sh", "zsh",
                                       "bash", "scpt", "applescript", "workflow", "jar", "bin", "iso", "deb", "rpm", "apk",
                                       "ipa", "dylib", "so", "plugin", "kext", "terminal", "url", "webloc", "zip", "rar", "7z",
                                       "tar", "gz", "xz"]
    static let mimeToExt: [String: String] = [
        "application/pdf": "pdf", "text/plain": "txt", "text/markdown": "md", "text/csv": "csv", "application/json": "json",
        "application/msword": "doc", "application/rtf": "rtf", "image/png": "png", "image/jpeg": "jpg", "image/gif": "gif",
        "image/webp": "webp",
        "application/vnd.openxmlformats-officedocument.wordprocessingml.document": "docx",
        "application/vnd.openxmlformats-officedocument.presentationml.presentation": "pptx",
        "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet": "xlsx",
    ]

    static let maxBytes = 50_000_000

    static func isAllowed(ext: String) -> Bool {
        let e = ext.lowercased()
        return !blocked.contains(e) && (documents.contains(e) || text.contains(e) || images.contains(e))
    }

    /// A link that obviously points at a file (by its extension), excluding web pages.
    static func looksLikeFile(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        return !e.isEmpty && !["html", "htm", "php", "asp", "aspx"].contains(e) && isAllowed(ext: e)
    }

    /// No usable extension (none, or something like arXiv's "2401.12345"), but the link looks like a
    /// download; worth asking the server what it is.
    static func mightBeFile(_ url: URL) -> Bool {
        let e = url.pathExtension.lowercased()
        guard !looksLikeFile(url), !blocked.contains(e) else { return false }
        guard e.isEmpty || e.allSatisfy(\.isNumber) else { return false }
        let s = url.absoluteString.lowercased()
        let hints = ["download", "/pdf/", "export=", "attachment", "/file/", "/files/", "/raw/", "dl=1", "format=pdf"]
        return hints.contains { s.contains($0) }
    }
}

// MARK: - Links inside a screen region

/// A link found on screen: where it goes and what it says.
struct FoundLink {
    let url: URL
    /// The link's visible text, e.g. "mat223_2_6_I.pdf".
    let text: String?
    /// The link on the page, so Shapr can press it like a click.
    var element: AXUIElement? = nil
}

@MainActor
enum LinkFinder {
    /// Every link inside `rect` (global AppKit coordinates), top to bottom.
    /// On a web page it reads the page's links and keeps the ones whose box falls in the circle, so the
    /// result is complete and the same every time. Elsewhere it falls back to hit-testing a grid.
    static func links(in rect: CGRect, maxSamples: Int = 360) -> [FoundLink] {
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let axRect = CGRect(x: rect.minX, y: mainHeight - rect.maxY, width: rect.width, height: rect.height)
        if let web = webArea(around: axRect) {
            let found = links(inside: web, area: axRect)
            fileLog.notice("page scan: \(found.count) link(s) in the circle")
            if !found.isEmpty { return found }
        }
        return sampledLinks(in: rect, maxSamples: maxSamples)
    }

    /// The web page under the circle (Safari, Chrome, Arc… expose it as an AXWebArea).
    static func webArea(around axRect: CGRect) -> AXUIElement? {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.5)
        let points = [CGPoint(x: axRect.midX, y: axRect.midY),
                      CGPoint(x: axRect.minX + axRect.width * 0.25, y: axRect.minY + axRect.height * 0.25),
                      CGPoint(x: axRect.maxX - axRect.width * 0.25, y: axRect.maxY - axRect.height * 0.25)]
        for p in points {
            var el: AXUIElement?
            guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(p.y), &el) == .success else { continue }
            var cur = el
            for _ in 0..<60 {
                guard let c = cur else { break }
                if (FormScanner.attr(c, kAXRoleAttribute) as String?) == "AXWebArea" { return c }
                cur = FormScanner.attr(c, kAXParentAttribute)
            }
        }
        return nil
    }

    /// Links inside `area` (Accessibility coordinates, top-left origin), skipping invisible ones.
    static func links(inside root: AXUIElement, area: CGRect, budget: TimeInterval = 3) -> [FoundLink] {
        let deadline = Date().addingTimeInterval(budget)
        let near = area.insetBy(dx: -60, dy: -60)
        var queue: [AXUIElement] = [root]
        var head = 0
        var found: [(link: FoundLink, frame: CGRect)] = []
        var seen = Set<String>()
        while head < queue.count, head < 20_000, Date() < deadline {
            let el = queue[head]; head += 1
            let role: String? = FormScanner.attr(el, kAXRoleAttribute)
            let f = frame(of: el)
            if role == "AXLink" {
                // Pages keep invisible leftover links (Quercus has empty ones about 10 pt tall): only keep
                // links tall enough to be a line of text, with some text.
                if let f, f.width >= 8, f.height >= 12, covers(area, f), let link = link(from: el), link.text?.nonEmpty != nil,
                   seen.insert(link.url.absoluteString).inserted {
                    found.append((link, f))
                }
                continue
            }
            // Skip whole sections of the page that are nowhere near the circle (or scrolled away).
            if el != root as AXUIElement?, let f, f.width > 0, f.height > 0, !f.intersects(near) { continue }
            queue.append(contentsOf: (FormScanner.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
        }
        if Date() >= deadline { fileLog.notice("page scan stopped at the time limit after \(head) elements") }
        return found.sorted { abs($0.frame.minY - $1.frame.minY) > 4 ? $0.frame.minY < $1.frame.minY : $0.frame.minX < $1.frame.minX }
            .map(\.link)
    }

    /// A link counts when its middle is in the circle, or most of it is.
    static func covers(_ area: CGRect, _ link: CGRect) -> Bool {
        if area.contains(CGPoint(x: link.midX, y: link.midY)) { return true }
        let i = area.intersection(link)
        return !i.isNull && i.width * i.height >= 0.5 * link.width * link.height
    }

    static func frame(of el: AXUIElement) -> CGRect? {
        var pos: CFTypeRef?, size: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, kAXPositionAttribute as CFString, &pos) == .success,
              AXUIElementCopyAttributeValue(el, kAXSizeAttribute as CFString, &size) == .success,
              let pos, let size, CFGetTypeID(pos) == AXValueGetTypeID(), CFGetTypeID(size) == AXValueGetTypeID() else { return nil }
        var p = CGPoint.zero, s = CGSize.zero
        guard AXValueGetValue(pos as! AXValue, .cgPoint, &p), AXValueGetValue(size as! AXValue, .cgSize, &s) else { return nil }
        return CGRect(origin: p, size: s)
    }

    /// Hit-tests a grid inside `rect` (global AppKit coordinates): for apps that aren't web pages.
    static func sampledLinks(in rect: CGRect, maxSamples: Int = 360) -> [FoundLink] {
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.25)
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        let step = max(8, (rect.width * rect.height / CGFloat(maxSamples)).squareRoot())
        var found: [(link: FoundLink, dist: CGFloat)] = []
        var seen = Set<String>()
        let deadline = Date().addingTimeInterval(2)

        var y = rect.minY + step / 2
        while y < rect.maxY, Date() < deadline {
            var x = rect.minX + step / 2
            while x < rect.maxX, Date() < deadline {
                var el: AXUIElement?
                if AXUIElementCopyElementAtPosition(system, Float(x), Float(mainHeight - y), &el) == .success,
                   let el, let link = link(from: el), seen.insert(link.url.absoluteString).inserted {
                    found.append((link, hypot(x - rect.midX, y - rect.midY)))
                }
                x += step
            }
            y += step
        }
        return found.sorted { $0.dist < $1.dist }.map(\.link)
    }

    /// The link at or just above this element, with its visible text.
    static func link(from start: AXUIElement) -> FoundLink? {
        var el: AXUIElement? = start
        for _ in 0..<8 {
            guard let cur = el else { return nil }
            let role: String? = FormScanner.attr(cur, kAXRoleAttribute)
            if role == "AXLink" {
                var value: CFTypeRef?
                guard AXUIElementCopyAttributeValue(cur, kAXURLAttribute as CFString, &value) == .success, let value else { return nil }
                let url: URL? = (value as? URL) ?? (value as? String).flatMap(URL.init(string:))
                guard let url, url.scheme?.hasPrefix("http") == true else { return nil }
                return FoundLink(url: url, text: text(of: cur), element: cur)
            }
            el = FormScanner.attr(cur, kAXParentAttribute)
        }
        return nil
    }

    private static func text(of link: AXUIElement) -> String? {
        for key in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            let v: String? = FormScanner.attr(link, key)
            if let v = v?.nonEmpty { return v }
        }
        // Otherwise the text inside it.
        var parts: [String] = []
        func walk(_ e: AXUIElement, depth: Int) {
            guard depth < 3, parts.count < 6 else { return }
            if let v: String = FormScanner.attr(e, kAXValueAttribute), let t = v.nonEmpty { parts.append(t) }
            for c in (FormScanner.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(c, depth: depth + 1) }
        }
        walk(link, depth: 0)
        return parts.joined(separator: " ").nonEmpty
    }

    /// The download button (like Quercus's ↓) for the same file, near a file-name link.
    /// Quercus shows it as a button labelled "Download <file name>" right after the link, with no address;
    /// other sites use a download link that points at the same file.
    static func downloadButton(near link: AXUIElement, text: String?, key: String?) -> AXUIElement? {
        // 1. A "Download …" button right after the link.
        if let parent: AXUIElement = FormScanner.attr(link, kAXParentAttribute),
           let siblings: [AXUIElement] = FormScanner.attr(parent, kAXChildrenAttribute),
           let i = siblings.firstIndex(where: { CFEqual($0, link) }) {
            for el in siblings.dropFirst(i + 1).prefix(3) {
                let role: String? = FormScanner.attr(el, kAXRoleAttribute)
                if role == "AXLink", label(el).map(isLinkText) == true { break } // the next file's link: stop
                if isDownloadControl(el, for: text) { return el }
            }
        }
        // 2. Anywhere in the row: a "Download <same name>" button, or a download link to the same file.
        return searchNearby(link, text: text, key: key)
    }

    private static func label(_ el: AXUIElement) -> String? {
        for k in [kAXTitleAttribute, kAXDescriptionAttribute, kAXValueAttribute] {
            if let s: String = FormScanner.attr(el, k), let t = s.nonEmpty { return t }
        }
        return nil
    }

    private static func isLinkText(_ s: String) -> Bool { !s.lowercased().hasPrefix("download") }

    /// A button or link labelled "Download", or "Download <this file's name>" (never another file's name).
    static func isDownloadLabel(_ label: String, for text: String?) -> Bool {
        func norm(_ s: String) -> String {
            s.lowercased().replacingOccurrences(of: #"["“”'’]"#, with: "", options: .regularExpression)
                .split(whereSeparator: \.isWhitespace).joined(separator: " ")
        }
        let l = norm(label)
        guard l.hasPrefix("download") else { return false }
        let rest = String(l.dropFirst("download".count)).trimmingCharacters(in: CharacterSet(charactersIn: " :"))
        guard !rest.isEmpty else { return true }
        guard let text, case let t = norm(text), !t.isEmpty else { return false }
        if rest == t { return true }
        // One of them shortened with an ellipsis.
        for (short, long) in [(rest, t), (t, rest)] where short.hasSuffix("…") || short.hasSuffix("...") {
            let stem = short.replacingOccurrences(of: "…", with: "").replacingOccurrences(of: "...", with: "")
            if stem.count >= 8, long.hasPrefix(stem) { return true }
        }
        return false
    }

    private static func isDownloadControl(_ el: AXUIElement, for text: String?) -> Bool {
        let role: String? = FormScanner.attr(el, kAXRoleAttribute)
        guard role == "AXButton" || role == "AXLink" else { return false }
        if let l = label(el), isDownloadLabel(l, for: text) { return true }
        // An icon-only download link: its address says so.
        var value: CFTypeRef?
        if role == "AXLink", AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &value) == .success, let value,
           let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)), FileLinkResolver.isDownloadLink(url),
           label(el) == nil {
            return true
        }
        return false
    }

    private static func searchNearby(_ link: AXUIElement, text: String?, key: String?) -> AXUIElement? {
        var ancestor: AXUIElement? = FormScanner.attr(link, kAXParentAttribute)
        for _ in 0..<5 {
            guard let a = ancestor else { return nil }
            var queue: [(AXUIElement, Int)] = [(a, 0)]
            var visited = 0
            while !queue.isEmpty, visited < 250 {
                let (el, depth) = queue.removeFirst()
                visited += 1
                let role: String? = FormScanner.attr(el, kAXRoleAttribute)
                if role == "AXButton" || role == "AXLink", !CFEqual(el, link) {
                    // Only a button that names this very file, so a neighbour's button is never pressed.
                    if let t = text?.nonEmpty, let l = label(el), l.lowercased() != "download", isDownloadLabel(l, for: t) {
                        return el
                    }
                    var value: CFTypeRef?
                    if role == "AXLink", let key, AXUIElementCopyAttributeValue(el, kAXURLAttribute as CFString, &value) == .success, let value,
                       let url = (value as? URL) ?? (value as? String).flatMap(URL.init(string:)),
                       FileLinkResolver.isDownloadLink(url), FileLinkResolver.siteDownload(url)?.key == key {
                        return el
                    }
                }
                if depth < 5 {
                    for c in (FormScanner.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { queue.append((c, depth + 1)) }
                }
            }
            ancestor = FormScanner.attr(a, kAXParentAttribute)
            if ancestor.map({ (FormScanner.attr($0, kAXRoleAttribute) as String?) == "AXWebArea" }) == true { break }
        }
        return nil
    }

    /// `Shapr --probe-downloads`: lists the file links on the front Safari window and the download button
    /// that would be pressed for each. Reads only; presses nothing.
    @MainActor
    static func probeFrontPage() {
        guard let safari = NSRunningApplication.runningApplications(withBundleIdentifier: "com.apple.Safari").first else {
            print("Safari isn't running"); return
        }
        let app = AXUIElementCreateApplication(safari.processIdentifier)
        guard let win: AXUIElement = FormScanner.attr(app, kAXFocusedWindowAttribute) else { print("No Safari window"); return }
        var queue = [win], links: [FoundLink] = [], seen = 0
        while !queue.isEmpty, seen < 20_000 {
            let e = queue.removeFirst(); seen += 1
            if (FormScanner.attr(e, kAXRoleAttribute) as String?) == "AXLink", let l = link(from: e) { links.append(l); continue }
            queue.append(contentsOf: (FormScanner.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
        }
        let (targets, _) = FileLinkResolver.targets(from: links)
        print("\(links.count) links, \(targets.count) files")
        // As if you circled every file name on the page that's visible right now.
        let frames = targets.compactMap { $0.linkElement.flatMap(frame(of:)) }.filter { $0.width > 2 && $0.height > 2 }
        if let first = frames.first, case let union = frames.dropFirst().reduce(first, { $0.union($1) }) {
            let mainHeight = NSScreen.screens.first?.frame.height ?? 0
            let appKit = CGRect(x: union.minX - 10, y: mainHeight - union.maxY - 10, width: union.width + 20, height: union.height + 20)
            // Safari's page directly (another window may be in front of it while this runs).
            var web: AXUIElement?
            var q = [win], h = 0
            while h < q.count, h < 5000, web == nil {
                let e = q[h]; h += 1
                if (FormScanner.attr(e, kAXRoleAttribute) as String?) == "AXWebArea" { web = e; break }
                q.append(contentsOf: (FormScanner.attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [])
            }
            _ = appKit
            print("visible file links span \(Int(union.width))×\(Int(union.height)) at y=\(Int(union.minY)); page found: \(web != nil)")
            for run in 1...3 {
                let t0 = Date()
                let files = FileLinkResolver.targets(from: web.map { Self.links(inside: $0, area: union.insetBy(dx: -10, dy: -10)) } ?? []).sure
                print(String(format: "circle around all of them, run %d: %d file(s) in %.2fs", run, files.count, Date().timeIntervalSince(t0))
                      + (run == 1 ? ": " + files.map { $0.name ?? "?" }.joined(separator: ", ") : ""))
                if run == 1 {
                    for t in files where t.name == nil || t.name!.hasPrefix("\"") {
                        let f = t.linkElement.flatMap(frame(of:)) ?? .zero
                        print("   odd one: text=\"\(t.linkText ?? "nil")\" frame=\(Int(f.minX)),\(Int(f.minY)) \(Int(f.width))×\(Int(f.height)) url=\(t.download.path)")
                    }
                }
            }
        }
        for t in targets {
            let button = t.pressElement ?? t.linkElement.flatMap { downloadButton(near: $0, text: t.linkText ?? t.name, key: t.siteKey) }
            print("  \(t.name ?? t.download.lastPathComponent)  →  " + (button.flatMap(label) ?? "no button (would open a background tab)"))
        }
    }

    /// Chromium apps only expose web content to Accessibility on request; ask early so it's ready.
    static func prepare(_ app: NSRunningApplication?) {
        guard let app else { return }
        AXUIElementSetAttributeValue(AXUIElementCreateApplication(app.processIdentifier),
                                     "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }
}

// MARK: - Which links are files, and where to download them from

/// A file link ready to download.
struct FileTarget {
    var download: URL
    /// From the link's text or address, when known ("mat223_2_6_I.pdf").
    var name: String?
    var ext: String?
    /// Known sites always need the browser's login to download.
    var needsLogin: Bool
    /// An on-page download link (like Quercus's ↓). Pressing it downloads in place, with no new tab.
    var pressElement: AXUIElement? = nil
    /// The link that was circled, used to find its ↓ button when only the file name was circled.
    var linkElement: AXUIElement? = nil
    /// The link's visible text ("mat223_1_1.pdf"), to recognize a "Download mat223_1_1.pdf" button.
    var linkText: String? = nil
    /// Identifies the file on its site (Canvas file id), so its ↓ button can be recognized.
    var siteKey: String? = nil
}

enum FileLinkResolver {
    /// Turns the links in a circle into files to download: one per file, even when a site shows both a
    /// file-name link and a download icon for it.
    static func targets(from links: [FoundLink]) -> (sure: [FileTarget], maybe: [URL]) {
        var sure: [FileTarget] = []
        var maybe: [URL] = []
        var byKey: [String: Int] = [:]
        for link in links {
            let textName = fileName(fromText: link.text)
            let press = isDownloadLink(link.url) ? link.element : nil
            if let site = siteDownload(link.url) {
                let name = textName ?? site.name
                let t = FileTarget(download: site.url, name: name, ext: name.map { ($0 as NSString).pathExtension.lowercased() },
                                   needsLogin: site.needsLogin, pressElement: press, linkElement: link.element,
                                   linkText: link.text, siteKey: site.key)
                merge(t, key: site.key, into: &sure, byKey: &byKey)
            } else if FileTypes.looksLikeFile(link.url) {
                let name = textName ?? FileDownloader.sanitize(link.url.lastPathComponent)
                merge(FileTarget(download: link.url, name: name, ext: link.url.pathExtension.lowercased(), needsLogin: false,
                                 pressElement: press), key: link.url.absoluteString, into: &sure, byKey: &byKey)
            } else if let textName {
                // The link says it's a file ("Lecture 3.pdf") even if its address doesn't.
                merge(FileTarget(download: link.url, name: textName, ext: (textName as NSString).pathExtension.lowercased(),
                                 needsLogin: false, pressElement: press), key: link.url.absoluteString, into: &sure, byKey: &byKey)
            } else if FileTypes.mightBeFile(link.url) {
                maybe.append(link.url)
            }
        }
        return (sure, maybe)
    }

    private static func merge(_ t: FileTarget, key: String, into list: inout [FileTarget], byKey: inout [String: Int]) {
        if let i = byKey[key] {
            if list[i].name == nil, let n = t.name { list[i].name = n; list[i].ext = t.ext }
            if list[i].pressElement == nil { list[i].pressElement = t.pressElement }
        } else {
            byKey[key] = list.count
            list.append(t)
        }
    }

    /// Links that download when clicked instead of opening a page (safe to press in place).
    static func isDownloadLink(_ url: URL) -> Bool {
        let s = url.absoluteString.lowercased()
        return url.path.lowercased().hasSuffix("/download") || s.contains("download_frd=1") || s.contains("export=download")
            || s.contains("dl=1") || s.contains("attachment=1") || s.contains("download=1")
    }

    /// "mat223_2_6_I.pdf" → itself; "Download (PDF)" → nil.
    static func fileName(fromText text: String?) -> String? {
        guard let t = text?.trimmingCharacters(in: .whitespacesAndNewlines), t.count <= 200,
              let last = t.split(separator: " ").last.map(String.init) else { return nil }
        for candidate in [t, last] {
            let ext = (candidate as NSString).pathExtension.lowercased()
            if !ext.isEmpty, FileTypes.isAllowed(ext: ext), !["html", "htm"].contains(ext) {
                return FileDownloader.sanitize(candidate)
            }
        }
        return nil
    }

    /// Download addresses for sites whose file links don't point straight at the file.
    static func siteDownload(_ url: URL) -> (url: URL, key: String, name: String?, needsLogin: Bool)? {
        let host = url.host?.lowercased() ?? ""
        let path = url.path

        // Canvas (Quercus, *.instructure.com and every other Canvas school): /courses/1/files/2[/download|/preview]
        if let r = path.range(of: #"(/courses/\d+)?/files/\d+"#, options: .regularExpression),
           path.contains("/courses/") || host.contains("instructure") || host.contains("canvas") || host == "q.utoronto.ca" {
            let base = String(path[r])
            var c = URLComponents()
            c.scheme = url.scheme
            c.host = url.host
            c.port = url.port
            c.path = base + "/download"
            c.queryItems = [URLQueryItem(name: "download_frd", value: "1")]
            if let u = c.url { return (u, host + base, nil, true) }
        }
        // Google Drive: /file/d/<id>/view → direct download
        if host == "drive.google.com", let r = path.range(of: #"/file/d/[^/]+"#, options: .regularExpression) {
            let id = path[r].split(separator: "/").last.map(String.init) ?? ""
            if let u = URL(string: "https://drive.google.com/uc?export=download&id=\(id)") { return (u, "gdrive:" + id, nil, true) }
        }
        // Dropbox: dl=0 → dl=1
        if host.hasSuffix("dropbox.com"), var c = URLComponents(url: url, resolvingAgainstBaseURL: false) {
            var items = (c.queryItems ?? []).filter { $0.name != "dl" }
            items.append(URLQueryItem(name: "dl", value: "1"))
            c.queryItems = items
            if let u = c.url, url.pathExtension.nonEmpty != nil {
                return (u, "dropbox:" + url.path, FileDownloader.sanitize(url.lastPathComponent), false)
            }
        }
        // GitHub: /owner/repo/blob/ref/path → raw file
        if host == "github.com" {
            let parts = path.split(separator: "/").map(String.init)
            if parts.count >= 5, parts[2] == "blob", FileTypes.isAllowed(ext: (parts.last! as NSString).pathExtension) {
                let raw = "https://raw.githubusercontent.com/" + ([parts[0], parts[1]] + parts[3...]).joined(separator: "/")
                if let u = URL(string: raw) { return (u, raw, parts.last, false) }
            }
        }
        return nil
    }
}

// MARK: - Downloading

enum FileDownloader {
    enum DownloadError: LocalizedError {
        case notAFile, tooBig(Int), blocked(String), needsBrowser, timedOut, http(Int)
        var errorDescription: String? {
            switch self {
            case .notAFile: return "That link isn't a file Shapr can save."
            case .tooBig(let n): return "The file is \(ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)), over Shapr's 50 MB limit."
            case .blocked(let e): return "Shapr doesn't save .\(e) files."
            case .needsBrowser: return "This file needs your browser's login."
            case .timedOut: return "The download didn't finish in time."
            case .http(let c): return "The server answered \(c)."
            }
        }
    }

    struct Result {
        let file: URL
        let name: String
    }

    /// Asks the server what a link is without downloading it. Returns an extension Shapr accepts, or nil.
    static func probe(_ url: URL) async -> String? {
        var req = URLRequest(url: url)
        req.httpMethod = "HEAD"
        req.timeoutInterval = 5
        guard let (_, resp) = try? await URLSession.shared.data(for: req), let http = resp as? HTTPURLResponse,
              (200..<400).contains(http.statusCode), let mime = http.mimeType?.lowercased() else { return nil }
        if mime == "text/html" { return nil }
        if let ext = FileTypes.mimeToExt[mime] { return ext }
        if let name = http.suggestedFilename.map({ ($0 as NSString).pathExtension }), FileTypes.isAllowed(ext: name) { return name }
        return nil
    }

    /// Downloads straight from the server (public links). Throws `.needsBrowser` when the server
    /// answers with a login page instead of the file.
    static func download(_ url: URL, expectedExt: String?) async throws -> Result {
        var req = URLRequest(url: url)
        req.timeoutInterval = 60
        let (tmp, resp) = try await URLSession.shared.download(for: req)
        guard let http = resp as? HTTPURLResponse else { throw DownloadError.notAFile }
        if [401, 403].contains(http.statusCode) { throw DownloadError.needsBrowser }
        guard (200..<300).contains(http.statusCode) else { throw DownloadError.http(http.statusCode) }
        let size = (try? tmp.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size <= FileTypes.maxBytes else { throw DownloadError.tooBig(size) }

        let mime = http.mimeType?.lowercased() ?? ""
        var name = sanitize(http.suggestedFilename ?? url.lastPathComponent)
        var ext = (name as NSString).pathExtension.lowercased()
        if mime == "text/html" && !["html", "htm"].contains(expectedExt ?? "") { throw DownloadError.needsBrowser }
        if ext.isEmpty || !FileTypes.isAllowed(ext: ext), let fromMime = FileTypes.mimeToExt[mime] ?? expectedExt {
            ext = fromMime
            name = (name as NSString).deletingPathExtension + "." + ext
        }
        if FileTypes.blocked.contains(ext) { throw DownloadError.blocked(ext) }
        guard FileTypes.isAllowed(ext: ext) else { throw DownloadError.notAFile }

        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-dl-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let dest = dir.appendingPathComponent(name)
        try FileManager.default.moveItem(at: tmp, to: dest)
        Quarantine.mark(dest, from: url)
        return Result(file: dest, name: name)
    }

    struct BrowserItem {
        var url: URL
        var press: AXUIElement?
        /// The name the page shows, used to match the finished file.
        var expectedName: String?
    }

    /// Downloads several login-protected files at once with your browser's session, then picks the
    /// finished files up from Downloads (your browser keeps its copies).
    /// - On-page download links (like Quercus's ↓) are pressed in place: no new tabs.
    /// - Anything that can't be pressed, or doesn't start, opens in a background tab that's closed
    ///   when the batch finishes, and you're put back on your page.
    /// Returns the finished files by item index; `progress` reports how many are done.
    @MainActor
    static func viaBrowser(_ items: [BrowserItem], browserBundleID: String?, since batchStart: Date = Date(),
                           timeout: TimeInterval = 90, folder: URL? = nil,
                           open: ((URL) async -> Void)? = nil,
                           press pressOverride: ((Int) async -> Bool)? = nil,
                           progress: (Int) -> Void = { _ in }) async -> [Int: Result] {
        let downloads = folder ?? FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        let listing: [String]
        do {
            listing = try FileManager.default.contentsOfDirectory(atPath: downloads.path)
        } catch {
            fileLog.error("can't read \(downloads.path, privacy: .public): \(error.localizedDescription, privacy: .public)")
            listing = []
        }
        // A file counts as new if it wasn't there before, if it was created after you circled (a download
        // that lands while Shapr is still getting ready), or if it replaced a file with the same name
        // (Safari can save over an earlier copy instead of adding "(1)").
        var snapshot: [String: Date] = [:]
        for name in listing where !isNew(name, in: downloads, since: batchStart) { snapshot[name] = stamp(name, in: downloads) }
        let before = Snapshot(dir: downloads, stamps: snapshot)
        fileLog.notice("browser batch: \(items.count) item(s), \(before.count) existing file(s), expected \(items.map { $0.expectedName ?? "?" }.joined(separator: ", "), privacy: .public)")
        let tabs = BrowserTabs.Session(bundleID: browserBundleID)
        var waiting = Set(items.indices)

        // 1. Press each on-page download button, one at a time. A press starts a page load in the
        //    browser, and the next press cancels it if its download hasn't begun yet, so wait for each
        //    download to show up in the folder (or its .download placeholder) before pressing the next.
        func press(_ i: Int) async -> Bool {
            if let pressOverride { return await pressOverride(i) }
            guard let el = items[i].press else { return false }
            let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
            if r != .success { fileLog.notice("press failed for item \(i): AX error \(r.rawValue)") }
            return r == .success
        }
        func waitForStart(_ i: Int, since known: Set<String>, seconds: Double) async -> Bool {
            let until = Date().addingTimeInterval(seconds)
            while Date() < until {
                try? await Task.sleep(for: .milliseconds(120))
                let fresh = entries(downloads, excluding: before).filter { !known.contains($0) }
                if items[i].expectedName == nil ? !fresh.isEmpty : hasStarted(items[i].expectedName, in: fresh) { return true }
            }
            return false
        }
        var pressed: [Int] = []
        var stalled: [Int] = []
        for i in items.indices where items[i].press != nil || pressOverride != nil {
            let known = Set(entries(downloads, excluding: before))
            guard await press(i) else { continue }
            pressed.append(i)
            if await waitForStart(i, since: known, seconds: 4) { continue }
            // Didn't start: press once more before giving up on doing it in place.
            if await press(i), await waitForStart(i, since: known, seconds: 3) { continue }
            stalled.append(i)
        }
        fileLog.notice("pressed \(pressed.count) of \(items.count) link(s) on the page; \(stalled.count) didn't start")
        // 2. Only what couldn't be done on the page opens in a background tab (closed afterwards).
        var toOpen = items.indices.filter { !pressed.contains($0) } + stalled
        if !toOpen.isEmpty { fileLog.notice("opening \(toOpen.count) link(s) in background tabs") }
        for i in toOpen {
            if let open { await open(items[i].url); continue }
            await openInBackground(items[i].url, browserBundleID: browserBundleID)
            tabs.noteOpened()
        }
        defer { tabs.closeOpenedAndReturn() }

        // 3. Collect finished files, matching them to links by name where possible.
        var results: [Int: Result] = [:]
        var claimed = Set<String>()
        var lastSizes: [String: Int] = [:]
        let partial: Set<String> = ["crdownload", "download", "part", "tmp", "partial"]
        let deadline = Date().addingTimeInterval(timeout)
        while !waiting.isEmpty && Date() < deadline {
            try? await Task.sleep(for: .milliseconds(400))
            for name in entries(downloads, excluding: before).sorted() where !claimed.contains(name) {
                let ext = (name as NSString).pathExtension.lowercased()
                guard !partial.contains(ext) else { continue }
                let path = downloads.appendingPathComponent(name)
                let size = (try? path.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
                defer { lastSizes[name] = size }
                guard size > 0, lastSizes[name] == size else { continue } // still growing
                claimed.insert(name)
                guard FileTypes.isAllowed(ext: ext), !FileTypes.blocked.contains(ext), size <= FileTypes.maxBytes else { continue }
                let index = waiting.first { matches(name, items[$0].expectedName) } ?? waiting.sorted().first
                guard let index else { continue }
                let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-dl-\(UUID().uuidString)")
                try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
                let copy = dir.appendingPathComponent(name)
                do {
                    try FileManager.default.copyItem(at: path, to: copy)
                } catch {
                    fileLog.error("couldn't copy \(name, privacy: .public): \(error.localizedDescription, privacy: .public)")
                    claimed.remove(name) // try again on the next pass
                    continue
                }
                fileLog.notice("got \(name, privacy: .public) for item \(index)")
                results[index] = Result(file: copy, name: name)
                waiting.remove(index)
                progress(results.count)
            }
        }
        if !waiting.isEmpty {
            let seen = entries(downloads, excluding: before)
            fileLog.error("gave up waiting for \(waiting.count) file(s); new in folder: \(seen.joined(separator: ", "), privacy: .public)")
        }
        return results
    }

    /// Created (or added to the folder) at or after `since`, give or take a few seconds.
    static func isNew(_ name: String, in dir: URL, since: Date) -> Bool {
        stamp(name, in: dir) >= since.addingTimeInterval(-3)
    }

    /// What was in the folder before the batch, by name and creation time.
    struct Snapshot {
        let dir: URL
        let stamps: [String: Date]
        var count: Int { stamps.count }
        /// Not there before, or there before but since replaced by a newer file of the same name.
        func isOld(_ name: String) -> Bool {
            guard let old = stamps[name] else { return false }
            return FileDownloader.stamp(name, in: dir) <= old.addingTimeInterval(0.5)
        }
    }

    private static func entries(_ dir: URL, excluding before: Snapshot) -> [String] {
        ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { !$0.hasPrefix(".") && !before.isOld($0) }
    }

    /// When a file appeared: the later of its creation date and the date it was added to the folder.
    static func stamp(_ name: String, in dir: URL) -> Date {
        let v = try? dir.appendingPathComponent(name).resourceValues(forKeys: [.creationDateKey, .addedToDirectoryDateKey])
        return max(v?.creationDate ?? .distantPast, v?.addedToDirectoryDate ?? .distantPast)
    }

    private static func hasStarted(_ expected: String?, in names: [String]) -> Bool {
        guard let expected else { return !names.isEmpty }
        return names.contains { matches($0, expected) || $0.hasPrefix((expected as NSString).deletingPathExtension) }
    }

    /// "mat223_5_1.pdf" matches "mat223_5_1.pdf", "mat223_5_1 (1).pdf" and "mat223_5_1-2.pdf".
    static func matches(_ fileName: String, _ expected: String?) -> Bool {
        guard let expected else { return false }
        let a = (fileName as NSString).deletingPathExtension.lowercased()
        let b = (expected as NSString).deletingPathExtension.lowercased()
        guard (fileName as NSString).pathExtension.lowercased() == (expected as NSString).pathExtension.lowercased() else { return false }
        return a == b || a.hasPrefix(b + " (") || a.hasPrefix(b + "-") || a.replacingOccurrences(of: " ", with: "_") == b.replacingOccurrences(of: " ", with: "_")
    }

    @MainActor
    private static func openInBackground(_ url: URL, browserBundleID: String?) async {
        if let bid = browserBundleID, let app = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bid) {
            let config = NSWorkspace.OpenConfiguration()
            config.activates = false
            _ = try? await NSWorkspace.shared.open([url], withApplicationAt: app, configuration: config)
        } else {
            NSWorkspace.shared.open(url)
        }
        try? await Task.sleep(for: .milliseconds(600))
    }

    static func sanitize(_ name: String) -> String {
        var n = name.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: ":", with: "-")
        while n.hasPrefix(".") { n.removeFirst() }
        if n.isEmpty { n = "file" }
        return String(n.prefix(120))
    }
}

/// Marks a file as downloaded from the internet, so macOS checks it if it's ever opened.
enum Quarantine {
    static func mark(_ file: URL, from origin: URL?) {
        let value = String(format: "0083;%08x;Shapr;", Int(Date().timeIntervalSince1970))
        _ = value.withCString { setxattr(file.path, "com.apple.quarantine", $0, strlen($0), 0, 0) }
        if let origin {
            let plist = try? PropertyListSerialization.data(fromPropertyList: [origin.absoluteString], format: .binary, options: 0)
            plist?.withUnsafeBytes { buf in
                _ = setxattr(file.path, "com.apple.metadata:kMDItemWhereFroms", buf.baseAddress, buf.count, 0, 0)
            }
        }
    }

    static func isMarked(_ file: URL) -> Bool {
        getxattr(file.path, "com.apple.quarantine", nil, 0, 0, 0) > 0
    }
}

// MARK: - Text out of files

enum FileText {
    static let maxChars = 300_000

    /// Reads the text in a document, sheet, slide deck, text file or image. Never opens the file in another app.
    static func extract(_ file: URL) async -> String {
        let ext = file.pathExtension.lowercased()
        // AppKit's Word/HTML/RTF importers must run on the main thread.
        if attributedTypes[ext] != nil {
            return await MainActor.run { clip(attributedText(file, ext: ext)) }
        }
        return await Task.detached(priority: .userInitiated) { extractSync(file) }.value
    }

    private static let attributedTypes: [String: NSAttributedString.DocumentType] = [
        "docx": .officeOpenXML, "doc": .docFormat, "rtf": .rtf, "odt": .openDocument,
        "html": .html, "htm": .html, "webarchive": .webArchive,
    ]

    private static func attributedText(_ file: URL, ext: String) -> String {
        guard let t = attributedTypes[ext],
              let s = try? NSAttributedString(url: file, options: [.documentType: t], documentAttributes: nil) else { return "" }
        return s.string
    }

    private static func clip(_ s: String) -> String {
        String(s.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
    }

    static func extractSync(_ file: URL) -> String {
        let ext = file.pathExtension.lowercased()
        var text = ""
        switch ext {
        case "pdf":
            if let doc = PDFDocument(url: file) {
                var parts: [String] = []
                for i in 0..<min(doc.pageCount, 400) {
                    if let s = doc.page(at: i)?.string { parts.append(s) }
                }
                text = parts.joined(separator: "\n\n")
                if text.trimmingCharacters(in: .whitespacesAndNewlines).count < 40 {
                    // A scanned PDF: read the first pages with OCR.
                    text = (0..<min(doc.pageCount, 10)).compactMap { i -> String? in
                        guard let page = doc.page(at: i) else { return nil }
                        let img = page.thumbnail(of: CGSize(width: 1600, height: 2000), for: .mediaBox)
                        return img.cgImage(forProposedRect: nil, context: nil, hints: nil).map(OCR.recognize)
                    }.joined(separator: "\n\n")
                }
            }
        case "docx", "doc", "rtf", "odt", "html", "htm", "webarchive":
            text = "" // handled on the main thread in extract()
        case "pptx", "xlsx":
            text = officeXMLText(file, ext: ext)
        case _ where FileTypes.images.contains(ext):
            if let img = NSImage(contentsOf: file), let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil) {
                text = OCR.recognize(cg)
                if text.count < 20 {
                    let labels = OCR.labels(for: cg)
                    if !labels.isEmpty { text += (text.isEmpty ? "" : "\n") + "Image: " + labels.joined(separator: ", ") }
                }
            }
        case _ where FileTypes.text.contains(ext):
            text = (try? String(contentsOf: file, encoding: .utf8))
                ?? (try? String(contentsOf: file, encoding: .isoLatin1)) ?? ""
        default:
            text = ""
        }
        return String(text.trimmingCharacters(in: .whitespacesAndNewlines).prefix(maxChars))
    }

    /// Slides and spreadsheets are zipped XML; pull the text runs out of the slide and shared-string parts.
    private static func officeXMLText(_ file: URL, ext: String) -> String {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("shapr-x-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        p.arguments = ["-x", "-k", file.path, dir.path]
        p.standardError = Pipe()
        guard (try? p.run()) != nil else { return "" }
        p.waitUntilExit()

        var parts: [URL] = []
        if ext == "pptx" {
            let slides = dir.appendingPathComponent("ppt/slides")
            parts = ((try? FileManager.default.contentsOfDirectory(at: slides, includingPropertiesForKeys: nil)) ?? [])
                .filter { $0.pathExtension == "xml" }
                .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
        } else {
            parts = [dir.appendingPathComponent("xl/sharedStrings.xml")]
        }
        let runPattern = ext == "pptx" ? #"<a:t>([^<]*)</a:t>"# : #"<t[^>]*>([^<]*)</t>"#
        guard let re = try? NSRegularExpression(pattern: runPattern) else { return "" }
        var out: [String] = []
        for (i, url) in parts.enumerated() {
            guard let xml = try? String(contentsOf: url, encoding: .utf8) else { continue }
            let runs = re.matches(in: xml, range: NSRange(xml.startIndex..., in: xml)).compactMap {
                Range($0.range(at: 1), in: xml).map { String(xml[$0]) }
            }.map(unescape)
            if runs.isEmpty { continue }
            out.append(ext == "pptx" ? "Slide \(i + 1): " + runs.joined(separator: " ") : runs.joined(separator: "\n"))
        }
        return out.joined(separator: "\n")
    }

    private static func unescape(_ s: String) -> String {
        s.replacingOccurrences(of: "&lt;", with: "<").replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&quot;", with: "\"").replacingOccurrences(of: "&apos;", with: "'")
            .replacingOccurrences(of: "&amp;", with: "&")
    }
}

// MARK: - From a file to a capture

enum FileImporter {
    /// A capture for a local file: its text, its name as the title, and the file itself attached.
    static func draft(file: URL, name: String? = nil, sourceURL: URL? = nil, appName: String? = nil) async -> CaptureDraft? {
        let ext = file.pathExtension.lowercased()
        guard FileTypes.isAllowed(ext: ext) else { return nil }
        let size = (try? file.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        guard size > 0, size <= FileTypes.maxBytes else { return nil }
        let text = await FileText.extract(file)
        let title = name ?? file.lastPathComponent
        return CaptureDraft(text: text.nonEmpty ?? "File: \(title)", appName: appName, title: title,
                            url: sourceURL?.absoluteString, attachment: file)
    }
}
