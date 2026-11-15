import AppKit
import ApplicationServices

/// Grabs the current selection from the frontmost app, plus where it came from.
@MainActor
enum CaptureService {
    enum Failure: Error {
        case needsAccessibility
        case nothingSelected
        case ownApp

        var message: (title: String, subtitle: String) {
            switch self {
            case .needsAccessibility:
                return ("Shapr needs Accessibility access", "It's how Shapr reads the text you highlight.")
            case .nothingSelected:
                return ("Nothing selected", "Highlight some text first, then press ⌥C.")
            case .ownApp:
                return ("That's Shapr itself", "Switch to another app and highlight text there.")
            }
        }
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Shows the system prompt that adds Shapr to Accessibility settings.
    @discardableResult
    static func requestTrust() -> Bool {
        AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
    }

    static func captureSelection() async -> Result<CaptureDraft, Failure> {
        guard isTrusted else { return .failure(.needsAccessibility) }
        guard let app = NSWorkspace.shared.frontmostApplication else { return .failure(.nothingSelected) }
        if app.bundleIdentifier == Bundle.main.bundleIdentifier, Bundle.main.bundleIdentifier != nil {
            return .failure(.ownApp)
        }

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appElement, 0.6)

        var text = selectedTextViaAccessibility(appElement)
        if text == nil { text = await selectedTextViaCopy() }
        guard let text = text?.nonEmpty else { return .failure(.nothingSelected) }

        var draft = CaptureDraft(text: String(text.prefix(50_000)), appName: app.localizedName,
                                 bundleID: app.bundleIdentifier)
        if let bid = app.bundleIdentifier, let info = browserInfo(bundleID: bid) {
            draft.url = info.url
            draft.title = info.title
        }
        if draft.title == nil || draft.url == nil {
            let win = windowInfo(appElement)
            draft.title = draft.title ?? win.title
            draft.url = draft.url ?? win.document
        }
        return .success(draft)
    }

    // MARK: Selection

    private static func selectedTextViaAccessibility(_ app: AXUIElement) -> String? {
        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        var selected: CFTypeRef?
        guard AXUIElementCopyAttributeValue(focused as! AXUIElement, kAXSelectedTextAttribute as CFString,
                                            &selected) == .success else { return nil }
        return (selected as? String)?.nonEmpty
    }

    /// Fallback for apps (most browsers) that don't expose the selection: press ⌘C,
    /// read the clipboard, then put back whatever was on it before.
    private static func selectedTextViaCopy() async -> String? {
        // Let go of ⌥⇧ first so the app sees a clean ⌘C.
        let held: CGEventFlags = [.maskAlternate, .maskShift, .maskControl, .maskCommand]
        for _ in 0..<15 where !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty {
            try? await Task.sleep(for: .milliseconds(20))
        }

        let pb = NSPasteboard.general
        let saved: [[NSPasteboard.PasteboardType: Data]] = (pb.pasteboardItems ?? []).map { item in
            var d: [NSPasteboard.PasteboardType: Data] = [:]
            for t in item.types { if let data = item.data(forType: t) { d[t] = data } }
            return d
        }
        let before = pb.changeCount

        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: true)   // kVK_ANSI_C
        let up = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)

        var copied: String?
        for _ in 0..<40 {
            try? await Task.sleep(for: .milliseconds(20))
            if pb.changeCount != before {
                copied = pb.string(forType: .string)
                break
            }
        }

        if pb.changeCount != before {
            pb.clearContents()
            let items = saved.map { d -> NSPasteboardItem in
                let item = NSPasteboardItem()
                for (t, data) in d { item.setData(data, forType: t) }
                return item
            }
            if !items.isEmpty { pb.writeObjects(items) }
        }
        return copied
    }

    // MARK: Source

    private static let chromium: Set<String> = [
        "com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.canary", "com.brave.Browser",
        "com.microsoft.edgemac", "com.vivaldi.Vivaldi", "company.thebrowser.Browser", "com.operasoftware.Opera",
    ]

    /// Page URL and title from the browser, via AppleScript (asks for Automation permission once).
    static func browserInfo(bundleID: String) -> (url: String?, title: String?)? {
        let script: String
        if bundleID == "com.apple.Safari" || bundleID == "com.apple.SafariTechnologyPreview" {
            script = """
            tell application id "\(bundleID)"
              if (count of documents) > 0 then return {URL of front document, name of front document}
            end tell
            """
        } else if chromium.contains(bundleID) {
            script = """
            tell application id "\(bundleID)"
              if (count of windows) > 0 then return {URL of active tab of front window, title of active tab of front window}
            end tell
            """
        } else {
            return nil
        }
        var err: NSDictionary?
        guard let out = NSAppleScript(source: script)?.executeAndReturnError(&err), out.numberOfItems >= 2 else {
            return nil
        }
        return (out.atIndex(1)?.stringValue?.nonEmpty, out.atIndex(2)?.stringValue?.nonEmpty)
    }

    /// Window title and, for document apps like Preview, the file being viewed.
    private static func windowInfo(_ app: AXUIElement) -> (title: String?, document: String?) {
        var win: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute as CFString, &win) == .success,
              let win, CFGetTypeID(win) == AXUIElementGetTypeID() else { return (nil, nil) }
        let w = win as! AXUIElement
        var title: CFTypeRef?
        var doc: CFTypeRef?
        AXUIElementCopyAttributeValue(w, kAXTitleAttribute as CFString, &title)
        AXUIElementCopyAttributeValue(w, kAXDocumentAttribute as CFString, &doc)
        return ((title as? String)?.nonEmpty, (doc as? String)?.nonEmpty)
    }
}
