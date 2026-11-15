import Foundation

// Shapr Flow: the data model.
//
// Everything here is plain Foundation so it builds and is tested on any platform. The macOS app
// reads windows and draws panels; this module decides what may be observed, what is worth
// remembering, and what can be said about it.

public enum FlowSchema {
    /// Bumped when the stored memory format changes in a way older builds can't read.
    public static let version = 1
}

// MARK: - Session

public enum SessionState: String, Codable, Sendable {
    /// Nothing is observed. The default at every launch.
    case off
    /// Only explicitly authorized apps are observed.
    case active
    /// Observation stopped; nothing new is recorded until resumed.
    case paused
    /// Flushing compact working state, then off.
    case ending
}

// MARK: - App authorization (Shapr's own, narrower than macOS permissions)

public enum AppAccess: String, Codable, Sendable, CaseIterable {
    /// Never observed. Always wins over any other rule.
    case denied
    /// Until the user leaves the app (this activation only). Never stored on disk.
    case once
    /// Until the working session ends. Never stored on disk.
    case session
    /// Every session, until revoked.
    case always

    public var label: String {
        switch self {
        case .denied: return "Blocked"
        case .once: return "Allowed once"
        case .session: return "This session"
        case .always: return "Always allowed"
        }
    }
}

public struct AppPermission: Codable, Sendable, Equatable {
    public var bundleID: String
    public var displayName: String
    public var access: AppAccess
    public var grantedAt: Date
    /// Hard expiry for `once` and `session` grants, as a backstop to their scope ending.
    public var expiresAt: Date?
    /// The session a `session`/`once` grant belongs to.
    public var sessionID: UUID?
    /// The app activation an `once` grant belongs to.
    public var activation: Int?
    /// Last time the policy evaluated this app and allowed a read.
    public var lastAllowedRead: Date?

    public init(bundleID: String, displayName: String, access: AppAccess, grantedAt: Date,
                expiresAt: Date? = nil, sessionID: UUID? = nil, activation: Int? = nil) {
        self.bundleID = bundleID
        self.displayName = displayName
        self.access = access
        self.grantedAt = grantedAt
        self.expiresAt = expiresAt
        self.sessionID = sessionID
        self.activation = activation
    }

    public var isExcluded: Bool { access == .denied }
}

// MARK: - Provenance: how do we know this?

/// Ordered from strongest to weakest. Compression may never move a statement up this list.
public enum Provenance: String, Codable, Sendable, CaseIterable, Comparable {
    /// The user confirmed it in Shapr ("Yes, that's right").
    case userConfirmed
    /// The user said or wrote it (Threads, a typed goal, a pinned note).
    case userStated
    /// Read directly from an authorized app (a window title, an error line, a page address).
    case observed
    /// Derived by Shapr from observations (a task title, a grouping).
    case inferred
    /// A guess that needs checking.
    case hypothesis

    private var rank: Int { Self.allCases.firstIndex(of: self)! }
    public static func < (a: Provenance, b: Provenance) -> Bool { a.rank > b.rank } // weaker < stronger

    public var label: String {
        switch self {
        case .userConfirmed: return "confirmed"
        case .userStated: return "you said"
        case .observed: return "observed"
        case .inferred: return "inferred"
        case .hypothesis: return "unverified"
        }
    }

    public var isFact: Bool { self == .userConfirmed || self == .userStated || self == .observed }
}

/// Where a piece of memory came from: enough to show it, check it, and delete it.
public struct EvidenceRef: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable { case window, page, document, capture, note, command }
    public var id: UUID
    public var kind: Kind
    public var bundleID: String
    public var appName: String
    public var title: String?
    /// A web address or a file path.
    public var location: String?
    public var at: Date
    /// A short quote (at most 240 characters), already scrubbed of secrets.
    public var excerpt: String?
    public var sessionID: UUID?

    public init(id: UUID = UUID(), kind: Kind, bundleID: String, appName: String, title: String? = nil,
                location: String? = nil, at: Date, excerpt: String? = nil, sessionID: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.bundleID = bundleID
        self.appName = appName
        self.title = title
        self.location = location
        self.at = at
        self.excerpt = excerpt.map { String($0.prefix(240)) }
        self.sessionID = sessionID
    }
}

// MARK: - Observations (Level 1: immediate, in RAM only)

public struct ObservationEvent: Sendable, Identifiable {
    public enum Kind: String, Codable, Sendable {
        /// App or window came to the front: title, document, page address.
        case focus
        /// Salient lines read from an authorized window (errors, commands).
        case content
        /// The user circled or selected something and acted on it.
        case capture
        /// The user typed or said something to Shapr.
        case note
    }

    public var id = UUID()
    public var at: Date
    public var sessionID: UUID?
    public var kind: Kind
    public var bundleID: String
    public var appName: String
    public var windowTitle: String?
    /// A file the window shows (AXDocument), as a path.
    public var documentPath: String?
    public var url: String?
    /// The project folder or repository the app layer found for this window, if any.
    public var projectHint: String?
    /// Only the salient lines (errors, shell commands) for `content`; the user's text for `capture`/`note`.
    /// Raw window text never reaches this type.
    public var text: String?

    public init(at: Date, sessionID: UUID?, kind: Kind, bundleID: String, appName: String, windowTitle: String? = nil,
                documentPath: String? = nil, url: String? = nil, projectHint: String? = nil, text: String? = nil) {
        self.at = at
        self.sessionID = sessionID
        self.kind = kind
        self.bundleID = bundleID
        self.appName = appName
        self.windowTitle = windowTitle
        self.documentPath = documentPath
        self.url = url
        self.projectHint = projectHint
        self.text = text
    }

    /// Same app, same window, same page, same content: the same observation.
    public var fingerprint: UInt64 {
        var h = FNV1a()
        h.add(kind.rawValue); h.add(bundleID); h.add(windowTitle ?? ""); h.add(documentPath ?? "")
        h.add(Text.stripQuery(url) ?? ""); h.add(Text.normalized(text ?? ""))
        return h.value
    }

    /// Rough size for the immediate-memory byte budget.
    public var approximateBytes: Int {
        let parts: [String?] = [windowTitle, documentPath, url, text]
        return parts.reduce(128) { $0 + ($1?.utf8.count ?? 0) }
    }

    func evidence(kind k: EvidenceRef.Kind? = nil, excerpt: String? = nil) -> EvidenceRef {
        let inferredKind: EvidenceRef.Kind = url != nil ? .page : documentPath != nil ? .document : .window
        return EvidenceRef(id: id, kind: k ?? (kind == .capture ? .capture : kind == .note ? .note : inferredKind),
                           bundleID: bundleID, appName: appName, title: windowTitle,
                           location: Text.stripQuery(url) ?? documentPath, at: at, excerpt: excerpt, sessionID: sessionID)
    }
}

// MARK: - Working, episodic and long-term memory

public enum MemoryLevel: String, Codable, Sendable {
    /// Level 2: the active task's state.
    case working
    /// Level 3: milestones kept from an ended session.
    case episodic
    /// Level 4: user-approved knowledge (pinned). Never forgotten automatically.
    case knowledge
}

public struct MemoryRecord: Codable, Sendable, Identifiable, Equatable {
    public enum Kind: String, Codable, Sendable, CaseIterable {
        case goal, instruction, decision, attempt, error, openQuestion, nextStep, source, note

        public var heading: String {
            switch self {
            case .goal: return "Goal"
            case .instruction: return "Your rules"
            case .decision: return "Decisions"
            case .attempt: return "Tried"
            case .error: return "Errors seen"
            case .openQuestion: return "Open questions"
            case .nextStep: return "Next step"
            case .source: return "Sources"
            case .note: return "Notes"
            }
        }
    }

    public var id = UUID()
    public var taskID: UUID?
    public var kind: Kind
    public var text: String
    public var provenance: Provenance
    public var evidence: [EvidenceRef]
    public var level: MemoryLevel = .working
    public var pinned = false
    public var created: Date
    public var updated: Date
    /// Last time this was observed again (errors that keep showing up).
    public var lastSeen: Date
    public var occurrences = 1
    /// Set when newer information replaced this; kept so history stays traceable.
    public var supersededBy: UUID?
    /// Normalized form used for de-duplication.
    public var key: UInt64

    public init(taskID: UUID?, kind: Kind, text: String, provenance: Provenance, evidence: [EvidenceRef], at: Date, pinned: Bool = false) {
        self.taskID = taskID
        self.kind = kind
        self.text = text
        self.provenance = provenance
        self.evidence = evidence
        self.pinned = pinned
        self.level = pinned ? .knowledge : .working
        self.created = at
        self.updated = at
        self.lastSeen = at
        self.key = MemoryRecord.key(kind: kind, text: text)
    }

    public static func key(kind: Kind, text: String) -> UInt64 {
        var h = FNV1a()
        h.add(kind.rawValue)
        h.add(Text.normalized(text, maskNumbers: kind == .error))
        return h.value
    }

    public var apps: Set<String> { Set(evidence.map(\.bundleID)) }
    public var isCurrent: Bool { supersededBy == nil }
}

public struct SourceRef: Codable, Sendable, Hashable {
    public var title: String
    public var location: String?
    public var bundleID: String
    public var appName: String
    public var lastSeen: Date
}

public struct TaskState: Codable, Sendable, Identifiable, Equatable {
    public enum Status: String, Codable, Sendable { case active, paused, done }

    public var id = UUID()
    public var version = 1
    public var title: String
    public var titleProvenance: Provenance
    /// The evidence the title was inferred from, so deleting that evidence also resets the title.
    public var titleEvidence: UUID?
    public var status: Status = .active
    public var created: Date
    public var lastActivity: Date
    /// Bundle IDs that contributed to this task.
    public var apps: [String] = []
    /// Repositories, project folders and file names that identify the task.
    public var projectKeys: [String] = []
    /// Most frequent terms (bounded) for matching new activity.
    public var keywords: [String: Int] = [:]
    public var sources: [SourceRef] = []
    /// A context pack this task is linked to (for checkpoints and handoffs).
    public var packID: UUID?
    /// The user confirmed this grouping at least once.
    public var confirmed = false
    /// Checkpoint files Shapr Flow wrote for this task, so deleting the task removes them too.
    public var writtenCheckpoints: [String] = []

    public init(title: String, titleProvenance: Provenance, at: Date) {
        self.title = title
        self.titleProvenance = titleProvenance
        self.created = at
        self.lastActivity = at
    }
}

/// A finished stretch of work, kept for "Continue where you left off".
public struct Episode: Codable, Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var taskID: UUID
    public var title: String
    public var sessionID: UUID?
    public var startedAt: Date
    public var endedAt: Date
    /// Copies of the records that mattered, so the episode survives working-memory eviction.
    public var records: [MemoryRecord]
    public var pinned = false
}

// MARK: - Policy and budgets

public struct MemoryPolicy: Codable, Sendable, Equatable {
    /// Level 1 (RAM only).
    public var immediateMaxEvents = 200
    public var immediateMaxBytes = 256 * 1024
    public var immediateTTL: TimeInterval = 20 * 60
    /// Level 2.
    public var maxRecordsPerTask = 60
    public var maxRecordsPerKind = 12
    public var maxEvidencePerRecord = 5
    public var maxSourcesPerTask = 20
    public var maxKeywordsPerTask = 40
    public var maxTasks = 30
    /// Level 3.
    public var episodeRetention: TimeInterval = 30 * 24 * 3600
    public var maxEpisodes = 60
    /// The whole stored file.
    public var maxStoredBytes = 1_500_000
    /// Consolidate after this many accepted observations (also on idle, pause and end).
    public var consolidateEvery = 25
    /// Text limits.
    public var maxRecordText = 400

    public init() {}
}

public enum ProcessingMode: String, Codable, Sendable, CaseIterable {
    /// Flow content is processed on this Mac only. Claude is never called for Flow features.
    case onThisMac
    /// Claude may be used, but only when the user asks, after showing what will be sent.
    case askBeforeCloud

    public var label: String {
        switch self {
        case .onThisMac: return "AI on this Mac only"
        case .askBeforeCloud: return "Claude when I ask"
        }
    }
}

public enum AssistanceMode: String, Codable, Sendable, CaseIterable {
    case quiet, balanced, proactive

    public var label: String {
        switch self {
        case .quiet: return "Quiet"
        case .balanced: return "Balanced"
        case .proactive: return "Proactive"
        }
    }

    public var detail: String {
        switch self {
        case .quiet: return "Never interrupts. Helps when you ask."
        case .balanced: return "Rarely: only when an earlier error comes back."
        case .proactive: return "Also offers to pick up a paused task when you return to it."
        }
    }
}
