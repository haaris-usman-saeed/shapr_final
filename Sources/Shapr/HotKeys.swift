import Carbon
import Foundation

/// Global shortcuts via Carbon's RegisterEventHotKey, which reports both press and release
/// (needed for hold-to-open on the wheel) and needs no extra permission.
@MainActor
final class HotKeyCenter {
    static let shared = HotKeyCenter()

    private struct Handlers {
        let pressed: () -> Void
        let released: () -> Void
    }

    private var handlers: [UInt32: Handlers] = [:]
    private var refs: [UInt32: EventHotKeyRef] = [:]
    private var installed = false

    static let captureID: UInt32 = 1
    static let wheelID: UInt32 = 2
    static let dropID: UInt32 = 3
    static let screenID: UInt32 = 4
    static let formID: UInt32 = 5
    static let progressID: UInt32 = 6
    static let resumeID: UInt32 = 7
    static let quickID: UInt32 = 8
    static let useID: UInt32 = 9
    static let askID: UInt32 = 10
    static let voiceID: UInt32 = 11

    @discardableResult
    func register(id: UInt32, keyCode: Int, modifiers: Int,
                  pressed: @escaping () -> Void, released: @escaping () -> Void = {}) -> Bool {
        installIfNeeded()
        if let old = refs[id] { UnregisterEventHotKey(old) }
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: OSType(0x5348_5052), id: id) // 'SHPR'
        let status = RegisterEventHotKey(UInt32(keyCode), UInt32(modifiers), hotKeyID,
                                         GetApplicationEventTarget(), 0, &ref)
        guard status == noErr, let ref else { return false }
        refs[id] = ref
        handlers[id] = Handlers(pressed: pressed, released: released)
        return true
    }

    func unregister(id: UInt32) {
        if let ref = refs[id] { UnregisterEventHotKey(ref) }
        refs[id] = nil
        handlers[id] = nil
    }

    fileprivate func fire(id: UInt32, pressed: Bool) {
        guard let h = handlers[id] else { return }
        pressed ? h.pressed() : h.released()
    }

    private func installIfNeeded() {
        guard !installed else { return }
        installed = true
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
            guard let event else { return OSStatus(eventNotHandledErr) }
            var hk = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID),
                              nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let isPress = GetEventKind(event) == UInt32(kEventHotKeyPressed)
            let id = hk.id
            Task { @MainActor in HotKeyCenter.shared.fire(id: id, pressed: isPress) }
            return noErr
        }, specs.count, &specs, nil, nil)
    }
}

/// Shapr is voice-first: ⌥C scoops, ⌘⌘ circles, ⌥S opens the wheel, and holding ⌥V does everything else.
/// The classic one-shortcut-per-command set (⌥⇧D, ⌥⇧F, …) is an option.
enum ShortcutSettings {
    static let changed = Notification.Name("ShaprShortcutsChanged")
    static var classic: Bool {
        get { UserDefaults.standard.bool(forKey: "classicShortcuts") }
        set {
            UserDefaults.standard.set(newValue, forKey: "classicShortcuts")
            NotificationCenter.default.post(name: changed, object: nil)
        }
    }
}
