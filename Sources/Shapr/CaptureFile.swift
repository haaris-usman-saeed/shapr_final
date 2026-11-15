import Foundation

/// Reads and writes a capture as Markdown with a small YAML front-matter header:
///
///     ---
///     id: 6F1C…
///     captured: 2026-11-07T10:22:01Z
///     app: "Safari"
///     title: "Toyota Supra – Wikipedia"
///     url: "https://en.wikipedia.org/wiki/Toyota_Supra"
///     ---
///
///     The captured text…
enum CaptureFile {
    /// Written with milliseconds so captures saved in the same second keep their order.
    static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()

    private static let isoSeconds: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()

    static func date(_ s: String) -> Date? { iso.date(from: s) ?? isoSeconds.date(from: s) }

    static func serialize(_ c: Capture) -> String {
        var lines = ["---", "id: \(c.id.uuidString)", "captured: \(iso.string(from: c.capturedAt))"]
        if let v = c.appName { lines.append("app: \(quote(v))") }
        if let v = c.bundleID { lines.append("bundle_id: \(quote(v))") }
        if let v = c.title { lines.append("title: \(quote(v))") }
        if let v = c.url { lines.append("url: \(quote(v))") }
        if let v = c.image { lines.append("image: \(quote(v))") }
        if let v = c.file { lines.append("file: \(quote(v))") }
        if let v = c.sourceID { lines.append("source_id: \(quote(v))") }
        if let v = c.sourceKey { lines.append("source_key: \(quote(v))") }
        if let v = c.sourceRev { lines.append("source_rev: \(quote(v))") }
        lines.append("---")
        return lines.joined(separator: "\n") + "\n\n" + c.text + "\n"
    }

    static func parse(_ s: String, fileName: String) -> Capture? {
        let src = s.replacingOccurrences(of: "\r\n", with: "\n")
        guard src.hasPrefix("---\n") else { return nil }
        let afterOpen = src.index(src.startIndex, offsetBy: 4)
        guard let close = src.range(of: "\n---\n", range: afterOpen..<src.endIndex)
                ?? (src.hasSuffix("\n---") ? src.range(of: "\n---", options: .backwards) : nil)
        else { return nil }

        var fields: [String: String] = [:]
        for line in src[afterOpen..<close.lowerBound].split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let key = line[..<colon].trimmingCharacters(in: .whitespaces)
            let raw = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            fields[key] = unquote(raw)
        }

        var body = String(src[close.upperBound...])
        if body.hasPrefix("\n") { body.removeFirst() }
        if body.hasSuffix("\n") { body.removeLast() }

        guard let idString = fields["id"], let id = UUID(uuidString: idString) else { return nil }
        let date = fields["captured"].flatMap(Self.date) ?? Date()
        return Capture(id: id, text: body, capturedAt: date,
                       appName: fields["app"], bundleID: fields["bundle_id"],
                       title: fields["title"], url: fields["url"], fileName: fileName,
                       image: fields["image"], file: fields["file"],
                       sourceID: fields["source_id"], sourceKey: fields["source_key"], sourceRev: fields["source_rev"])
    }

    /// JSON string literals are valid YAML double-quoted scalars.
    static func quote(_ s: String) -> String {
        var out = "\""
        for u in s.unicodeScalars {
            switch u {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            default:
                if u.value < 0x20 { out += String(format: "\\u%04x", u.value) } else { out.unicodeScalars.append(u) }
            }
        }
        return out + "\""
    }

    static func unquote(_ raw: String) -> String {
        guard raw.hasPrefix("\""), let data = raw.data(using: .utf8),
              let s = try? JSONSerialization.jsonObject(with: data, options: .fragmentsAllowed) as? String
        else { return raw }
        return s
    }
}
