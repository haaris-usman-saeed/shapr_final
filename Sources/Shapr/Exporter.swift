import Foundation

/// Turns a pack into one Markdown document (for Claude, a .md file, or a shared copy).
enum Exporter {
    struct Options {
        var includeSources = true
        var includeTimes = true
        var includeApps = true
    }

    static func markdown(packName: String, captures: [Capture], options: Options = Options(),
                         footnote: String? = nil) -> String {
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var out = "# \(packName)\n\n"
        out += "> Context pack from Shapr · \(captures.count) capture\(captures.count == 1 ? "" : "s")"
        if let footnote { out += " · \(footnote)" }
        out += "\n"

        for (i, c) in captures.enumerated() {
            out += "\n## \(i + 1). \(c.displayTitle.singleLine)\n\n"
            var meta: [String] = []
            if options.includeSources, let url = c.url?.nonEmpty {
                meta.append("Source: [\(c.host ?? url)](\(url))")
            }
            if options.includeApps, let app = c.appName { meta.append(app) }
            if options.includeTimes { meta.append(df.string(from: c.capturedAt)) }
            if !meta.isEmpty { out += "*" + meta.joined(separator: " · ") + "*\n\n" }
            if c.image != nil { out += "_Screenshot; the text below was read from it._\n\n" }
            if let f = c.file { out += "_File: \(f); the text below was extracted from it._\n\n" }
            out += c.text.trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
        }
        return out
    }

    /// The pack wrapped with a short preamble, ready to paste into Claude or any chat.
    static func prompt(for pack: Pack) -> String {
        "The following is a context pack called “\(pack.name)” that I collected with Shapr. "
            + "Each section is one snippet with its source. Use it as background for my next request.\n\n"
            + markdown(packName: pack.name, captures: pack.captures)
    }
}
