import AppKit
import ApplicationServices

/// The text of the window in front, read through Accessibility, for apps that aren't browsers or AI
/// chats: WhatsApp, Messages, Slack, Notes, Mail, a PDF. Everything the window has loaded, in reading
/// order, not just what fits on screen. It never clicks, scrolls, types or touches the clipboard.
enum WindowText {
    /// Chrome around the content: never part of what you'd want to keep.
    private static let skipRoles: Set<String> = ["AXMenuBar", "AXMenu", "AXMenuItem", "AXToolbar", "AXScrollBar", "AXButton", "AXPopUpButton",
                                                 "AXMenuButton", "AXCheckBox", "AXRadioButton", "AXSlider", "AXTabGroup", "AXSplitter",
                                                 "AXIncrementor", "AXDisclosureTriangle", "AXImage", "AXSearchField"]
    private static let keys = [kAXRoleAttribute, kAXValueAttribute, kAXDescriptionAttribute, kAXChildrenAttribute] as CFArray

    static func read(pid: pid_t, budget: TimeInterval = 2.0, maxNodes: Int = 20_000) -> (title: String?, text: String)? {
        let app = AXUIElementCreateApplication(pid)
        AXUIElementSetMessagingTimeout(app, 0.4)
        // Electron and Catalyst apps build their full tree only for assistive apps that ask for it.
        AXUIElementSetAttributeValue(app, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        guard let window: AXUIElement = ChatReader.attr(app, kAXFocusedWindowAttribute) ?? ChatReader.attr(app, kAXMainWindowAttribute) else { return nil }
        let title: String? = ChatReader.attr(window, kAXTitleAttribute)
        var lines: [String] = []
        var count = 0
        walk(window, into: &lines, count: &count, maxNodes: maxNodes, deadline: Date().addingTimeInterval(budget), depth: 0)
        return (title?.nonEmpty, join(lines))
    }

    private static func walk(_ el: AXUIElement, into lines: inout [String], count: inout Int, maxNodes: Int, deadline: Date, depth: Int) {
        count += 1
        var values: CFArray?
        guard AXUIElementCopyMultipleAttributeValues(el, keys, [], &values) == .success, let arr = values as? [Any], arr.count == 4 else { return }
        let role = arr[0] as? String ?? ""
        guard !skipRoles.contains(role) else { return }
        if role == "AXStaticText" || role == "AXTextArea" || role == "AXTextField" || role == "AXHeading" || role == "AXLink" {
            if let v = (arr[1] as? String)?.nonEmpty { lines.append(v) }
        }
        // Many chat apps put a whole message ("Ana, see you at five, 10:42") in an element's description.
        if role != "AXWindow", let d = (arr[2] as? String)?.nonEmpty, d.count >= 12 { lines.append(d) }
        guard role != "AXStaticText", depth < 70, let kids = arr[3] as? [AXUIElement] else { return }
        for k in kids {
            guard count < maxNodes, Date() < deadline else { break }
            walk(k, into: &lines, count: &count, maxNodes: maxNodes, deadline: deadline, depth: depth + 1)
        }
    }

    /// The lines as text: blank and repeated lines go, and so does a line that only repeats part of the
    /// one before it (a message's own text right after the description that already had it).
    static func join(_ lines: [String]) -> String {
        var out: [String] = []
        for raw in lines {
            for piece in raw.components(separatedBy: "\n") {
                let l = piece.trimmingCharacters(in: .whitespaces)
                guard !l.isEmpty else { continue }
                if out.suffix(3).contains(where: { $0 == l || ($0.count > l.count && l.count >= 2 && $0.contains(l)) }) { continue }
                // The longer line that follows has it too: keep that one.
                if let last = out.last, l.count > last.count, last.count >= 4, l.contains(last) { out.removeLast() }
                out.append(l)
            }
        }
        return String(out.joined(separator: "\n").prefix(200_000))
    }
}
