import Foundation

/// Why an app may or may not be observed right now.
public enum ObservationDecision: Equatable, Sendable {
    case observe
    /// Not decided yet: ask the user (only the app's identity was looked at).
    case ask
    case deny(DenyReason)

    public enum DenyReason: String, Sendable {
        case sessionOff, paused, noIdentity, neverObserved, userDenied, notNow
    }

    public var allowed: Bool { self == .observe }
}

/// The user's per-app choices. `always` and `denied` are stored on disk; `session` and `once`
/// live only in memory, so they can never outlive their scope by surviving a restart.
public final class AppAuthorizationStore {
    public private(set) var stored: [String: AppPermission] = [:]
    private var transient: [String: AppPermission] = [:]
    /// Apps the user dismissed the prompt for this session ("not now"): not asked again until the next session.
    private var notNow: [String: UUID] = [:]
    private let url: URL?
    private let now: () -> Date
    /// Session and once grants also expire after this long, whatever happens.
    public var transientMaxAge: TimeInterval = 12 * 3600
    public var onRevoke: (String) -> Void = { _ in }

    public init(url: URL?, now: @escaping () -> Date = Date.init) {
        self.url = url
        self.now = now
        load()
    }

    private func load() {
        guard let url, let data = try? Data(contentsOf: url) else { return }
        guard let file = try? JSONDecoder.flow.decode(File.self, from: data) else {
            FlowStore.quarantine(url)
            return
        }
        // Only durable grants are ever trusted from disk.
        stored = file.apps.filter { $0.value.access == .always || $0.value.access == .denied }
    }

    private struct File: Codable { var schema = FlowSchema.version; var apps: [String: AppPermission] }

    private func save() {
        guard let url else { return }
        FlowStore.writeAtomically(File(apps: stored), to: url)
    }

    /// The decision for one app. Only the bundle identifier is consulted; nothing about its content.
    public func decision(bundleID: String?, sessionID: UUID?, activation: Int?) -> ObservationDecision {
        guard let b = bundleID, !b.isEmpty else { return .deny(.noIdentity) }
        if SensitiveApps.isNeverObserved(b) { return .deny(.neverObserved) }
        if stored[b]?.access == .denied { return .deny(.userDenied) } // denial wins over anything broader
        if stored[b]?.access == .always { return .observe }
        if let t = transient[b] {
            let fresh = t.expiresAt.map { now() < $0 } ?? true
            switch t.access {
            case .session where fresh && t.sessionID != nil && t.sessionID == sessionID: return .observe
            case .once where fresh && t.sessionID == sessionID && t.activation != nil && t.activation == activation: return .observe
            default: transient[b] = nil
            }
        }
        if let s = notNow[b], s == sessionID { return .deny(.notNow) }
        return .ask
    }

    public func permission(for bundleID: String) -> AppPermission? { transient[bundleID] ?? stored[bundleID] }

    /// Every app with a choice, for the privacy controls.
    public var all: [AppPermission] {
        var m = stored
        for (k, v) in transient where m[k] == nil { m[k] = v }
        return m.values.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    public func set(_ access: AppAccess, bundleID: String, name: String, sessionID: UUID?, activation: Int?) {
        let t = now()
        let narrowing = access == .denied || (permission(for: bundleID).map { $0.access == .always } ?? false) && access != .always
        notNow[bundleID] = nil
        switch access {
        case .always, .denied:
            transient[bundleID] = nil
            stored[bundleID] = AppPermission(bundleID: bundleID, displayName: name, access: access, grantedAt: t)
        case .session, .once:
            stored[bundleID] = nil
            transient[bundleID] = AppPermission(bundleID: bundleID, displayName: name, access: access, grantedAt: t,
                                                expiresAt: t.addingTimeInterval(transientMaxAge),
                                                sessionID: sessionID, activation: access == .once ? activation : nil)
        }
        save()
        if narrowing { onRevoke(bundleID) }
    }

    /// Forget the choice entirely: the app will be asked about again. Observation stops at once.
    public func revoke(bundleID: String) {
        stored[bundleID] = nil
        transient[bundleID] = nil
        notNow[bundleID] = nil
        save()
        onRevoke(bundleID)
    }

    public func dismissPrompt(bundleID: String, sessionID: UUID?) {
        if let s = sessionID { notNow[bundleID] = s }
    }

    public func noteDeactivated(bundleID: String) {
        if transient[bundleID]?.access == .once { transient[bundleID] = nil }
    }

    public func endSession() {
        transient.removeAll()
        notNow.removeAll()
    }

    public func noteRead(bundleID: String) {
        if transient[bundleID] != nil { transient[bundleID]?.lastAllowedRead = now() }
        else if stored[bundleID] != nil { stored[bundleID]?.lastAllowedRead = now() }
    }
}

/// Session state plus an epoch that changes on every pause, end or revocation. A read gets a
/// ticket before it starts and must present it again before its result is used: if anything
/// changed in between, the result is thrown away without being looked at.
public final class FlowSession {
    public private(set) var state: SessionState = .off
    public private(set) var sessionID: UUID?
    public private(set) var startedAt: Date?
    public private(set) var epoch: UInt64 = 0
    public var onChange: (SessionState) -> Void = { _ in }
    private let now: () -> Date

    public init(now: @escaping () -> Date = Date.init) { self.now = now }

    public struct Ticket: Equatable, Sendable {
        public let epoch: UInt64
        public let sessionID: UUID
        public let bundleID: String
        public let activation: Int
    }

    @discardableResult
    public func start() -> UUID {
        if state == .active, let s = sessionID { return s }
        if state == .paused, let s = sessionID { set(.active); return s }
        let id = UUID()
        sessionID = id
        startedAt = now()
        set(.active)
        return id
    }

    public func pause() { if state == .active { set(.paused) } }
    public func resume() { if state == .paused { set(.active) } }

    /// Ends the session: `flush` runs while the state is `.ending` (nothing new is accepted then).
    public func end(flush: () -> Void) {
        guard state == .active || state == .paused else { return }
        set(.ending)
        flush()
        sessionID = nil
        startedAt = nil
        set(.off)
    }

    /// Invalidate every outstanding ticket (on revocation, sleep, screen lock).
    public func invalidate() { epoch &+= 1 }

    private func set(_ s: SessionState) {
        state = s
        epoch &+= 1
        onChange(s)
    }

    public func ticket(bundleID: String, activation: Int) -> Ticket? {
        guard state == .active, let s = sessionID else { return nil }
        return Ticket(epoch: epoch, sessionID: s, bundleID: bundleID, activation: activation)
    }

    public func isCurrent(_ t: Ticket) -> Bool { state == .active && t.epoch == epoch && t.sessionID == sessionID }
}
