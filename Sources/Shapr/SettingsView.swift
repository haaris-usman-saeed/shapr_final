import AppKit
import AVFoundation
import SwiftUI

/// Settings, grouped like a Mac settings window: General, Shortcuts, AI, Privacy, Connections.
/// Shows real permission and connection state, and never shows the API key itself.
struct SettingsView: View {
    enum Tab: String, CaseIterable, Identifiable {
        case general, shortcuts, ai, privacy, connections
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "General"
            case .shortcuts: return "Shortcuts"
            case .ai: return "AI"
            case .privacy: return "Privacy"
            case .connections: return "Connections"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "gearshape"
            case .shortcuts: return "keyboard"
            case .ai: return "sparkles"
            case .privacy: return "lock.shield"
            case .connections: return "link"
            }
        }
    }

    @State var tab: Tab = .general
    @State private var engine = SorterSettings.engine
    @State private var model = SorterSettings.model
    @State private var keyField = ""
    @State private var keyTail: String? = Keychain.get(SorterSettings.keychainAccount).map { String($0.suffix(4)) }
    @State private var testResult: (ok: Bool, text: String)?
    @State private var testing = false
    @State private var desktopAdded = MCPSetup.isInClaudeDesktop
    @State private var connectNote: String?
    @State private var circleKey = DoubleTapDetector.Key.current
    @State private var screenAllowed = ScreenCapture.hasPermission
    @State private var axAllowed = AXIsProcessTrusted()
    @State private var vaultItems = Vault.items
    @State private var newKind: SensitiveKind = .cardNumber
    @State private var newLabel = ""
    @State private var newSite = ""
    @State private var newValue = ""
    @State private var suggestOpened = SuggestionSettings.opened
    @State private var suggestDownloads = SuggestionSettings.downloads
    @State private var neverFolders = SuggestionSettings.neverFolders
    @State private var autoUpdate = Updater.auto
    @State private var watchLimits = RelaySettings.watchLimits
    @State private var askBack = RelaySettings.askBack
    @State private var readBack = RelaySettings.readBack
    @State private var serverField = UserDefaults.standard.string(forKey: ShareServer.defaultsKey) ?? ""
    @State private var autoPick = PackRouter.enabled
    @State private var keepAudio = VoiceSettings.keepAudio
    @State private var voiceCommands = VoiceSettings.commands
    @State private var readAnswers = VoiceSettings.readAnswers
    @State private var classicKeys = ShortcutSettings.classic
    @State private var micStatus = VoiceSettings.micStatus
    @State private var githubField = ""
    @State private var githubTail: String? = Keychain.get(SourceSync.githubAccount).map { String($0.suffix(4)) }
    @State private var notionField = ""
    @State private var notionTail: String? = Keychain.get(SourceSync.notionAccount).map { String($0.suffix(4)) }
    let appleStatus: String
    var onCheckUpdates: () -> Void = {}
    var onDone: () -> Void = {}

    static let size = CGSize(width: 780, height: 600)

    /// A sidebar of pages and the page beside it, like System Settings (CodeEdit's layout).
    var body: some View {
        NavigationSplitView {
            List(selection: Binding(get: { Optional(tab) }, set: { if let t = $0 { tab = t } })) {
                ForEach(Tab.allCases) { t in
                    Label(t.title, systemImage: t.symbol).tag(t)
                }
            }
            .navigationSplitViewColumnWidth(190)
            .toolbar(removing: .sidebarToggle)
        } detail: {
            Group {
                switch tab {
                case .general: general
                case .shortcuts: shortcuts
                case .ai: ai
                case .privacy: privacy
                case .connections: connections
                }
            }
            .formStyle(.grouped)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle(tab.title)
        }
        .frame(width: Self.size.width, height: Self.size.height)
        .background { Button("", action: onDone).keyboardShortcut(.cancelAction).hidden() }
        .onReceive(Timer.publish(every: 2, on: .main, in: .common).autoconnect()) { _ in
            screenAllowed = ScreenCapture.hasPermission
            axAllowed = AXIsProcessTrusted()
            micStatus = VoiceSettings.micStatus
        }
    }

    // MARK: General

    private var general: some View {
        Form {
            Section {
                PermissionLine(title: "Accessibility", detail: "Scoop, Drop and Fill read and paste text through it.",
                               granted: axAllowed, action: "Open Settings") {
                    CaptureService.requestTrust()
                    CaptureService.openAccessibilitySettings()
                }
                PermissionLine(title: "Screen Recording", detail: "Circle capture takes a screenshot of the area. Reopen Shapr after allowing.",
                               granted: screenAllowed, action: "Allow…") {
                    ScreenCapture.requestPermission()
                    ScreenCapture.openSettings()
                }
            } header: {
                Text("Permissions")
            }

            Section {
                Picker("Sort with", selection: $engine) {
                    ForEach(SortEngine.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: engine) { _, v in SorterSettings.engine = v }
                if engine == .onDevice {
                    note("Runs on this Mac. Nothing you capture leaves your computer. Status: \(appleStatus).", symbol: "lock.laptopcomputer")
                } else {
                    note(keyTail == nil ? "Add your Claude API key under AI first. Until then Shapr sorts on this Mac."
                                        : "Captured text and its source are sent to Anthropic's API to pick a pack.",
                         symbol: "exclamationmark.triangle", color: DS.warning)
                }
                Toggle("Pick the pack from where I am", isOn: $autoPick)
                    .onChange(of: autoPick) { _, v in PackRouter.enabled = v }
            } header: {
                Text("Auto-sort")
            } footer: {
                Text("When no pack is equipped, Shapr picks one for each capture, and asks the first time a capture joins an existing pack. Picking from where you are: an email from someone at acme.com goes with your Acme pack, and so does a draft you write to them. It uses who sent it, the site, repo or folder, and the packs you chose there before, all on this Mac.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }

            Section {
                PermissionLine(title: "Microphone", detail: "Hold ⌥V and talk. Speech is turned into text on this Mac; nothing is sent anywhere.",
                               granted: micStatus == .authorized, action: micStatus == .notDetermined ? "Allow…" : "Open Settings") {
                    if micStatus == .notDetermined {
                        AVCaptureDevice.requestAccess(for: .audio) { _ in }
                    } else {
                        VoiceSettings.openMicSettings()
                    }
                }
                Toggle("Run commands I say (“fill this form”, “switch to Acme”)", isOn: $voiceCommands)
                    .onChange(of: voiceCommands) { _, v in VoiceSettings.commands = v }
                Toggle("Read answers aloud when I ask out loud", isOn: $readAnswers)
                    .onChange(of: readAnswers) { _, v in VoiceSettings.readAnswers = v }
                Toggle("Keep the recording with each voice note", isOn: $keepAudio)
                    .onChange(of: keepAudio) { _, v in VoiceSettings.keepAudio = v }
            } header: {
                Text("Talk to Shapr")
            } footer: {
                Text("Hold ⌥V, speak, and let go. Commands run (“draft a reply saying I'm in”, “ask Acme when it's due”, “fill this form”, “save this to Acme”, “continue in ChatGPT”), questions go to Ask, and anything else is saved as a voice note. Say “what can I say” for more. Tap ⌥V instead to keep talking until you tap it again.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }

            Section {
                Toggle("Offer to continue when a free AI runs out of messages", isOn: $watchLimits)
                    .onChange(of: watchLimits) { _, v in RelaySettings.watchLimits = v }
                Toggle("Let the next AI ask Shapr for more (“@shapr S3”)", isOn: $askBack)
                    .onChange(of: askBack) { _, v in RelaySettings.askBack = v }
                Toggle("Check that it read everything", isOn: $readBack)
                    .onChange(of: readBack) { _, v in RelaySettings.readBack = v }
            } header: {
                Text("Moving between AIs")
            } footer: {
                Text("Works with the free versions of ChatGPT, Claude and Gemini: Shapr reads the chat on your screen and pastes into the message box. Nothing is sent to the new AI until you press Return, and nothing leaves this Mac otherwise.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }

            Section("Updates") {
                LabeledContent("Version", value: "\(Updater.currentVersion) (\(Updater.currentBuild))")
                Toggle("Check for updates automatically", isOn: $autoUpdate)
                    .onChange(of: autoUpdate) { _, v in Updater.auto = v }
                Button("Check Now", action: onCheckUpdates)
            }

            Section {
                Toggle("Suggest files you open", isOn: $suggestOpened)
                    .onChange(of: suggestOpened) { _, v in SuggestionSettings.opened = v }
                Toggle("Suggest new downloads", isOn: $suggestDownloads)
                    .onChange(of: suggestDownloads) { _, v in SuggestionSettings.downloads = v }
                ForEach(neverFolders, id: \.self) { folder in
                    HStack {
                        Label((folder as NSString).abbreviatingWithTildeInPath, systemImage: "folder.badge.minus")
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Ask again") {
                            neverFolders.removeAll { $0 == folder }
                            SuggestionSettings.neverFolders = neverFolders
                        }
                    }
                }
            } header: {
                Text("File suggestions")
            } footer: {
                Text("While you work on a pack, Shapr offers to add documents and code files you open or download. It asks once per file, at most once a minute, decides on this Mac, and reads nothing until you click Add.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
        }
    }

    // MARK: Shortcuts

    private var shortcuts: some View {
        Form {
            Section {
                LabeledContent("Talk to Shapr (hold, then say anything)") { Keycap(keys: "⌥V") }
                LabeledContent("Scoop the highlighted text") { Keycap(keys: "⌥C") }
                LabeledContent("Open the wheel (hold, point, let go)") { Keycap(keys: "⌥S") }
                Toggle("Also use classic shortcuts (⌥⇧D draft, ⌥⇧F fill, ⌥⇧A ask, ⌥⇧Space…)", isOn: $classicKeys)
                    .onChange(of: classicKeys) { _, v in ShortcutSettings.classic = v }
            } header: {
                Text("Voice first")
            } footer: {
                Text("Everything else is one sentence away: hold ⌥V and say “draft a reply saying I'm in”, “fill this form”, “ask Acme when it's due”, “switch to Acme” or “what can I say”.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            Section {
                Picker("Circle to capture", selection: $circleKey) {
                    ForEach(DoubleTapDetector.Key.allCases) { Text($0.title).tag($0) }
                }
                .onChange(of: circleKey) { _, v in DoubleTapDetector.Key.current = v }
            } footer: {
                Text("Double-tap, then circle anything with your pointer. No clicking: a short trail follows the pointer, and Shapr captures when you pause. If the double-tap clashes with another app, pick a different key.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            Section("All shortcuts") {
                ForEach(ShortcutsList.items, id: \.0) { label, keys in
                    LabeledContent(label) { Keycap(keys: keys) }
                }
            }
        }
    }

    // MARK: AI

    private var ai: some View {
        Form {
            Section {
                if let tail = keyTail {
                    LabeledContent("API key") {
                        HStack(spacing: 8) {
                            Label("Saved in Keychain · ends in \(tail)", systemImage: "checkmark.circle.fill")
                                .foregroundStyle(DS.success)
                                .labelStyle(.titleAndIcon)
                            Button("Remove", role: .destructive) {
                                Keychain.set(nil, account: SorterSettings.keychainAccount)
                                keyTail = nil
                                testResult = nil
                            }
                        }
                    }
                }
                HStack {
                    SecureField(keyTail == nil ? "API key" : "Replace key", text: $keyField,
                                prompt: Text("sk-ant-…"))
                    Button("Save") {
                        Keychain.set(keyField.trimmingCharacters(in: .whitespacesAndNewlines), account: SorterSettings.keychainAccount)
                        keyTail = Keychain.get(SorterSettings.keychainAccount).map { String($0.suffix(4)) }
                        keyField = ""
                        testResult = nil
                    }
                    .disabled(keyField.nonEmpty == nil)
                }
                Picker("Model", selection: $model) {
                    ForEach(SorterSettings.models, id: \.id) { Text($0.title).tag($0.id) }
                }
                .onChange(of: model) { _, v in SorterSettings.model = v }
                HStack {
                    Button(testing ? "Testing…" : "Test connection") { test() }
                        .disabled(keyTail == nil || testing)
                    if testing { ProgressView().controlSize(.small) }
                    if let r = testResult {
                        StatusLine(tone: r.ok ? .success : .error, text: r.text)
                    }
                }
            } header: {
                Text("Claude")
            } footer: {
                Text("Optional. Used to write drafts and checkpoints, and to sort when Auto-sort is set to Claude. The pack you draft from is sent to Anthropic's API, and you pay for usage on your key. Without a key, Shapr uses Apple Intelligence on this Mac.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            Section("On this Mac") {
                LabeledContent("Apple Intelligence", value: appleStatus)
            }
        }
    }

    // MARK: Privacy

    private var privacy: some View {
        Form {
            Section {
                Button("Open Privacy & Memory…") { (NSApp.delegate as? AppController)?.flow.showPrivacy() }
            } header: {
                Text("Shapr Flow: working sessions")
            } footer: {
                Text("Which apps Shapr may observe during a session, what it remembers, how long, and where AI runs. Delete anything there.")
            }
            Section {
                if vaultItems.isEmpty {
                    Text("Nothing in your Vault yet.").foregroundStyle(DS.text2)
                }
                ForEach(vaultItems) { item in
                    HStack(spacing: 10) {
                        Image(systemName: item.kind.symbol).foregroundStyle(DS.text2).frame(width: 18)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(item.label)
                            Text([item.kind.title, item.site].compactMap { $0 }.joined(separator: " · "))
                                .font(.dsMeta).foregroundStyle(DS.text2)
                        }
                        Spacer()
                        Text("••••••••").foregroundStyle(DS.text3)
                        Button(role: .destructive) {
                            Vault.delete(item.id)
                            vaultItems = Vault.items
                        } label: { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Remove from the Vault")
                        .accessibilityLabel("Remove \(item.label) from the Vault")
                    }
                }
            } header: {
                Text("Vault: passwords, cards and IDs")
            } footer: {
                Text("Kept in your Mac's Keychain, never in packs. Shapr asks for Touch ID or your Mac password before filling them, types them instead of using the clipboard, and never sends them to any AI.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            Section("Add to the Vault") {
                Picker("Type", selection: $newKind) {
                    ForEach(SensitiveKind.allCases) { Text($0.title).tag($0) }
                }
                TextField("Name", text: $newLabel, prompt: Text(newKind == .password ? "e.g. Work email" : "e.g. Chase Visa"))
                if newKind == .password {
                    TextField("Website", text: $newSite, prompt: Text("e.g. github.com"))
                }
                HStack {
                    SecureField("Value", text: $newValue, prompt: Text("Stored only in your Keychain"))
                    Button("Add") {
                        Vault.add(kind: newKind, label: newLabel, site: newKind == .password ? newSite : nil, value: newValue)
                        vaultItems = Vault.items
                        newLabel = ""; newSite = ""; newValue = ""
                    }
                    .disabled(newLabel.nonEmpty == nil || newValue.nonEmpty == nil)
                }
            }
            Section {
                note("Share Safely checks a pack for names, emails, keys and links on this Mac, and changes only the shared copy.",
                     symbol: "hand.raised")
            }
        }
    }

    // MARK: Connections

    private var connections: some View {
        Form {
            Section {
                LabeledContent("Claude Desktop") {
                    HStack(spacing: 8) {
                        if desktopAdded {
                            Label("Connected", systemImage: "checkmark.circle.fill").foregroundStyle(DS.success)
                        }
                        Button(desktopAdded ? "Update" : "Add Shapr") { addToDesktop() }
                    }
                }
                LabeledContent("Claude Code") {
                    Button("Copy command") { copy(MCPSetup.claudeCodeCommand, "Paste it into your terminal.") }
                }
                LabeledContent("Cursor and other apps") {
                    Button("Copy config") { copy(MCPSetup.configSnippet, "Paste it into the app's MCP settings.") }
                }
                if let connectNote {
                    StatusLine(tone: .info, text: connectNote)
                }
            } header: {
                Text("Let Claude use your packs")
            } footer: {
                Text("Claude can then list, read and search your packs, and save a new pack when you ask, for example “make a context pack from this chat”. It runs on this Mac and only touches ~/Shapr/Packs.")
                    .font(.dsMeta).foregroundStyle(DS.text2)
            }
            liveSourcesSection
            shareServerSection
        }
    }

    private var liveSourcesSection: some View {
        Section {
            tokenRow(title: "GitHub token", tail: $githubTail, field: $githubField, account: SourceSync.githubAccount, prompt: "github_pat_…")
            tokenRow(title: "Notion token", tail: $notionTail, field: $notionField, account: SourceSync.notionAccount, prompt: "ntn_…")
        } header: {
            Text("Live sources")
        } footer: {
            Text("Packs can keep themselves up to date from a folder, a GitHub repo, a Notion page or a web page (pack menu → Keep Updated From). Public repos and pages need nothing here. For a private repo, make a fine-grained GitHub token with read access to it. For Notion, create an internal integration at notion.so/my-integrations, paste its secret here, then add the integration to each page (••• → Connections). Tokens stay in your Keychain.")
                .font(.dsMeta).foregroundStyle(DS.text2)
        }
    }

    @ViewBuilder
    private func tokenRow(title: String, tail: Binding<String?>, field: Binding<String>, account: String, prompt: String) -> some View {
        if let t = tail.wrappedValue {
            LabeledContent(title) {
                HStack(spacing: 8) {
                    Label("Saved in Keychain · ends in \(t)", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(DS.success).labelStyle(.titleAndIcon)
                    Button("Remove", role: .destructive) {
                        Keychain.set(nil, account: account)
                        tail.wrappedValue = nil
                    }
                }
            }
        } else {
            HStack {
                SecureField(title, text: field, prompt: Text(prompt))
                Button("Save") {
                    Keychain.set(field.wrappedValue.trimmingCharacters(in: .whitespacesAndNewlines), account: account)
                    tail.wrappedValue = Keychain.get(account).map { String($0.suffix(4)) }
                    field.wrappedValue = ""
                }
                .disabled(field.wrappedValue.nonEmpty == nil)
            }
        }
    }

    // MARK: Helpers

    private var shareServerSection: some View {
        Section {
            LabeledContent("Server") {
                HStack {
                    TextField("", text: $serverField, prompt: Text(ShareServer.base.absoluteString))
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 240)
                    Button("Save") {
                        let v = serverField.trimmingCharacters(in: .whitespacesAndNewlines)
                        if v.isEmpty || URL(string: v)?.scheme?.hasPrefix("http") == true {
                            UserDefaults.standard.set(v.isEmpty ? nil : v, forKey: ShareServer.defaultsKey)
                            connectNote = v.isEmpty ? "Using the built-in server again." : "Saved. New links use \(v)."
                        } else {
                            connectNote = "That isn't a web address."
                        }
                    }
                }
            }
        } header: {
            Text("Shared packs")
        } footer: {
            Text("Live links and the packs you add from them use this server. Leave it empty to use the one Shapr came with.")
                .font(.dsMeta).foregroundStyle(DS.text2)
        }
    }

    private func note(_ text: String, symbol: String, color: Color = DS.text2) -> some View {
        Label(text, systemImage: symbol)
            .font(.dsCallout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func copy(_ s: String, _ hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(s, forType: .string)
        connectNote = "Copied. \(hint)"
    }

    private func addToDesktop() {
        do {
            try MCPSetup.addToClaudeDesktop()
            desktopAdded = true
            connectNote = "Added. Quit and reopen Claude Desktop to see Shapr's tools. Your old config was saved as claude_desktop_config.json.bak."
        } catch {
            connectNote = error.localizedDescription
        }
    }

    private func test() {
        guard let key = SorterSettings.apiKey else { return }
        testing = true
        testResult = nil
        Task {
            do {
                let json = try await ClaudeClient(apiKey: key, model: model).structured(
                    system: Sorter.instructions,
                    prompt: Sorter.sortPrompt(CaptureDraft(text: "The new BMW M3 has an 8-speed automatic gearbox."), packs: []),
                    schema: ClaudeClient.choiceSchema)
                testResult = (true, "Works. It suggested “\(json["topic_name"] as? String ?? "?")”.")
            } catch {
                testResult = (false, error.localizedDescription)
            }
            testing = false
        }
    }
}

/// A permission with its real state and the one action that fixes it.
private struct PermissionLine: View {
    let title: String
    let detail: String
    let granted: Bool
    let action: String
    let run: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                .foregroundStyle(granted ? DS.success : DS.warning)
            VStack(alignment: .leading, spacing: 1) {
                Text(title + (granted ? ": on" : ": off"))
                Text(detail).font(.dsMeta).foregroundStyle(DS.text2).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if !granted { Button(action, action: run) }
        }
        .accessibilityElement(children: .combine)
    }
}

extension MCPServer.ToolError: LocalizedError {
    var errorDescription: String? { message }
}
