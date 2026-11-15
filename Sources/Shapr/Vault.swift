import Foundation
import LocalAuthentication

/// Sensitive values for form filling: passwords, cards, ID numbers.
/// Values live only in the macOS Keychain and are read only after Touch ID or your Mac password.
/// They never go into packs, never to Claude (API or MCP), and never onto the clipboard.
struct VaultItem: Codable, Identifiable, Hashable {
    var id: UUID
    var kind: SensitiveKind
    var label: String
    /// For passwords: the site it's for (matched against the page you're filling).
    var site: String?
}

@MainActor
enum Vault {
    static var service = "app.shapr.Shapr.vault"
    static var metadataKey = "vaultItems"
    private static var unlockedUntil: Date?

    /// Labels and kinds only. Safe to keep in preferences.
    static var items: [VaultItem] {
        get {
            guard let data = UserDefaults.standard.data(forKey: metadataKey),
                  let list = try? JSONDecoder().decode([VaultItem].self, from: data) else { return [] }
            return list
        }
        set { UserDefaults.standard.set(try? JSONEncoder().encode(newValue), forKey: metadataKey) }
    }

    @discardableResult
    static func add(kind: SensitiveKind, label: String, site: String?, value: String) -> VaultItem? {
        guard let value = value.nonEmpty, let label = label.nonEmpty else { return nil }
        let item = VaultItem(id: UUID(), kind: kind, label: label, site: site?.nonEmpty.map(normalizeSite))
        Keychain.set(value, account: item.id.uuidString, service: service)
        guard Keychain.get(item.id.uuidString, service: service) != nil else { return nil }
        items.append(item)
        return item
    }

    static func delete(_ id: UUID) {
        Keychain.set(nil, account: id.uuidString, service: service)
        items.removeAll { $0.id == id }
    }

    /// Reads a value. Call `unlock` first; this refuses while the Vault is locked.
    static func value(for id: UUID) -> String? {
        guard isUnlocked else { return nil }
        return Keychain.get(id.uuidString, service: service)
    }

    static var isUnlocked: Bool { (unlockedUntil ?? .distantPast) > Date() }

    static func lock() { unlockedUntil = nil }

    /// Touch ID, Apple Watch, or your Mac password. Stays unlocked for 2 minutes.
    static func unlock(reason: String) async -> Bool {
        if isUnlocked { return true }
        let ctx = LAContext()
        var err: NSError?
        guard ctx.canEvaluatePolicy(.deviceOwnerAuthentication, error: &err) else { return false }
        let ok = (try? await ctx.evaluatePolicy(.deviceOwnerAuthentication, localizedReason: reason)) ?? false
        if ok { unlockedUntil = Date().addingTimeInterval(120) }
        return ok
    }

    /// Unlocks without asking. Self-tests only.
    static func unlockForTesting() { unlockedUntil = Date().addingTimeInterval(60) }

    /// The best stored item for a sensitive field on this page, if any.
    static func match(_ kind: SensitiveKind, pageURL: String?) -> VaultItem? {
        let candidates = items.filter { $0.kind == kind }
        guard !candidates.isEmpty else { return nil }
        if kind == .password {
            guard let host = pageURL.flatMap({ URL(string: $0)?.host }).map(normalizeSite) else {
                return candidates.count == 1 ? candidates[0] : nil
            }
            // Only offer a password saved for this site.
            return candidates.first { item in
                guard let site = item.site else { return false }
                return host == site || host.hasSuffix("." + site)
            }
        }
        return candidates.count == 1 ? candidates[0] : candidates.first
    }

    static func normalizeSite(_ s: String) -> String {
        var h = s.lowercased().trimmingCharacters(in: .whitespaces)
        if let u = URL(string: h), let host = u.host { h = host }
        if h.hasPrefix("www.") { h.removeFirst(4) }
        return h
    }
}
