import Foundation

/// The one object the app talks to. It owns the permission boundary: an observation reaches
/// memory only if the session is active, the app is authorized, and the read's ticket is still
/// current when its result arrives.
///
/// Not thread-safe by design: the app uses it from the main actor. Expensive reads happen
/// elsewhere; the work done here is small, bounded string processing.
public final class FlowEngine {
    public struct Settings: Codable, Equatable, Sendable {
        public var processing: ProcessingMode = .onThisMac
        public var assistance: AssistanceMode = .quiet
        public var episodeRetentionDays = 30
        /// Let local AI tools (MCP) read the current task's summary. Never raw observations.
        public var shareTaskWithAITools = true
        public init() {}
    }

    public let auth: AppAuthorizationStore
    public let session: FlowSession
    public let kernel: MemoryKernel
    public let store: FlowStore
    public let metrics: FlowMetrics
    public let suggestions = SuggestionEngine()
    public var settings: Settings { didSet { applySettings(); saveSettings() } }
    /// Called after anything the UI shows changes.
    public var onChange: () -> Void = {}
    public var onSuggestion: (Suggestion) -> Void = { _ in }
    public var onQuestion: (TaskQuestion) -> Void = { _ in }

    private let directory: URL?
    private let now: () -> Date
    private var activations: [String: Int] = [:]
    private var activationCounter = 0
    private var lastSave = Date.distantPast
    public private(set) var lastEpisodes: [Episode] = []

    public init(directory: URL?, policy: MemoryPolicy = MemoryPolicy(), now: @escaping () -> Date = Date.init) {
        self.directory = directory
        self.now = now
        let m = FlowMetrics()
        metrics = m
        store = FlowStore(url: directory?.appendingPathComponent("memory.json"))
        auth = AppAuthorizationStore(url: directory?.appendingPathComponent("permissions.json"), now: now)
        session = FlowSession(now: now)
        settings = directory.flatMap { try? JSONDecoder.flow.decode(Settings.self, from: Data(contentsOf: $0.appendingPathComponent("settings.json"))) } ?? Settings()
        kernel = MemoryKernel(snapshot: store.load(), policy: policy, metrics: m, now: now)
        kernel.isAllowed = { [unowned self] b in self.isObservable(b) }
        auth.onRevoke = { [unowned self] b in
            // Stop at once: outstanding reads become invalid and unprocessed observations from the app go.
            self.session.invalidate()
            self.kernel.dropPending(bundleID: b)
            self.metrics.count("revocations")
            self.changed()
        }
        session.onChange = { [unowned self] _ in self.changed() }
        applySettings()
    }

    public var loadProblem: String? { store.loadProblem }

    private func applySettings() {
        suggestions.mode = settings.assistance
        kernel.policy.episodeRetention = TimeInterval(max(1, settings.episodeRetentionDays)) * 24 * 3600
    }

    private func saveSettings() {
        guard let d = directory else { return }
        FlowStore.writeAtomically(settings, to: d.appendingPathComponent("settings.json"))
    }

    private func changed() { onChange() }

    // MARK: Session

    public var state: SessionState { session.state }

    public func start() {
        session.start()
        suggestions.newSession()
        metrics.count("sessions.started")
    }

    public func pause() {
        session.pause()
        kernel.consolidate()
        save(force: true)
    }

    public func resume() { session.resume() }

    /// Ends the session: tasks become episodes, temporary observations are dropped, everything is written.
    public func end() {
        let sid = session.sessionID
        let started = session.startedAt
        session.end {
            lastEpisodes = kernel.endSession(sessionID: sid, startedAt: started)
            save(force: true, sync: true)
        }
        auth.endSession()
        activations.removeAll()
        changed()
    }

    /// Sleep, screen lock: stop reading and invalidate anything in flight, without ending the session.
    public func suspendForSystem() { session.invalidate() }

    // MARK: Permission boundary

    /// The app came to the front. Returns its activation number (scopes "Allow once").
    @discardableResult
    public func noteActivated(_ bundleID: String) -> Int {
        activationCounter += 1
        activations[bundleID] = activationCounter
        return activationCounter
    }

    public func noteDeactivated(_ bundleID: String) {
        auth.noteDeactivated(bundleID: bundleID)
        activations[bundleID] = nil
    }

    /// Only the bundle identifier is consulted.
    public func decision(for bundleID: String?) -> ObservationDecision {
        switch session.state {
        case .off, .ending: return .deny(.sessionOff)
        case .paused: return .deny(.paused)
        case .active: break
        }
        return auth.decision(bundleID: bundleID, sessionID: session.sessionID, activation: bundleID.flatMap { activations[$0] })
    }

    public func isObservable(_ bundleID: String) -> Bool { decision(for: bundleID) == .observe }
    public func isBlocked(_ bundleID: String) -> Bool { auth.stored[bundleID]?.access == .denied || SensitiveApps.isNeverObserved(bundleID) }

    /// A ticket to read one app. Nil means: don't read it.
    public func ticket(for bundleID: String) -> FlowSession.Ticket? {
        guard isObservable(bundleID), let a = activations[bundleID] else { return nil }
        return session.ticket(bundleID: bundleID, activation: a)
    }

    public func setAccess(_ access: AppAccess, bundleID: String, name: String) {
        auth.set(access, bundleID: bundleID, name: name, sessionID: session.sessionID, activation: activations[bundleID])
        changed()
    }

    public func dismissPrompt(bundleID: String) { auth.dismissPrompt(bundleID: bundleID, sessionID: session.sessionID) }

    public func revoke(bundleID: String) { auth.revoke(bundleID: bundleID) }

    /// The result of a read. Thrown away unread if the ticket went stale (pause, revoke, sleep) meanwhile.
    @discardableResult
    public func submit(_ event: ObservationEvent, ticket: FlowSession.Ticket) -> MemoryKernel.IngestResult {
        guard session.isCurrent(ticket), ticket.bundleID == event.bundleID, isObservable(event.bundleID),
              activations[event.bundleID] == ticket.activation || auth.permission(for: event.bundleID)?.access != .once else {
            metrics.count("events.rejected.staleTicket")
            return .rejected("stale ticket")
        }
        var e = event
        e.sessionID = session.sessionID
        let wasPaused = kernel.activeTask?.status == .paused
        let r = kernel.ingest(e)
        auth.noteRead(bundleID: event.bundleID)
        if case .kept(let tid) = r {
            if let s = suggestions.consider(kernel: kernel, taskID: tid, wasPaused: wasPaused, now: now()) { onSuggestion(s) }
            if let q = kernel.pendingQuestion { onQuestion(q) }
            save()
            changed()
        }
        return r
    }

    // MARK: Explicit actions (the user's own)

    @discardableResult
    public func remember(_ text: String, kind: MemoryRecord.Kind? = nil, evidence: EvidenceRef? = nil,
                         newTaskTitle: String? = nil, taskID: UUID? = nil) -> MemoryRecord? {
        var ev = evidence
        ev?.sessionID = session.sessionID
        let r = kernel.remember(text, kind: kind, evidence: ev, newTaskTitle: newTaskTitle, taskID: taskID)
        save(force: true)
        changed()
        return r
    }

    public func answer(_ a: TaskAnswer) { kernel.answer(a); save(force: true); changed() }

    public func edit(_ f: (MemoryKernel) -> Void) { f(kernel); save(force: true); changed() }

    // MARK: Reading memory

    public var activeTask: TaskState? { kernel.activeTask }

    public func summary(for taskID: UUID? = nil) -> TaskSummary? {
        guard let t = (taskID ?? kernel.snap.activeTaskID).flatMap(kernel.task) else { return nil }
        var rs = kernel.records(for: t.id)
        if rs.isEmpty, let ep = kernel.episodes.last(where: { $0.taskID == t.id }) { rs = ep.records }
        return TaskSummary.build(task: t, records: rs, now: now())
    }

    public func resumeCandidate() -> TaskSummary? { TaskSummary.resumeCandidate(kernel: kernel, now: now()) }

    public func context(for query: String, budget: Int = 4000) -> ContextPackage {
        let started = DispatchTime.now()
        defer { metrics.time("retrieve", since: started) }
        return MemoryRetrieval.retrieve(query: query, kernel: kernel, taskID: kernel.snap.activeTaskID,
                                        isBlocked: isBlocked, budget: budget, now: now())
    }

    public func compare(selection: String, paths: [String]) -> ScenarioComparison {
        let rs = kernel.snap.activeTaskID.map { kernel.records(for: $0) } ?? []
        return ScenarioExplorer.compare(selection: selection, paths: paths, records: rs)
    }

    public func continueTask(_ id: UUID) {
        kernel.activate(taskID: id)
        save(force: true)
        changed()
    }

    // MARK: Deletion

    @discardableResult public func deleteData(fromApp bundleID: String) -> MemoryKernel.PurgeReport { mutate { $0.purgeApp(bundleID) } }
    @discardableResult public func deleteSession(_ id: UUID) -> MemoryKernel.PurgeReport { mutate { $0.purgeSession(id) } }
    @discardableResult public func deleteTask(_ id: UUID) -> [String] { mutate { $0.deleteTask(id) } }
    public func clearTemporary() { mutate { $0.clearImmediate() } }
    @discardableResult public func deleteAll() -> [String] {
        let files = mutate { $0.deleteAll() }
        store.eraseFile()
        return files
    }

    private func mutate<T>(_ f: (MemoryKernel) -> T) -> T {
        let r = f(kernel)
        save(force: true, sync: true)
        changed()
        return r
    }

    // MARK: Persistence

    /// Writes at most every 30 seconds during work, and immediately after explicit actions.
    public func save(force: Bool = false, sync: Bool = false) {
        guard force || (kernel.dirty && now().timeIntervalSince(lastSave) > 30) else { return }
        var snap = kernel.snap
        snap.savedAt = now()
        store.save(snap, sync: sync)
        kernel.markSaved()
        lastSave = now()
    }

    public var storedBytes: Int { store.lastWrittenBytes }
}
