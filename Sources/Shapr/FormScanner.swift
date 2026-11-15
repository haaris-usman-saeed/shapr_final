import AppKit
import ApplicationServices

/// Fields that must never come from packs or go to an AI model. They're filled only from the Vault.
enum SensitiveKind: String, Codable, CaseIterable, Identifiable {
    case password, cardNumber, cardExpiry, cardCode, nationalID, passport, driversLicense, bankAccount, otherSecret

    var id: String { rawValue }

    var title: String {
        switch self {
        case .password: return "Password"
        case .cardNumber: return "Card number"
        case .cardExpiry: return "Card expiry"
        case .cardCode: return "Card security code"
        case .nationalID: return "SSN / national ID"
        case .passport: return "Passport number"
        case .driversLicense: return "Driver's license"
        case .bankAccount: return "Bank account"
        case .otherSecret: return "Other"
        }
    }

    var symbol: String {
        switch self {
        case .password: return "key.fill"
        case .cardNumber, .cardExpiry, .cardCode: return "creditcard.fill"
        case .nationalID, .passport, .driversLicense: return "person.text.rectangle.fill"
        case .bankAccount: return "building.columns.fill"
        case .otherSecret: return "lock.fill"
        }
    }

    private static let rules: [(SensitiveKind, String)] = [
        (.cardCode, #"\b(cvv|cvc|cvv2|csc|security code|card code|card verification)\b"#),
        (.cardExpiry, #"(expir|exp\.? ?date|valid (thru|through)|mm ?/ ?yy)"#),
        (.cardNumber, #"(card ?number|credit ?card|debit ?card|\bcc ?(number|no|#)|\bcard no\b|\bpan\b)"#),
        (.nationalID, #"(\bssn\b|social security|national (id|identity|insurance)|\bsin\b|tax ?id|\btin\b|\bitin\b|aadhaar|\bnric\b|\bpesel\b)"#),
        (.passport, #"passport"#),
        (.driversLicense, #"(driver'?s? ?licen[cs]e|driving licen[cs]e|licen[cs]e (number|no))"#),
        (.bankAccount, #"(account number|acct|routing|\biban\b|sort code|\bswift\b|\bbic\b|bank account)"#),
        (.password, #"(password|passcode|passphrase|\bpin\b)"#),
    ]

    /// Decides from the field's label, placeholder and whether it's a secure (dotted) field.
    static func classify(label: String, placeholder: String?, isSecure: Bool) -> SensitiveKind? {
        let text = (label + " " + (placeholder ?? "")).lowercased()
        for (kind, pattern) in rules where text.range(of: pattern, options: .regularExpression) != nil {
            return kind
        }
        return isSecure ? .password : nil
    }
}

enum FieldKind: Equatable {
    /// A text box.
    case text
    /// A dropdown or a group of radio buttons: pick one of `options`.
    case choice
    /// A single tick box: yes or no.
    case checkbox
    /// A date picker.
    case date
}

/// One fillable field found in the frontmost window.
struct FormField: Identifiable {
    let id: Int
    let element: AXUIElement
    let label: String
    let placeholder: String?
    let currentValue: String?
    let isSecure: Bool
    let isMultiline: Bool
    let sensitive: SensitiveKind?
    var kind: FieldKind = .text
    /// For choices: the options, in order.
    var options: [String] = []
    /// For radio buttons: the button for each option (dropdowns open their own menu).
    var optionElements: [AXUIElement] = []
    /// For checkboxes: ticked now?
    var checked: Bool? = nil

    var looksLikeQuestion: Bool {
        kind == .text && (isMultiline || label.contains("?") || label.split(separator: " ").count > 6)
    }

    /// Agreeing to terms, consenting, subscribing: Shapr never ticks these for you.
    var isConsent: Bool {
        kind == .checkbox && Self.isConsent(label)
    }

    static func isConsent(_ label: String) -> Bool {
        label.range(of: #"(?i)\b(agree|terms|conditions|privacy|consent|subscribe|newsletter|marketing|promotional|i confirm|i certify|i acknowledge|i accept|opt[ -]?in|i understand|authori[sz]e|declare|attest)\b"#,
                    options: .regularExpression) != nil
    }
}

@MainActor
enum FormScanner {
    private static let textRoles: Set<String> = ["AXTextField", "AXTextArea", "AXComboBox"]

    /// Every enabled text field in the app's focused window, in reading order.
    static func scan(app: NSRunningApplication, limit: Int = 60) -> [FormField] {
        let appEl = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(appEl, 1.0)
        // Chrome, Edge, Arc and other Chromium/Electron apps only build their web accessibility tree on request.
        AXUIElementSetAttributeValue(appEl, "AXManualAccessibility" as CFString, kCFBooleanTrue)

        guard let window: AXUIElement = attr(appEl, kAXFocusedWindowAttribute) else { return [] }
        var fields: [FormField] = []
        var recentText: String?
        var visited = 0
        var consumed: [AXUIElement] = []
        let deadline = Date().addingTimeInterval(2.0)

        func walk(_ el: AXUIElement, depth: Int) {
            guard fields.count < limit, visited < 6000, depth < 60, Date() < deadline else { return }
            visited += 1
            let role: String = attr(el, kAXRoleAttribute) ?? ""
            let subrole: String = attr(el, kAXSubroleAttribute) ?? ""
            // Browser chrome (tabs, address bar, toolbars) isn't part of the form.
            if role == "AXToolbar" || role == "AXTabGroup" { return }

            // A radio button: gather its whole group once (web radios each sit inside their own label).
            if role == "AXRadioButton" {
                guard !consumed.contains(where: { CFEqual($0, el) }) else { return }
                let group = radioGroup(of: el)
                consumed += group
                let titles = group.map { r -> String in
                    let t: String? = attr(r, kAXTitleAttribute)
                    return (t?.nonEmpty ?? Self.label(for: r) ?? "").singleLine.truncated(80)
                }
                if group.count >= 2, titles.allSatisfy({ !$0.isEmpty }) {
                    let selected = group.firstIndex { (attr($0, kAXValueAttribute) as NSNumber?)?.intValue == 1 }
                    fields.append(FormField(id: fields.count + 1, element: el, label: (recentText ?? "Choice \(fields.count + 1)").singleLine.truncated(160),
                                            placeholder: nil, currentValue: selected.map { titles[$0] }, isSecure: false, isMultiline: false,
                                            sensitive: nil, kind: .choice, options: titles, optionElements: group))
                    recentText = nil
                }
                return
            }

            if role == "AXStaticText" {
                let v: String? = attr(el, kAXValueAttribute)
                if let v = v?.nonEmpty, v.count < 200 { recentText = v }
            }

            let enabled = (attr(el, kAXEnabledAttribute) as Bool?) != false
            // A dropdown (HTML select or a native pop-up button).
            if role == "AXPopUpButton", enabled {
                let label = Self.label(for: el) ?? recentText ?? "Choice \(fields.count + 1)"
                let value: String? = attr(el, kAXValueAttribute) ?? attr(el, kAXTitleAttribute)
                fields.append(FormField(id: fields.count + 1, element: el, label: label.singleLine.truncated(160), placeholder: nil,
                                        currentValue: value?.nonEmpty, isSecure: false, isMultiline: false, sensitive: nil,
                                        kind: .choice, options: menuOptions(of: el)))
                recentText = nil
                return
            }
            if role == "AXCheckBox", enabled, subrole != "AXSwitch" || depth > 3 {
                let title: String? = attr(el, kAXTitleAttribute)
                let label = title?.nonEmpty ?? Self.label(for: el) ?? recentText ?? "Checkbox \(fields.count + 1)"
                let on = (attr(el, kAXValueAttribute) as NSNumber?)?.intValue == 1
                fields.append(FormField(id: fields.count + 1, element: el, label: label.singleLine.truncated(160), placeholder: nil,
                                        currentValue: on ? "yes" : "no", isSecure: false, isMultiline: false, sensitive: nil,
                                        kind: .checkbox, checked: on))
                recentText = nil
                return
            }
            if role == "AXDateField" || role == "AXDateTimeArea", enabled {
                let label = Self.label(for: el) ?? recentText ?? "Date \(fields.count + 1)"
                let value: String? = attr(el, kAXValueAttribute)
                fields.append(FormField(id: fields.count + 1, element: el, label: label.singleLine.truncated(160), placeholder: nil,
                                        currentValue: value?.nonEmpty, isSecure: false, isMultiline: false, sensitive: nil, kind: .date))
                recentText = nil
                return
            }
            // Radio buttons: a radio group, or two or more radios side by side.
            let kids: [AXUIElement] = attr(el, kAXChildrenAttribute) ?? []
            let radios = kids.filter { (attr($0, kAXRoleAttribute) as String?) == "AXRadioButton" }
            if radios.count >= 2 || (role == "AXRadioGroup" && !radios.isEmpty) {
                let titles = radios.map { r -> String in
                    let t: String? = attr(r, kAXTitleAttribute)
                    return (t?.nonEmpty ?? Self.label(for: r) ?? "").singleLine.truncated(80)
                }
                if titles.allSatisfy({ !$0.isEmpty }) {
                    let groupLabel = (role == "AXRadioGroup" ? Self.label(for: el) : nil) ?? recentText ?? Self.label(for: el) ?? "Choice \(fields.count + 1)"
                    let selected = radios.firstIndex { (attr($0, kAXValueAttribute) as NSNumber?)?.intValue == 1 }
                    fields.append(FormField(id: fields.count + 1, element: el, label: groupLabel.singleLine.truncated(160), placeholder: nil,
                                            currentValue: selected.map { titles[$0] }, isSecure: false, isMultiline: false, sensitive: nil,
                                            kind: .choice, options: titles, optionElements: radios))
                    recentText = nil
                    // Labels inside the group aren't the next field's label.
                    for k in kids where !radios.contains(where: { CFEqual($0, k) }) { walk(k, depth: depth + 1) }
                    return
                }
            }

            if textRoles.contains(role), subrole != "AXSearchField", enabled {
                let secure = subrole == "AXSecureTextField"
                let placeholder: String? = attr(el, "AXPlaceholderValue")
                let label = Self.label(for: el) ?? recentText ?? placeholder ?? "Field \(fields.count + 1)"
                let value: String? = secure ? nil : attr(el, kAXValueAttribute)
                fields.append(FormField(
                    id: fields.count + 1, element: el, label: label.singleLine.truncated(160),
                    placeholder: placeholder?.nonEmpty, currentValue: value?.nonEmpty,
                    isSecure: secure, isMultiline: role == "AXTextArea",
                    sensitive: SensitiveKind.classify(label: label, placeholder: placeholder, isSecure: secure)))
                recentText = nil
                return
            }

            for c in kids { walk(c, depth: depth + 1) }
        }
        // In a browser, only the page: never the tabs or the address bar.
        walk(webArea(in: window) ?? window, depth: 0)
        return fields
    }

    /// The web page inside a browser window, if there is one.
    static func webArea(in window: AXUIElement) -> AXUIElement? {
        var queue: [(AXUIElement, Int)] = [(window, 0)]
        var i = 0
        var best: (AXUIElement, Int)?
        while i < queue.count, i < 400 {
            let (el, depth) = queue[i]
            i += 1
            if (attr(el, kAXRoleAttribute) as String?) == "AXWebArea" {
                let n = (attr(el, kAXChildrenAttribute) as [AXUIElement]?)?.count ?? 0
                if best == nil || n > best!.1 { best = (el, n) }
                continue
            }
            guard depth < 12 else { continue }
            for k in (attr(el, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { queue.append((k, depth + 1)) }
        }
        return best?.0
    }

    /// Every radio button in the same group: the ones the page links together, or else the radios
    /// under the nearest container (a fieldset, or the label's parent).
    static func radioGroup(of radio: AXUIElement) -> [AXUIElement] {
        func isRadio(_ e: AXUIElement) -> Bool { (attr(e, kAXRoleAttribute) as String?) == "AXRadioButton" }
        if let linked: [AXUIElement] = attr(radio, "AXLinkedUIElements") {
            var group = linked.filter(isRadio)
            if !group.contains(where: { CFEqual($0, radio) }) { group.insert(radio, at: 0) }
            if group.count >= 2 { return group }
        }
        var container: AXUIElement? = attr(radio, kAXParentAttribute)
        for _ in 0..<3 {
            guard let c = container else { break }
            var found: [AXUIElement] = []
            func collect(_ e: AXUIElement, _ d: Int) {
                guard d <= 3, found.count < 40 else { return }
                if isRadio(e) { found.append(e); return }
                for k in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { collect(k, d + 1) }
            }
            collect(c, 0)
            if found.count >= 2 { return found }
            container = attr(c, kAXParentAttribute)
        }
        return [radio]
    }

    /// A dropdown's options when its menu is in the tree (most native pop-ups, Chrome's selects).
    static func menuOptions(of popup: AXUIElement) -> [String] {
        var out: [String] = []
        let kids: [AXUIElement] = attr(popup, kAXChildrenAttribute) ?? []
        for k in kids {
            let role: String = attr(k, kAXRoleAttribute) ?? ""
            let items: [AXUIElement] = role == "AXMenu" ? (attr(k, kAXChildrenAttribute) ?? []) : (role == "AXMenuItem" ? [k] : [])
            for i in items {
                let t: String? = attr(i, kAXTitleAttribute) ?? attr(i, kAXValueAttribute)
                if let t = t?.nonEmpty, !out.contains(t) { out.append(t) }
                if out.count >= 300 { return out }
            }
        }
        return out
    }

    /// The visible label of a text field: its linked title element, accessible description, title, or help.
    static func label(for el: AXUIElement) -> String? {
        if let titleEl: AXUIElement = attr(el, kAXTitleUIElementAttribute) {
            let v: String? = attr(titleEl, kAXValueAttribute) ?? attr(titleEl, kAXTitleAttribute)
            if let v = v?.nonEmpty { return v }
        }
        for key in [kAXDescriptionAttribute, kAXTitleAttribute, kAXHelpAttribute] {
            let v: String? = attr(el, key)
            if let v = v?.nonEmpty { return v }
        }
        return nil
    }

    static func attr<T>(_ el: AXUIElement, _ name: String) -> T? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(el, name as CFString, &value) == .success, let value else { return nil }
        if T.self == AXUIElement.self {
            return CFGetTypeID(value) == AXUIElementGetTypeID() ? (value as! T) : nil
        }
        return value as? T
    }

    // MARK: Filling

    /// Focuses the field, selects what's in it, and replaces it. Normal text is pasted (fast, and fires the
    /// page's input events); secret values are typed so they never touch the clipboard.
    static func fill(_ field: FormField, with value: String, app: AXUIElement) async -> Bool {
        AXUIElementSetAttributeValue(field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(90))
        guard let focused: AXUIElement = attr(app, kAXFocusedUIElementAttribute), CFEqual(focused, field.element) else {
            return false
        }
        key(0, flags: .maskCommand) // ⌘A: select the field's current text
        try? await Task.sleep(for: .milliseconds(40))
        if field.sensitive != nil {
            type(value)
        } else {
            let pb = NSPasteboard.general
            pb.clearContents()
            pb.setString(value, forType: .string)
            // Ask clipboard managers not to keep this.
            pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
            key(9, flags: .maskCommand) // ⌘V
        }
        try? await Task.sleep(for: .milliseconds(120))
        return true
    }

    /// Keys only ever go to the app the form is in: if you switched apps, Shapr stops typing.
    static func appIsFront(_ app: AXUIElement) -> Bool {
        var pid: pid_t = 0
        AXUIElementGetPid(app, &pid)
        return NSWorkspace.shared.frontmostApplication?.processIdentifier == pid
    }

    /// Ticks or unticks a checkbox, picks a radio button or a dropdown option, or enters a date.
    static func fill(choice field: FormField, with value: String, app: AXUIElement) async -> Bool {
        switch field.kind {
        case .checkbox:
            let want = value.lowercased() == "yes"
            let now = (attr(field.element, kAXValueAttribute) as NSNumber?)?.intValue == 1
            if want != now { AXUIElementPerformAction(field.element, kAXPressAction as CFString) }
            try? await Task.sleep(for: .milliseconds(80))
            return ((attr(field.element, kAXValueAttribute) as NSNumber?)?.intValue == 1) == want
        case .choice where !field.optionElements.isEmpty:
            guard let i = field.options.firstIndex(of: value), i < field.optionElements.count else { return false }
            AXUIElementPerformAction(field.optionElements[i], kAXPressAction as CFString)
            try? await Task.sleep(for: .milliseconds(80))
            return true
        case .choice:
            return await pick(value, in: field.element, app: app)
        case .date:
            return await enterDate(value, in: field, app: app)
        case .text:
            return await fill(field, with: value, app: app)
        }
    }

    /// Opens a dropdown, presses the matching item, and checks that it took.
    private static func pick(_ value: String, in popup: AXUIElement, app: AXUIElement) async -> Bool {
        let before: String? = attr(popup, kAXValueAttribute) ?? attr(popup, kAXTitleAttribute)
        if before == value { return true }
        AXUIElementPerformAction(popup, kAXPressAction as CFString)
        try? await Task.sleep(for: .milliseconds(250))
        // The open menu hangs off the pop-up, or off the app as its own menu.
        var menus: [AXUIElement] = (attr(popup, kAXChildrenAttribute) as [AXUIElement]?)?.filter { (attr($0, kAXRoleAttribute) as String?) == "AXMenu" } ?? []
        menus += (attr(app, kAXChildrenAttribute) as [AXUIElement]?)?.filter { (attr($0, kAXRoleAttribute) as String?) == "AXMenu" } ?? []
        for m in menus {
            let items: [AXUIElement] = attr(m, kAXChildrenAttribute) ?? []
            if let item = items.first(where: { ((attr($0, kAXTitleAttribute) as String?) ?? "") == value }) {
                AXUIElementPerformAction(item, kAXPressAction as CFString)
                try? await Task.sleep(for: .milliseconds(150))
                let after: String? = attr(popup, kAXValueAttribute) ?? attr(popup, kAXTitleAttribute)
                return after == value || after == nil
            }
        }
        // No menu in the tree (Safari's web selects): close it, then type the option to select it.
        guard appIsFront(app) else { return false }
        key(53, flags: []) // Escape
        try? await Task.sleep(for: .milliseconds(120))
        AXUIElementSetAttributeValue(popup, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(80))
        for ch in value {
            guard appIsFront(app) else { return false }
            type(String(ch))
            try? await Task.sleep(for: .milliseconds(25))
        }
        try? await Task.sleep(for: .milliseconds(200))
        let after: String? = attr(popup, kAXValueAttribute) ?? attr(popup, kAXTitleAttribute)
        return after == value
    }

    /// Dates: typed into the field's own parts in its own order (month/day/year on a US page), with real
    /// number keys. A native date picker with no parts is set directly.
    private static func enterDate(_ value: String, in field: FormField, app: AXUIElement) async -> Bool {
        guard let date = DateEntry.parse(value) else { return false }
        let parts = dateParts(field.element)
        if parts.isEmpty {
            var settable: DarwinBoolean = false
            if AXUIElementIsAttributeSettable(field.element, kAXValueAttribute as CFString, &settable) == .success, settable.boolValue,
               AXUIElementSetAttributeValue(field.element, kAXValueAttribute as CFString, date as CFDate) == .success {
                return true
            }
        }
        let digitKeys: [Character: CGKeyCode] = ["0": 29, "1": 18, "2": 19, "3": 20, "4": 21, "5": 23, "6": 22, "7": 26, "8": 28, "9": 25]
        func press(_ digits: String) async -> Bool {
            for ch in digits {
                guard appIsFront(app) else { return false }
                if let code = digitKeys[ch] { key(code, flags: []) } else { type(String(ch)) }
                try? await Task.sleep(for: .milliseconds(45))
            }
            return true
        }
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        if !parts.isEmpty {
            // Each part on its own: focus it, then type its digits (some fields don't move on by themselves).
            for part in parts {
                let digits = part.unit == "y" ? String(format: "%04d", c.year ?? 2000)
                           : part.unit == "M" ? String(format: "%02d", c.month ?? 1) : String(format: "%02d", c.day ?? 1)
                AXUIElementSetAttributeValue(part.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
                try? await Task.sleep(for: .milliseconds(90))
                guard await press(digits) else { return false }
            }
            try? await Task.sleep(for: .milliseconds(120))
            return true
        }
        AXUIElementSetAttributeValue(field.element, kAXFocusedAttribute as CFString, kCFBooleanTrue)
        try? await Task.sleep(for: .milliseconds(120))
        let ok = await press(DateEntry.keystrokes(for: date))
        try? await Task.sleep(for: .milliseconds(120))
        return ok
    }

    /// A date field's parts in on-screen order: "M", "d" or "y" for each (Safari and Chrome expose them).
    static func dateParts(_ el: AXUIElement) -> [(unit: Character, element: AXUIElement)] {
        var out: [(Character, AXUIElement)] = []
        func walk(_ e: AXUIElement, _ depth: Int) {
            guard depth < 5, out.count < 3 else { return }
            let role: String = attr(e, kAXRoleAttribute) ?? ""
            if role == "AXIncrementor" || role == "AXTextField" || role == "AXSpinButton" {
                let name = ((attr(e, kAXDescriptionAttribute) as String?) ?? (attr(e, kAXTitleAttribute) as String?) ?? "").lowercased()
                if name.contains("month") { out.append(("M", e)); return }
                if name.contains("day") { out.append(("d", e)); return }
                if name.contains("year") { out.append(("y", e)); return }
            }
            for k in (attr(e, kAXChildrenAttribute) as [AXUIElement]?) ?? [] { walk(k, depth + 1) }
        }
        walk(el, 0)
        return Set(out.map(\.0)).count == out.count ? out : []
    }

    private static func key(_ code: CGKeyCode, flags: CGEventFlags) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let down = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: code, keyDown: false)
        down?.flags = flags
        up?.flags = flags
        down?.post(tap: .cghidEventTap)
        up?.post(tap: .cghidEventTap)
    }

    /// Types text as keyboard input, a few characters per event.
    private static func type(_ text: String) {
        let src = CGEventSource(stateID: .combinedSessionState)
        let units = Array(text.utf16)
        var i = 0
        while i < units.count {
            let chunk = Array(units[i..<min(i + 16, units.count)])
            for down in [true, false] {
                let e = CGEvent(keyboardEventSource: src, virtualKey: 0, keyDown: down)
                e?.flags = []
                chunk.withUnsafeBufferPointer { e?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: $0.baseAddress) }
                e?.post(tap: .cghidEventTap)
            }
            i += 16
        }
    }
}

/// Turning an answer into what a date field expects.
enum DateEntry {
    static func parse(_ s: String) -> Date? {
        let t = s.trimmingCharacters(in: .whitespaces)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = .current
        for fmt in ["yyyy-MM-dd", "yyyy/MM/dd", "MM/dd/yyyy", "d MMMM yyyy", "MMMM d, yyyy", "MMM d, yyyy", "d MMM yyyy"] {
            f.dateFormat = fmt
            if let d = f.date(from: t) { return d }
        }
        if let det = try? NSDataDetector(types: NSTextCheckingResult.CheckingType.date.rawValue),
           let m = det.firstMatch(in: t, range: NSRange(t.startIndex..., in: t)) { return m.date }
        return nil
    }

    /// Digits in the field's order when known, else this region's: month-day-year in the US,
    /// day-month-year in most places, year first in some.
    static func keystrokes(for date: Date, order known: [Character]? = nil, locale: Locale = .current) -> String {
        let pattern = DateFormatter.dateFormat(fromTemplate: "yMMdd", options: 0, locale: locale) ?? "MM/dd/y"
        let c = Calendar(identifier: .gregorian).dateComponents([.year, .month, .day], from: date)
        let y = String(format: "%04d", c.year ?? 2000), m = String(format: "%02d", c.month ?? 1), d = String(format: "%02d", c.day ?? 1)
        let order = known ?? pattern.compactMap { ch -> Character? in "yMd".contains(ch) ? ch : nil }
        var seen: [Character] = []
        for ch in order where !seen.contains(ch) { seen.append(ch) }
        return seen.map { $0 == "y" ? y : $0 == "M" ? m : d }.joined()
    }
}
