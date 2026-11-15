import AppKit
import ApplicationServices

/// Fast reads of what you're pointing at, for showing feedback right away: the selected text and
/// where it is on screen, whether you're in a text box, and the text under the pointer.
/// Accessibility only, with short timeouts; nothing here presses keys or touches the clipboard.
@MainActor
enum PointerContext {
    struct Snapshot {
        var app: NSRunningApplication?
        var selection: String?
        /// Global AppKit coordinates.
        var selectionBounds: CGRect?
        var inTextBox = false
    }

    static func now() -> Snapshot {
        var s = Snapshot(app: NSWorkspace.shared.frontmostApplication)
        guard CaptureService.isTrusted, let app = s.app, app.bundleIdentifier != Bundle.main.bundleIdentifier else { return s }
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 0.15)
        guard let focused: AXUIElement = FormScanner.attr(el, kAXFocusedUIElementAttribute) else { return s }
        s.selection = (FormScanner.attr(focused, kAXSelectedTextAttribute) as String?)?.nonEmpty
        s.selectionBounds = selectionBounds(focused)
        let role: String? = FormScanner.attr(focused, kAXRoleAttribute)
        var settable = DarwinBoolean(false)
        AXUIElementIsAttributeSettable(focused, kAXValueAttribute as CFString, &settable)
        s.inTextBox = ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role ?? "") || settable.boolValue
        return s
    }

    /// The selection's rectangle on screen, from the text range (native apps) or the text marker
    /// range (Safari and other WebKit pages).
    static func selectionBounds(_ focused: AXUIElement) -> CGRect? {
        var bounds: CFTypeRef?
        var range: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, kAXSelectedTextRangeAttribute as CFString, &range) == .success, let range,
           AXUIElementCopyParameterizedAttributeValue(focused, kAXBoundsForRangeParameterizedAttribute as CFString, range, &bounds) == .success {
            return appKitRect(bounds)
        }
        var marker: CFTypeRef?
        if AXUIElementCopyAttributeValue(focused, "AXSelectedTextMarkerRange" as CFString, &marker) == .success, let marker,
           AXUIElementCopyParameterizedAttributeValue(focused, "AXBoundsForTextMarkerRange" as CFString, marker, &bounds) == .success {
            return appKitRect(bounds)
        }
        return nil
    }

    private static func appKitRect(_ value: CFTypeRef?) -> CGRect? {
        guard let value, CFGetTypeID(value) == AXValueGetTypeID() else { return nil }
        var r = CGRect.zero
        guard AXValueGetValue(value as! AXValue, .cgRect, &r), r.width > 1, r.height > 1 else { return nil }
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        return CGRect(x: r.minX, y: mainHeight - r.maxY, width: r.width, height: r.height)
    }

    /// The readable text under the pointer: the element there, or its paragraph.
    static func textUnderPointer() -> String? {
        guard CaptureService.isTrusted else { return nil }
        let system = AXUIElementCreateSystemWide()
        AXUIElementSetMessagingTimeout(system, 0.2)
        let p = NSEvent.mouseLocation
        let mainHeight = NSScreen.screens.first?.frame.height ?? 0
        var el: AXUIElement?
        guard AXUIElementCopyElementAtPosition(system, Float(p.x), Float(mainHeight - p.y), &el) == .success, var cur = el else { return nil }
        for _ in 0..<4 {
            if let t = text(of: cur), t.count >= 12 { return String(t.prefix(4000)) }
            guard let parent: AXUIElement = FormScanner.attr(cur, kAXParentAttribute) else { break }
            cur = parent
        }
        return nil
    }

    private static func text(of el: AXUIElement) -> String? {
        for k in [kAXValueAttribute, kAXTitleAttribute, kAXDescriptionAttribute] {
            if let s: String = FormScanner.attr(el, k), let t = s.nonEmpty, t.count >= 12 { return t }
        }
        var parts: [String] = []
        for c in ((FormScanner.attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? []).prefix(40) {
            if let v: String = FormScanner.attr(c, kAXValueAttribute), let t = v.nonEmpty { parts.append(t) }
        }
        return parts.joined(separator: " ").nonEmpty
    }
}
