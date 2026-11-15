import Foundation

/// A capture that has been grabbed from another app but not yet filed into a pack.
struct CaptureDraft {
    var text: String
    var capturedAt: Date = Date()
    var appName: String?
    var bundleID: String?
    var title: String?
    var url: String?
    /// PNG of a screen capture; saved next to the Markdown file.
    var imageData: Data?
    /// A local file (downloaded or dropped in) to keep with the capture.
    var attachment: URL?

    var host: String? { Capture.host(of: url) }
}

/// One captured snippet, stored on disk as a Markdown file with front matter.
struct Capture: Identifiable, Hashable {
    let id: UUID
    var text: String
    var capturedAt: Date
    var appName: String?
    var bundleID: String?
    var title: String?
    var url: String?
    var fileName: String
    /// Screenshot file name in the same pack folder, for screen captures.
    var image: String? = nil
    /// An attached file (PDF, doc, sheet…) in the same pack folder.
    var file: String? = nil
    /// Set for captures kept up to date from a live source (a folder, repo, Notion page or web page):
    /// which source, which item in it, and the version last saved.
    var sourceID: String? = nil
    var sourceKey: String? = nil
    var sourceRev: String? = nil

    /// Files kept next to the capture's Markdown.
    var sideFiles: [String] { [image, file].compactMap { $0 } }

    var host: String? { Capture.host(of: url) }

    var displayTitle: String {
        if let t = title?.nonEmpty { return t }
        if let line = text.firstLine.nonEmpty { return line.truncated(70) }
        return image != nil ? "Screenshot" : file ?? "Capture"
    }

    static func host(of url: String?) -> String? {
        guard let url, let u = URL(string: url) else { return nil }
        if u.isFileURL { return u.lastPathComponent }
        guard var h = u.host else { return nil }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
}

/// What a pack is for. A facts pack holds what's true (the default); a style pack holds things you
/// wrote, so drafts can sound like you without taking any facts from them.
enum PackRole: String, Codable, Hashable {
    case facts, style
}

struct PackMeta: Codable, Hashable {
    var id: UUID
    var name: String
    var emoji: String?
    var created: Date
    /// True while the name was chosen by Shapr; a manual rename turns it off.
    var autoNamed: Bool
    /// nil means facts (packs saved before 0.13 have no role).
    var role: PackRole? = nil
    /// The pack's color, an index into PackStyle.palette: picked once when the pack is made, so packs
    /// don't share a color while there are colors to go round. Packs saved before 0.16 get one on load.
    var hue: Int? = nil
}

struct Pack: Identifiable, Hashable {
    var meta: PackMeta
    var folder: URL
    /// Oldest first.
    var captures: [Capture]

    var id: UUID { meta.id }
    var name: String { meta.name }
    var updated: Date { captures.last?.capturedAt ?? meta.created }
    /// The pack's initials (its orb). Packs are never shown with emoji.
    var badge: String { name.split { !($0.isLetter || $0.isNumber) }.first.map { String($0.prefix(1)).uppercased() } ?? "" }
    var label: String { name }
    /// A pack of your own writing: used for how drafts sound, never for facts.
    var isStyle: Bool { meta.role == .style }
}

// MARK: - String helpers

extension String {
    var nonEmpty: String? {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }

    var firstLine: String {
        let t = trimmingCharacters(in: .whitespacesAndNewlines)
        return String(t.split(whereSeparator: \.isNewline).first ?? Substring(t))
    }

    func truncated(_ n: Int) -> String {
        count <= n ? self : String(prefix(n - 1)).trimmingCharacters(in: .whitespaces) + "…"
    }

    /// Lowercase, ASCII, dash-separated, for file and folder names.
    func slug(maxWords: Int = 6) -> String {
        let folded = folding(options: [.diacriticInsensitive, .caseInsensitive], locale: .current).lowercased()
        let words = folded.split { !($0.isLetter || $0.isNumber) || !$0.isASCII }
        let s = words.prefix(maxWords).joined(separator: "-")
        return s.isEmpty ? "capture" : String(s.prefix(60))
    }

    var singleLine: String {
        replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespaces)
    }
}
