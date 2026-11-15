import AppKit

/// A `.shapr` file: a zip of one pack folder (pack.json plus a Markdown file per capture).
/// Friends double-click it and the pack appears in their library.
enum PackBundle {
    enum BundleError: LocalizedError {
        case zip(String)
        case notAPack
        var errorDescription: String? {
            switch self {
            case .zip(let s): return "Couldn't read or write the file: \(s)"
            case .notAPack: return "That file doesn't contain a Shapr pack."
            }
        }
    }

    static let fileExtension = "shapr"
    private static let maxFiles = 2000
    private static let maxFileBytes = 4_000_000
    private static let maxImageBytes = 25_000_000

    // MARK: Export

    /// `imageFolder` is where the captures' screenshots live (their pack folder); nil leaves images out.
    static func write(name: String, emoji: String?, captures: [Capture], imageFolder: URL? = nil, to dest: URL) throws {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shapr-export-\(UUID().uuidString)", isDirectory: true)
        let folder = tmp.appendingPathComponent(name.slug(), isDirectory: true)
        try fm.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }

        let meta = PackMeta(id: UUID(), name: name, emoji: emoji, created: Date(), autoNamed: false)
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        try enc.encode(meta).write(to: folder.appendingPathComponent("pack.json"))

        var used = Set<String>()
        for (i, c) in captures.enumerated() {
            var base = String(format: "%03d-", i + 1) + (c.title?.nonEmpty ?? c.text).slug()
            while used.contains(base) { base += "-x" }
            used.insert(base)
            var out = c
            out.fileName = base + ".md"
            if let img = c.image, let src = imageFolder?.appendingPathComponent(img), fm.fileExists(atPath: src.path) {
                out.image = base + "." + (img as NSString).pathExtension
                try fm.copyItem(at: src, to: folder.appendingPathComponent(out.image!))
            } else {
                out.image = nil
            }
            if let f = c.file, let src = imageFolder?.appendingPathComponent(f), fm.fileExists(atPath: src.path) {
                out.file = base + ".attachment." + (f as NSString).pathExtension
                try fm.copyItem(at: src, to: folder.appendingPathComponent(out.file!))
            } else {
                out.file = nil
            }
            try CaptureFile.serialize(out).write(to: folder.appendingPathComponent(out.fileName), atomically: true, encoding: .utf8)
        }

        try? fm.removeItem(at: dest)
        try run("/usr/bin/ditto", ["-c", "-k", "--keepParent", folder.path, dest.path])
    }

    // MARK: Import

    struct Contents {
        var name: String
        var emoji: String?
        var drafts: [CaptureDraft]
    }

    /// Reads a .shapr file. Only regular .md files and pack.json are read; links and anything else are ignored.
    static func read(_ file: URL) throws -> Contents {
        let fm = FileManager.default
        let tmp = fm.temporaryDirectory.appendingPathComponent("shapr-import-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tmp) }
        try run("/usr/bin/ditto", ["-x", "-k", file.path, tmp.path])

        // The pack folder is the extracted folder that holds pack.json (or the root itself).
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        var files: [URL] = []
        if let walker = fm.enumerator(at: tmp, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) {
            for case let url as URL in walker {
                guard files.count < maxFiles else { break }
                let v = try? url.resourceValues(forKeys: Set(keys))
                let isMedia = ["png", "jpg", "jpeg"].contains(url.pathExtension.lowercased())
                    || url.lastPathComponent.contains(".attachment.")
                guard v?.isSymbolicLink != true, v?.isRegularFile == true,
                      (v?.fileSize ?? 0) <= (isMedia ? FileTypes.maxBytes : maxFileBytes) else { continue }
                files.append(url)
            }
        }
        guard let metaURL = files.first(where: { $0.lastPathComponent == "pack.json" }) else { throw BundleError.notAPack }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        let meta = try? dec.decode(PackMeta.self, from: Data(contentsOf: metaURL))
        let packDir = metaURL.deletingLastPathComponent().standardizedFileURL.path

        var drafts: [CaptureDraft] = []
        for f in files where f.pathExtension.lowercased() == "md" && !f.lastPathComponent.contains(".attachment.")
            && f.deletingLastPathComponent().standardizedFileURL.path == packDir {
            guard let s = try? String(contentsOf: f, encoding: .utf8) else { continue }
            if let c = CaptureFile.parse(s, fileName: f.lastPathComponent) {
                // Only an image file sitting right next to the capture, and only if it really is an image.
                var imageData: Data?
                if let img = c.image, !img.contains("/"),
                   let imgURL = files.first(where: { $0.lastPathComponent == img
                       && $0.deletingLastPathComponent().standardizedFileURL.path == packDir }),
                   let data = try? Data(contentsOf: imgURL), NSImage(data: data) != nil {
                    imageData = NSBitmapImageRep(data: data)?.representation(using: .png, properties: [:]) ?? data
                }
                // Attached files: only allowed types, only from the same folder, kept in a temp copy for import.
                var attachment: URL?
                if let f = c.file, !f.contains("/"), FileTypes.isAllowed(ext: (f as NSString).pathExtension),
                   let src = files.first(where: { $0.lastPathComponent == f
                       && $0.deletingLastPathComponent().standardizedFileURL.path == packDir }) {
                    let keep = fm.temporaryDirectory.appendingPathComponent("shapr-import-files-\(UUID().uuidString)")
                    try? fm.createDirectory(at: keep, withIntermediateDirectories: true)
                    let dest = keep.appendingPathComponent(f)
                    if (try? fm.copyItem(at: src, to: dest)) != nil {
                        Quarantine.mark(dest, from: nil)
                        attachment = dest
                    }
                }
                drafts.append(CaptureDraft(text: c.text, capturedAt: c.capturedAt, appName: c.appName,
                                           bundleID: nil, title: c.title, url: c.url, imageData: imageData,
                                           attachment: attachment))
            } else if let text = s.nonEmpty {
                drafts.append(CaptureDraft(text: text, title: f.deletingPathExtension().lastPathComponent))
            }
        }
        drafts.sort { $0.capturedAt < $1.capturedAt }
        let name = meta?.name.nonEmpty ?? metaURL.deletingLastPathComponent().lastPathComponent
        return Contents(name: PackNaming.clean(name), emoji: PackNaming.cleanEmoji(meta?.emoji), drafts: drafts)
    }

    /// Adds the bundle's contents to the library as a new pack (never merged into an existing one).
    @MainActor
    @discardableResult
    static func importPack(_ file: URL, into store: PackStore) throws -> Pack {
        let contents = try read(file)
        let p = store.createPack(name: contents.name, emoji: contents.emoji, autoNamed: false)
        for d in contents.drafts { store.add(d, to: p.id) }
        return store.pack(p.id) ?? p
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: tool)
        proc.arguments = args
        let err = Pipe()
        proc.standardError = err
        proc.standardOutput = Pipe()
        try proc.run()
        proc.waitUntilExit()
        guard proc.terminationStatus == 0 else {
            let msg = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            throw BundleError.zip(msg.trimmingCharacters(in: .whitespacesAndNewlines))
        }
    }
}
