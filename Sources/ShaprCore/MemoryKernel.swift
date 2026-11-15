import Foundation

// MARK: - Level 1: immediate memory (RAM only, bounded, expiring)

public struct ImmediateMemory: Sendable {
    public private(set) var events: [ObservationEvent] = []
    private var seen: [UInt64: Date] = [:]
    public private(set) var bytes = 0

    /// False when the same observation was already made recently (it only refreshes the time).
    mutating func insert(_ e: ObservationEvent, policy: MemoryPolicy) -> Bool {
        let f = e.fingerprint
        if let last = seen[f], e.at.timeIntervalSince(last) < policy.immediateTTL {
            seen[f] = e.at
            return false
        }
        seen[f] = e.at
        events.append(e)
        bytes += e.approximateBytes
        while events.count > policy.immediateMaxEvents || bytes > policy.immediateMaxBytes, !events.isEmpty {
            bytes -= events.removeFirst().approximateBytes
        }
        return true
    }

    mutating func expire(now: Date, ttl: TimeInterval) {
        removeAll { now.timeIntervalSince($0.at) > ttl }
        seen = seen.filter { now.timeIntervalSince($0.value) <= ttl }
    }

    mutating func removeAll(where match: (ObservationEvent) -> Bool) {
        let gone = events.filter(match)
        guard !gone.isEmpty else { return }
        events.removeAll(where: match)
        for g in gone { seen[g.fingerprint] = nil }
        bytes = events.reduce(0) { $0 + $1.approximateBytes }
    }

    mutating func clear() { events.removeAll(); seen.removeAll(); bytes = 0 }

    public var latest: ObservationEvent? { events.last }
}

// MARK: - Task grouping

/// "Is this part of your API project?" Asked rarely, never twice about the same thing.
public struct TaskQuestion: Sendable, Identifiable, Equatable {
    public var id = UUID()
    public var taskID: UUID
    public var taskTitle: String
    public var about: String
    public var keys: [String]
    public var eventID: UUID
    public var bundleID: String
}

public enum TaskAnswer: Sendable { case yes, separateTask, ignore }

struct TaskMatcher {
    enum Outcome: Equatable { case attach(UUID), ask(UUID), create, none }

    static func score(_ e: ObservationEvent, keys: [String], stems: Set<String>, task: TaskState,
                      active: UUID?, latestError: Set<String>) -> Double {
        var s = 0.0
        let tk = Set(task.projectKeys)
        let projects = Set(keys.filter { $0.hasPrefix("proj:") || $0.hasPrefix("repo:") })
        let taskProjects = tk.filter { $0.hasPrefix("proj:") || $0.hasPrefix("repo:") }
        if !projects.isDisjoint(with: taskProjects) { s += 3 }
        else if !projects.isEmpty && !taskProjects.isEmpty { s -= 3 } // a different project: never merge on words alone
        let others = Set(keys).subtracting(projects)
        if !others.isDisjoint(with: tk) { s += 2 }
        let taskStems = Set(task.keywords.keys.map { String($0.prefix(6)) })
        let o = FlowText.overlap(stems, taskStems)
        if o.shared >= 2 && o.score >= 0.34 { s += 2 } else if o.shared >= 1 && o.score >= 0.2 { s += 1 }
        // Continuity is measured from the observation itself, not the wall clock.
        let continuous = task.id == active && abs(e.at.timeIntervalSince(task.lastActivity)) < 10 * 60
        if continuous { s += 1 }
        // Looking something up right after an error: does it share words with that error?
        let shared = stems.intersection(latestError).count
        if shared >= 2 || (shared >= 1 && continuous) { s += 1 }
        return s
    }
}

// MARK: - The kernel

/// Holds working memory and decides what an observation changes. Deterministic: the same events
/// always give the same memory. It never turns a guess into a fact: every record keeps the
/// provenance it was created with, and merging only combines records of equal provenance.
public final class MemoryKernel {
    public var policy: MemoryPolicy
    public private(set) var snap: FlowSnapshot
    public private(set) var immediate = ImmediateMemory()
    public private(set) var pendingQuestion: TaskQuestion?
    /// Defence in depth: the kernel re-checks authorization itself before accepting anything.
    public var isAllowed: (String) -> Bool = { _ in false }
    public let metrics: FlowMetrics
    public private(set) var dirty = false
    private let now: () -> Date
    private var acceptedSinceConsolidation = 0
    private var askedKeys: Set<String> = []
    private var ignoredKeys: Set<String> = []
    private var lastAsk: Date?
    /// Tasks touched in the current session (for episodes).
    private var touched: Set<UUID> = []

    public init(snapshot: FlowSnapshot = FlowSnapshot(), policy: MemoryPolicy = MemoryPolicy(),
                metrics: FlowMetrics = FlowMetrics(), now: @escaping () -> Date = Date.init) {
        self.snap = snapshot
        self.policy = policy
        self.metrics = metrics
        self.now = now
    }

    public var tasks: [TaskState] { snap.tasks }
    public var records: [MemoryRecord] { snap.records }
    public var episodes: [Episode] { snap.episodes }
    public var activeTask: TaskState? { snap.activeTaskID.flatMap(task) }
    public func task(_ id: UUID) -> TaskState? { snap.tasks.first { $0.id == id } }
    public func records(for taskID: UUID, includeSuperseded: Bool = false) -> [MemoryRecord] {
        snap.records.filter { $0.taskID == taskID && (includeSuperseded || $0.isCurrent) }
    }
    public func markSaved() { dirty = false }

    // MARK: Ingest

    public enum IngestResult: Equatable { case rejected(String), duplicate, kept(UUID?) }

    /// Observe → validate permission → filter → deduplicate → relevance → task state → (consolidate).
    @discardableResult
    public func ingest(_ raw: ObservationEvent) -> IngestResult {
        let started = DispatchTime.now()
        defer { metrics.time("ingest", since: started) }
        metrics.count("events.seen")
        guard isAllowed(raw.bundleID) else { metrics.count("events.rejected.permission"); return .rejected("not authorized") }
        guard !SensitiveApps.titleIsPrivate(raw.windowTitle) else { metrics.count("events.rejected.private"); return .rejected("private window") }

        var e = raw
        if let t = e.text {
            let s = Redactor.scrub(t)
            e.text = s.text
            if s.count > 0 { metrics.count("redactions", by: s.count) }
        }
        if let t = e.windowTitle { e.windowTitle = Redactor.scrub(t).text }
        e.url = FlowText.stripQuery(e.url)

        guard immediate.insert(e, policy: policy) else { metrics.count("events.duplicate"); return .duplicate }

        let keys = ProjectKeys.from(title: e.windowTitle, url: e.url, documentPath: e.documentPath,
                                    projectHint: e.projectHint, appName: e.appName)
        let lines = e.kind == .content ? Salience.lines(in: e.text ?? "") : []
        let errors = lines.filter { $0.kind == .error }
        let termSource = [e.windowTitle ?? "", errors.map(\.text).joined(separator: " ")].joined(separator: " ")
        let stems = FlowText.stems(termSource)

        let taskID: UUID?
        switch outcome(for: e, keys: keys, stems: stems, hasErrors: !errors.isEmpty) {
        case .attach(let id): taskID = id
        case .ask(let id):
            maybeAsk(about: e, keys: keys, taskID: id)
            taskID = nil
        case .create:
            taskID = createTask(from: e, keys: keys, errors: errors)
        case .none: taskID = nil
        }
        guard let tid = taskID, let ti = snap.tasks.firstIndex(where: { $0.id == tid }) else {
            metrics.count("events.unassigned")
            return .kept(nil)
        }

        // Task state
        touched.insert(tid)
        snap.activeTaskID = tid
        var t = snap.tasks[ti]
        t.lastActivity = e.at
        t.status = .active
        if !t.apps.contains(e.bundleID) { t.apps.append(e.bundleID) }
        for k in keys where !t.projectKeys.contains(k) { t.projectKeys.append(k) }
        if t.projectKeys.count > 16 { t.projectKeys.removeFirst(t.projectKeys.count - 16) }
        for term in FlowText.terms(termSource, limit: 60) { t.keywords[term, default: 0] += 1 }
        if (e.url != nil || e.documentPath != nil), let title = e.windowTitle?.trimmingCharacters(in: .whitespaces), !title.isEmpty {
            let loc = e.url ?? e.documentPath
            if let i = t.sources.firstIndex(where: { $0.location == loc }) {
                t.sources[i].lastSeen = e.at
                t.sources[i].title = title
            } else {
                t.sources.append(SourceRef(title: title, location: loc, bundleID: e.bundleID, appName: e.appName, lastSeen: e.at))
            }
        }
        snap.tasks[ti] = t

        // Records: only what changes the task's state.
        for l in lines {
            switch l.kind {
            case .error:
                upsert(taskID: tid, kind: .error, text: l.text, provenance: .observed,
                       evidence: e.evidence(excerpt: l.text))
            case .command where Salience.looksLikeAttempt(l.text):
                upsert(taskID: tid, kind: .attempt, text: "Ran `\(l.text)`", provenance: .observed,
                       evidence: e.evidence(kind: .command, excerpt: l.text))
            case .command: break
            }
        }
        if let first = errors.first, snap.tasks[ti].titleProvenance == .inferred, snap.tasks[ti].title.hasPrefix("Work on ") {
            snap.tasks[ti].title = Self.title(fromError: first.text)
            snap.tasks[ti].titleEvidence = e.id
        }
        dirty = true
        acceptedSinceConsolidation += 1
        if acceptedSinceConsolidation >= policy.consolidateEvery { consolidate() }
        metrics.count("events.kept")
        return .kept(tid)
    }

    private func outcome(for e: ObservationEvent, keys: [String], stems: Set<String>, hasErrors: Bool) -> TaskMatcher.Outcome {
        if keys.contains(where: ignoredKeys.contains) { return .none }
        if let linked = keys.lazy.compactMap({ self.snap.confirmedLinks[$0] }).first, task(linked) != nil { return .attach(linked) }
        let scored = snap.tasks.filter { $0.status != .done }.map { t -> (UUID, Double) in
            let err = snap.records.filter { $0.taskID == t.id && $0.kind == .error && $0.isCurrent }.max { $0.lastSeen < $1.lastSeen }
            return (t.id, TaskMatcher.score(e, keys: keys, stems: stems, task: t, active: snap.activeTaskID,
                                            latestError: err.map { FlowText.stems($0.text) } ?? []))
        }
        .sorted { $0.1 > $1.1 }
        if let best = scored.first {
            if best.1 >= 3 { return .attach(best.0) }
            if best.1 >= 2, hasErrors || e.url != nil { return .ask(best.0) }
        }
        let hasProject = keys.contains { $0.hasPrefix("proj:") || $0.hasPrefix("repo:") }
        if hasProject || hasErrors { return .create }
        return .none
    }

    private func maybeAsk(about e: ObservationEvent, keys: [String], taskID: UUID) {
        let t = now()
        let k = keys.first ?? (e.windowTitle.map { "title:" + FlowText.normalized($0) } ?? e.bundleID)
        guard pendingQuestion == nil, !askedKeys.contains(k), lastAsk.map({ t.timeIntervalSince($0) > 10 * 60 }) ?? true,
              let task = task(taskID) else { return }
        askedKeys.insert(k)
        lastAsk = t
        pendingQuestion = TaskQuestion(taskID: taskID, taskTitle: task.title, about: e.windowTitle ?? e.appName,
                                       keys: keys.isEmpty ? [k] : keys, eventID: e.id, bundleID: e.bundleID)
    }

    public func answer(_ a: TaskAnswer) {
        guard let q = pendingQuestion else { return }
        pendingQuestion = nil
        let ev = immediate.events.first { $0.id == q.eventID }
        switch a {
        case .yes:
            for k in q.keys { snap.confirmedLinks[k] = q.taskID }
            if let i = snap.tasks.firstIndex(where: { $0.id == q.taskID }) { snap.tasks[i].confirmed = true }
            if let ev { immediate.removeAll { $0.id == ev.id }; ingest(ev) }
        case .separateTask:
            if let ev {
                let id = createTask(from: ev, keys: q.keys, errors: [])
                for k in q.keys { snap.confirmedLinks[k] = id }
                immediate.removeAll { $0.id == ev.id }
                ingest(ev)
            }
        case .ignore:
            for k in q.keys { ignoredKeys.insert(k) }
        }
        dirty = true
    }

    @discardableResult
    private func createTask(from e: ObservationEvent, keys: [String], errors: [Salience.Line]) -> UUID {
        let project = keys.first { $0.hasPrefix("proj:") }.map { String($0.dropFirst(5)) }
            ?? keys.first { $0.hasPrefix("repo:") }.map { String($0.split(separator: "/").last ?? "") }
        let title = errors.first.map { Self.title(fromError: $0.text) } ?? "Work on \(project ?? e.appName)"
        var t = TaskState(title: title, titleProvenance: .inferred, at: e.at)
        t.titleEvidence = e.id
        snap.tasks.append(t)
        snap.activeTaskID = t.id
        metrics.count("tasks.created")
        return t.id
    }

    /// "Error: connect ECONNREFUSED 127.0.0.1:5432" → "Fix: connect ECONNREFUSED 127.0.0.1:5432". Always marked inferred.
    static func title(fromError line: String) -> String {
        var s = line
        for p in ["Error:", "error:", "ERROR:", "Exception:", "fatal:", "FATAL:", "Uncaught", "Unhandled"] where s.hasPrefix(p) {
            s = String(s.dropFirst(p.count))
        }
        return "Fix: " + FlowText.clip(s.trimmingCharacters(in: .whitespaces), 56)
    }

    // MARK: Records

    @discardableResult
    func upsert(taskID: UUID?, kind: MemoryRecord.Kind, text: String, provenance: Provenance,
                evidence: EvidenceRef?, pinned: Bool = false) -> UUID {
        let clean = FlowText.clip(Redactor.scrub(text).text, policy.maxRecordText)
        let key = MemoryRecord.key(kind: kind, text: clean)
        let t = evidence?.at ?? now()
        if let i = snap.records.firstIndex(where: { $0.taskID == taskID && $0.key == key && $0.isCurrent }) {
            var r = snap.records[i]
            r.occurrences += 1
            r.lastSeen = max(r.lastSeen, t)
            r.updated = now()
            if provenance > r.provenance { r.provenance = provenance } // only new, stronger evidence upgrades it
            if pinned { r.pinned = true; r.level = .knowledge }
            if let evidence, !r.evidence.contains(where: { $0.id == evidence.id }) {
                r.evidence.append(evidence)
                if r.evidence.count > policy.maxEvidencePerRecord {
                    // Keep the first sighting and the most recent ones.
                    r.evidence = [r.evidence[0]] + r.evidence.suffix(policy.maxEvidencePerRecord - 1)
                }
            }
            snap.records[i] = r
            dirty = true
            return r.id
        }
        let r = MemoryRecord(taskID: taskID, kind: kind, text: clean, provenance: provenance,
                             evidence: evidence.map { [$0] } ?? [], at: t, pinned: pinned)
        snap.records.append(r)
        metrics.count("records.created")
        dirty = true
        return r.id
    }

    /// Threads: "This is important to my current task. Remember it."
    /// The user's own action, so it is `userStated` and pinned; its kind comes from its wording unless given.
    @discardableResult
    public func remember(_ text: String, kind: MemoryRecord.Kind? = nil, evidence: EvidenceRef?,
                         newTaskTitle: String? = nil, taskID: UUID? = nil) -> MemoryRecord? {
        let body = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !body.isEmpty else { return nil }
        if let b = evidence?.bundleID, b != "app.shapr.Shapr", evidence?.kind != .capture, !isAllowed(b) { return nil }
        let tid: UUID
        if let title = newTaskTitle?.trimmingCharacters(in: .whitespacesAndNewlines), !title.isEmpty {
            var t = TaskState(title: title, titleProvenance: .userStated, at: now())
            t.confirmed = true
            snap.tasks.append(t)
            tid = t.id
        } else if let id = taskID ?? snap.activeTaskID, task(id) != nil {
            tid = id
        } else {
            var t = TaskState(title: FlowText.clip(FlowText.firstLine(body), 48), titleProvenance: .inferred, at: now())
            t.titleEvidence = evidence?.id
            snap.tasks.append(t)
            tid = t.id
        }
        snap.activeTaskID = tid
        touched.insert(tid)
        let k = kind ?? Salience.classify(body)
        if k == .goal || k == .nextStep { supersedeCurrent(kind: k, taskID: tid) }
        let id = upsert(taskID: tid, kind: k, text: body, provenance: .userStated, evidence: evidence, pinned: true)
        if let i = snap.tasks.firstIndex(where: { $0.id == tid }) {
            snap.tasks[i].lastActivity = now()
            for term in FlowText.terms(body, limit: 40) { snap.tasks[i].keywords[term, default: 0] += 1 }
            if let ev = evidence, let loc = ev.location, !snap.tasks[i].sources.contains(where: { $0.location == loc }) {
                snap.tasks[i].sources.append(SourceRef(title: ev.title ?? ev.appName, location: loc, bundleID: ev.bundleID,
                                                       appName: ev.appName, lastSeen: ev.at))
            }
        }
        return snap.records.first { $0.id == id }
    }

    private func supersedeCurrent(kind: MemoryRecord.Kind, taskID: UUID) {
        let marker = UUID()
        for i in snap.records.indices where snap.records[i].taskID == taskID && snap.records[i].kind == kind && snap.records[i].isCurrent {
            snap.records[i].supersededBy = marker
        }
    }

    public func setGoal(_ text: String, taskID: UUID) { remember(text, kind: .goal, evidence: nil, taskID: taskID) }

    public func rename(taskID: UUID, to title: String) {
        guard let i = snap.tasks.firstIndex(where: { $0.id == taskID }), let t = title.trimmingCharacters(in: .whitespaces).nilIfEmpty else { return }
        snap.tasks[i].title = t
        snap.tasks[i].titleProvenance = .userStated
        snap.tasks[i].titleEvidence = nil
        dirty = true
    }

    /// The user says a record is right. Only the user can make something `userConfirmed`.
    public func confirm(recordID: UUID) { edit(recordID) { $0.provenance = .userConfirmed } }
    public func pin(recordID: UUID, _ on: Bool = true) { edit(recordID) { $0.pinned = on; $0.level = on ? .knowledge : .working } }
    /// Outdated, but kept so the history stays traceable.
    public func supersede(recordID: UUID) { edit(recordID) { $0.supersededBy = $0.supersededBy ?? UUID() } }
    public func deleteRecord(_ id: UUID) {
        snap.records.removeAll { $0.id == id }
        for i in snap.episodes.indices { snap.episodes[i].records.removeAll { $0.id == id } }
        dirty = true
    }

    private func edit(_ id: UUID, _ f: (inout MemoryRecord) -> Void) {
        guard let i = snap.records.firstIndex(where: { $0.id == id }) else { return }
        f(&snap.records[i])
        snap.records[i].updated = now()
        dirty = true
    }

    public func activate(taskID: UUID) {
        guard let i = snap.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        snap.tasks[i].status = .active
        snap.tasks[i].lastActivity = now()
        snap.activeTaskID = taskID
        touched.insert(taskID)
        dirty = true
    }

    public func link(taskID: UUID, packID: UUID?) {
        guard let i = snap.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        snap.tasks[i].packID = packID
        dirty = true
    }

    public func noteCheckpoint(_ path: String, taskID: UUID) {
        guard let i = snap.tasks.firstIndex(where: { $0.id == taskID }) else { return }
        snap.tasks[i].writtenCheckpoints.append(path)
        dirty = true
    }

    // MARK: Consolidation and budgets

    /// Expire, merge, and trim to budget. Runs on thresholds, idle, pause and session end — never continuously.
    public func consolidate() {
        let started = DispatchTime.now()
        defer { metrics.time("consolidate", since: started) }
        acceptedSinceConsolidation = 0
        let t = now()
        immediate.expire(now: t, ttl: policy.immediateTTL)
        mergeNearDuplicates()
        trimRecords()
        trimTasks(now: t)
        snap.episodes.removeAll { !$0.pinned && t.timeIntervalSince($0.endedAt) > policy.episodeRetention }
        if snap.episodes.count > policy.maxEpisodes {
            let keep = snap.episodes.sorted { ($0.pinned ? 1 : 0, $0.endedAt) > ($1.pinned ? 1 : 0, $1.endedAt) }.prefix(policy.maxEpisodes)
            snap.episodes = snap.episodes.filter { e in keep.contains { $0.id == e.id } }
        }
        // The whole file stays under budget: drop the oldest unpinned episodes first.
        while let size = try? JSONEncoder.flow.encode(snap).count, size > policy.maxStoredBytes,
              let oldest = snap.episodes.filter({ !$0.pinned }).min(by: { $0.endedAt < $1.endedAt }) {
            snap.episodes.removeAll { $0.id == oldest.id }
        }
        dirty = true
        metrics.count("consolidations")
    }

    private func mergeNearDuplicates() {
        var out: [MemoryRecord] = []
        for r in snap.records {
            let stems = FlowText.stems(r.text)
            if r.kind != .source, r.isCurrent, let i = out.firstIndex(where: { o in
                o.taskID == r.taskID && o.kind == r.kind && o.provenance == r.provenance && o.isCurrent &&
                    { let x = FlowText.overlap(stems, FlowText.stems(o.text)); return x.score >= 0.85 && x.shared >= 3 }()
            }) {
                out[i].occurrences += r.occurrences
                out[i].lastSeen = max(out[i].lastSeen, r.lastSeen)
                out[i].pinned = out[i].pinned || r.pinned
                for ev in r.evidence where !out[i].evidence.contains(where: { $0.id == ev.id }) { out[i].evidence.append(ev) }
                if out[i].evidence.count > policy.maxEvidencePerRecord {
                    out[i].evidence = [out[i].evidence[0]] + out[i].evidence.suffix(policy.maxEvidencePerRecord - 1)
                }
                metrics.count("records.merged")
            } else {
                out.append(r)
            }
        }
        snap.records = out
    }

    /// Lowest value goes first: superseded, then guesses, then old one-off observations. Pinned never goes.
    private func utility(_ r: MemoryRecord) -> Double {
        if r.pinned { return .infinity }
        var u = Double(min(r.occurrences, 10))
        switch r.provenance {
        case .userConfirmed, .userStated: u += 20
        case .observed: u += 5
        case .inferred: u += 2
        case .hypothesis: u += 0
        }
        if !r.isCurrent { u -= 30 }
        u -= now().timeIntervalSince(r.lastSeen) / 3600 / 24 // a point a day
        return u
    }

    private func trimRecords() {
        var keep: [MemoryRecord] = []
        for (_, group) in Dictionary(grouping: snap.records, by: { $0.taskID }) {
            var g: [MemoryRecord] = []
            for (_, kindGroup) in Dictionary(grouping: group, by: \.kind) {
                g += kindGroup.sorted { utility($0) > utility($1) }.enumerated()
                    .filter { $0.offset < policy.maxRecordsPerKind || $0.element.pinned }.map(\.element)
            }
            g = g.sorted { utility($0) > utility($1) }.enumerated()
                .filter { $0.offset < policy.maxRecordsPerTask || $0.element.pinned }.map(\.element)
            keep += g
        }
        let evicted = snap.records.count - keep.count
        if evicted > 0 { metrics.count("records.evicted", by: evicted) }
        let ids = Set(keep.map(\.id))
        snap.records = snap.records.filter { ids.contains($0.id) } // keep original order
    }

    private func trimTasks(now t: Date) {
        for i in snap.tasks.indices {
            if snap.tasks[i].sources.count > policy.maxSourcesPerTask {
                snap.tasks[i].sources = Array(snap.tasks[i].sources.sorted { $0.lastSeen > $1.lastSeen }.prefix(policy.maxSourcesPerTask))
            }
            if snap.tasks[i].keywords.count > policy.maxKeywordsPerTask {
                let top = snap.tasks[i].keywords.sorted { ($0.value, $1.key) > ($1.value, $0.key) }.prefix(policy.maxKeywordsPerTask)
                snap.tasks[i].keywords = Dictionary(uniqueKeysWithValues: top.map { ($0.key, $0.value) })
            }
        }
        guard snap.tasks.count > policy.maxTasks else { return }
        let pinnedTasks = Set(snap.records.filter(\.pinned).compactMap(\.taskID))
        let removable = snap.tasks.filter { $0.id != snap.activeTaskID && !pinnedTasks.contains($0.id) }
            .sorted { $0.lastActivity < $1.lastActivity }
        for t in removable.prefix(snap.tasks.count - policy.maxTasks) { dropTask(t.id) }
    }

    private func dropTask(_ id: UUID) {
        snap.tasks.removeAll { $0.id == id }
        snap.records.removeAll { $0.taskID == id }
        snap.confirmedLinks = snap.confirmedLinks.filter { $0.value != id }
        if snap.activeTaskID == id { snap.activeTaskID = nil }
    }

    // MARK: Sessions

    /// Session end: every task touched becomes an episode (copies of what mattered), tasks pause,
    /// and temporary observations are discarded.
    @discardableResult
    public func endSession(sessionID: UUID?, startedAt: Date?) -> [Episode] {
        consolidate()
        var made: [Episode] = []
        for id in touched {
            guard let ti = snap.tasks.firstIndex(where: { $0.id == id }) else { continue }
            snap.tasks[ti].status = .paused
            let rs = records(for: id).filter { $0.kind != .source }
            guard !rs.isEmpty else { continue }
            let ep = Episode(taskID: id, title: snap.tasks[ti].title, sessionID: sessionID,
                             startedAt: startedAt ?? snap.tasks[ti].created, endedAt: now(), records: rs)
            snap.episodes.append(ep)
            made.append(ep)
        }
        touched.removeAll()
        immediate.clear()
        pendingQuestion = nil
        askedKeys.removeAll()
        ignoredKeys.removeAll()
        dirty = true
        return made
    }

    // MARK: Deletion (derived data goes too)

    public struct PurgeReport: Equatable, Sendable {
        public var observations = 0, records = 0, episodes = 0, sources = 0, titlesReset = 0
    }

    /// Removes every observation, record, episode entry and source that came from matching evidence,
    /// and rebuilds what was derived from them (titles, keyword index), so nothing deleted survives in a summary.
    @discardableResult
    public func purge(where match: (EvidenceRef) -> Bool) -> PurgeReport {
        var rep = PurgeReport()
        var removedEvidence = Set<UUID>()
        let before = immediate.events.count
        immediate.removeAll { e in match(e.evidence()) && { removedEvidence.insert(e.id); return true }() }
        rep.observations = before - immediate.events.count

        let keptRecords = snap.records.filter { r in
            let hit = r.evidence.contains(where: match)
            if hit { r.evidence.forEach { removedEvidence.insert($0.id) } }
            return !hit
        }
        rep.records = snap.records.count - keptRecords.count
        snap.records = keptRecords

        for i in snap.episodes.indices {
            let n = snap.episodes[i].records.count
            snap.episodes[i].records.removeAll { $0.evidence.contains(where: match) }
            rep.episodes += n - snap.episodes[i].records.count
        }
        snap.episodes.removeAll { $0.records.isEmpty }

        for i in snap.tasks.indices {
            let n = snap.tasks[i].sources.count
            snap.tasks[i].sources.removeAll { s in
                match(EvidenceRef(kind: .page, bundleID: s.bundleID, appName: s.appName, title: s.title, location: s.location, at: s.lastSeen))
            }
            rep.sources += n - snap.tasks[i].sources.count
            // An inferred title came from observed content: if that content is gone, so is the title.
            let fromDeleted = snap.tasks[i].titleEvidence.map(removedEvidence.contains) ?? false
            let nothingLeft = snap.tasks[i].titleProvenance == .inferred && snap.tasks[i].sources.isEmpty
                && !snap.records.contains { $0.taskID == snap.tasks[i].id }
            if fromDeleted || (nothingLeft && rep.records + rep.sources > 0) {
                snap.tasks[i].title = "Untitled task"
                snap.tasks[i].titleEvidence = nil
                rep.titlesReset += 1
            }
            rebuildIndex(i)
        }
        if let q = pendingQuestion, removedEvidence.contains(q.eventID) || match(EvidenceRef(kind: .window, bundleID: q.bundleID, appName: "", at: now())) {
            pendingQuestion = nil
        }
        dirty = true
        return rep
    }

    /// Keywords and app lists are rebuilt from what remains, never patched.
    private func rebuildIndex(_ i: Int) {
        let id = snap.tasks[i].id
        var kw: [String: Int] = [:]
        var apps: [String] = []
        for r in snap.records where r.taskID == id {
            for term in FlowText.terms(r.text, limit: 40) { kw[term, default: 0] += 1 }
            for b in r.apps where !apps.contains(b) { apps.append(b) }
        }
        for s in snap.tasks[i].sources {
            for term in FlowText.terms(s.title, limit: 20) { kw[term, default: 0] += 1 }
            if !apps.contains(s.bundleID) { apps.append(s.bundleID) }
        }
        snap.tasks[i].keywords = kw
        snap.tasks[i].apps = apps
    }

    public func purgeApp(_ bundleID: String) -> PurgeReport { purge { $0.bundleID == bundleID } }
    public func purgeSession(_ id: UUID) -> PurgeReport { purge { $0.sessionID == id } }
    /// Temporary observations only (Level 1).
    public func dropPending(bundleID: String) { immediate.removeAll { $0.bundleID == bundleID } }
    public func clearImmediate() { immediate.clear(); pendingQuestion = nil }

    /// Deletes a task, its records and episodes. Returns checkpoint files Flow wrote for it, for the app to delete.
    @discardableResult
    public func deleteTask(_ id: UUID) -> [String] {
        let files = task(id)?.writtenCheckpoints ?? []
        dropTask(id)
        snap.episodes.removeAll { $0.taskID == id }
        touched.remove(id)
        if pendingQuestion?.taskID == id { pendingQuestion = nil }
        dirty = true
        return files
    }

    /// Everything Flow collected. Packs are untouched.
    @discardableResult
    public func deleteAll() -> [String] {
        let files = snap.tasks.flatMap(\.writtenCheckpoints)
        snap = FlowSnapshot()
        immediate.clear()
        touched.removeAll()
        pendingQuestion = nil
        dirty = true
        return files
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
