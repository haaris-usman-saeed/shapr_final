import AppKit
import CryptoKit
import OSLog
import Security

/// Keeps Shapr up to date from the share server (scripts/release.sh publishes there).
/// An update is installed only if its checksum matches and it's signed by the same developer
/// as the copy that's running (same signing requirement), so nobody else can push an app to you.
@MainActor
final class Updater: ObservableObject {
    struct Release: Decodable {
        let version: String
        let build: String
        let file: String
        let sha256: String
        let notes: String?
    }

    static let autoKey = "checkForUpdates"
    static var auto: Bool {
        get { UserDefaults.standard.object(forKey: autoKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: autoKey) }
    }
    static var currentVersion: String { Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?" }
    static var currentBuild: Int { Int(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "") ?? 0 }

    private let log = Logger(subsystem: "app.shapr.Shapr", category: "updates")
    private let toast: ToastController
    private var timer: Timer?
    private var installing = false

    init(toast: ToastController) { self.toast = toast }

    /// Checks a little after launch and then every six hours (if automatic checks are on).
    func start() {
        guard Bundle.main.bundleURL.pathExtension == "app" else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 30) { [weak self] in if Self.auto { self?.check(silent: true) } }
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { if Self.auto { self?.check(silent: true) } }
        }
    }

    func check(silent: Bool) {
        Task {
            do {
                let (data, resp) = try await URLSession.shared.data(from: ShareServer.base.appendingPathComponent("api/app/latest"))
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    if !silent { upToDate() }
                    return
                }
                let r = try JSONDecoder().decode(Release.self, from: data)
                if (Int(r.build) ?? 0) > Self.currentBuild {
                    offer(r)
                } else if !silent {
                    upToDate()
                }
            } catch {
                log.error("update check failed: \(error.localizedDescription, privacy: .public)")
                if !silent {
                    toast.show(ToastContent(icon: .symbol("wifi.exclamationmark"), title: "Couldn't check for updates",
                                            subtitle: error.localizedDescription, tint: DS.warning), duration: 5)
                }
            }
        }
    }

    private func upToDate() {
        toast.show(ToastContent(icon: .symbol("checkmark.circle"), title: "Shapr is up to date",
                                subtitle: "Version \(Self.currentVersion)", tint: DS.success), duration: 3)
    }

    private func offer(_ r: Release) {
        guard !installing else { return }
        if Self.isLocalBuild {
            toast.show(ToastContent(icon: .symbol("arrow.down.circle"), title: "Shapr \(r.version) is out",
                                    subtitle: "This copy was built on this Mac, so it can't update itself. Download the new version instead.",
                                    actions: [ToastAction(title: "Download", style: .primary) {
                                        NSWorkspace.shared.open(ShareServer.base.appendingPathComponent("download"))
                                    }]), duration: 10)
            return
        }
        toast.show(ToastContent(icon: .symbol("arrow.down.circle"), title: "Shapr \(r.version) is ready",
                                subtitle: r.notes?.nonEmpty ?? "Install it now; Shapr restarts in a moment.",
                                actions: [ToastAction(title: "Install and Restart", style: .primary) { [weak self] in
                                              Task { await self?.install(r) }
                                          },
                                          ToastAction(title: "Later")]), duration: 20)
    }

    /// Signed only for this Mac (ad-hoc): its signature can't vouch for anyone else's build.
    static var isLocalBuild: Bool {
        guard let req = ownRequirement() else { return true }
        var s: CFString?
        SecRequirementCopyString(req, [], &s)
        return (s as String?)?.contains("cdhash") ?? true
    }

    private static func ownRequirement() -> SecRequirement? {
        var me: SecCode?, staticMe: SecStaticCode?, req: SecRequirement?
        guard SecCodeCopySelf([], &me) == errSecSuccess, let me,
              SecCodeCopyStaticCode(me, [], &staticMe) == errSecSuccess, let staticMe,
              SecCodeCopyDesignatedRequirement(staticMe, [], &req) == errSecSuccess else { return nil }
        return req
    }

    /// The downloaded app is a valid, untampered app signed the same way as this one.
    static func isTrusted(_ app: URL) -> Bool {
        guard let req = ownRequirement() else { return false }
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code else { return false }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        return SecStaticCodeCheckValidity(code, flags, req) == errSecSuccess
            && Bundle(url: app)?.bundleIdentifier == Bundle.main.bundleIdentifier
    }

    func install(_ r: Release) async {
        installing = true
        defer { installing = false }
        let working = toast.show(ToastContent(icon: .spinner, title: "Downloading Shapr \(r.version)…"), duration: nil)
        do {
            let fm = FileManager.default
            let dir = fm.temporaryDirectory.appendingPathComponent("shapr-update-\(UUID().uuidString)")
            try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            let url = ShareServer.base.appendingPathComponent("api/app/files").appendingPathComponent(r.file)
            let (tmp, resp) = try await URLSession.shared.download(from: url)
            guard (resp as? HTTPURLResponse)?.statusCode == 200 else { throw UpdateError("The download didn't work.") }
            let data = try Data(contentsOf: tmp, options: .mappedIfSafe)
            let sum = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            guard sum == r.sha256.lowercased() else { throw UpdateError("The download was damaged (checksum mismatch).") }
            let zip = dir.appendingPathComponent("Shapr.zip")
            try fm.moveItem(at: tmp, to: zip)
            try Self.run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.appendingPathComponent("x").path])
            guard let app = fm.enumerator(at: dir.appendingPathComponent("x"), includingPropertiesForKeys: nil)?
                    .compactMap({ $0 as? URL }).first(where: { $0.lastPathComponent == "Shapr.app" }) else {
                throw UpdateError("The download didn't contain Shapr.")
            }
            guard Self.isTrusted(app) else { throw UpdateError("The download isn't signed by Shapr's developer, so it wasn't installed.") }

            let current = Bundle.main.bundleURL
            _ = try fm.replaceItemAt(current, withItemAt: app, backupItemName: nil, options: [])
            log.notice("installed \(r.version, privacy: .public), restarting")
            toast.dismiss(ifToken: working)
            let relaunch = Process()
            relaunch.executableURL = URL(fileURLWithPath: "/bin/sh")
            relaunch.arguments = ["-c", "sleep 1; /usr/bin/open \"$0\"", current.path]
            try relaunch.run()
            NSApp.terminate(nil)
        } catch {
            toast.dismiss(ifToken: working)
            toast.show(ToastContent(icon: .symbol("exclamationmark.triangle"), title: "Couldn't install the update",
                                    subtitle: error.localizedDescription,
                                    actions: [ToastAction(title: "Download instead") {
                                        NSWorkspace.shared.open(ShareServer.base.appendingPathComponent("download"))
                                    }], tint: DS.warning), duration: 8)
        }
    }

    struct UpdateError: LocalizedError {
        let message: String
        init(_ m: String) { message = m }
        var errorDescription: String? { message }
    }

    private static func run(_ tool: String, _ args: [String]) throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: tool)
        p.arguments = args
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw UpdateError("Couldn't unpack the update.") }
    }
}
