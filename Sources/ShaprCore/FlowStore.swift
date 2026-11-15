import Foundation

extension JSONEncoder {
    static var flow: JSONEncoder {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.sortedKeys]
        return e
    }
}

extension JSONDecoder {
    static var flow: JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }
}

/// What Flow keeps on disk: working memory, episodes and task links. Never raw observations.
public struct FlowSnapshot: Codable, Sendable, Equatable {
    public var schema = FlowSchema.version
    public var tasks: [TaskState] = []
    public var records: [MemoryRecord] = []
    public var episodes: [Episode] = []
    public var activeTaskID: UUID?
    /// "This project key belongs to this task", confirmed by the user.
    public var confirmedLinks: [String: UUID] = [:]
    public var savedAt: Date?
    public init() {}
}

/// One JSON file, written atomically on a background queue. A file that can't be read is moved
/// aside (never silently overwritten) and Flow starts with empty memory.
public final class FlowStore {
    public let url: URL?
    private let queue = DispatchQueue(label: "app.shapr.flow.store", qos: .utility)
    public private(set) var lastWrittenBytes = 0
    public private(set) var loadProblem: String?

    public init(url: URL?) { self.url = url }

    public static func defaultDirectory() -> URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base.appendingPathComponent("Shapr/Flow", isDirectory: true)
    }

    /// `readOnly`: for other processes (the MCP server), which must never move or change the file.
    public func load(readOnly: Bool = false) -> FlowSnapshot {
        guard let url, let data = try? Data(contentsOf: url) else { return FlowSnapshot() }
        do {
            let snap = try JSONDecoder.flow.decode(FlowSnapshot.self, from: data)
            if snap.schema > FlowSchema.version {
                loadProblem = "Memory was saved by a newer Shapr; it was set aside, not changed."
                if !readOnly { Self.quarantine(url) }
                return FlowSnapshot()
            }
            return snap
        } catch {
            loadProblem = "Stored memory couldn't be read; it was set aside and Shapr started fresh."
            if !readOnly { Self.quarantine(url) }
            return FlowSnapshot()
        }
    }

    /// Encodes now (callers hold bounded data), writes in the background.
    @discardableResult
    public func save(_ snap: FlowSnapshot, sync: Bool = false) -> Int {
        guard let url else { return 0 }
        guard let data = try? JSONEncoder.flow.encode(snap) else { return 0 }
        lastWrittenBytes = data.count
        let work: @Sendable () -> Void = { Self.write(data, to: url) }
        if sync { queue.sync(execute: work) } else { queue.async(execute: work) }
        return data.count
    }

    /// Waits for pending writes (tests, quitting).
    public func flush() { queue.sync {} }

    public func eraseFile() {
        guard let url else { return }
        queue.sync { try? FileManager.default.removeItem(at: url) }
    }

    static func write(_ data: Data, to url: URL) {
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: url, options: .atomic)
    }

    static func writeAtomically<T: Encodable>(_ value: T, to url: URL) {
        guard let data = try? JSONEncoder.flow.encode(value) else { return }
        write(data, to: url)
    }

    /// Keeps one unreadable copy for inspection; older ones are replaced.
    static func quarantine(_ url: URL) {
        let aside = url.deletingPathExtension().appendingPathExtension("unreadable.json")
        try? FileManager.default.removeItem(at: aside)
        try? FileManager.default.moveItem(at: url, to: aside)
    }
}
