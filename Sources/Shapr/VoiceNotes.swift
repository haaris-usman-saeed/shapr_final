import AppKit
import AVFoundation
import Carbon
import Speech
import SwiftUI
import os

let voiceLog = Logger(subsystem: "app.shapr.Shapr", category: "voice")

enum VoiceSettings {
    static var keepAudio: Bool {
        get { UserDefaults.standard.object(forKey: "voiceKeepAudio") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceKeepAudio") }
    }

    /// Answers to questions you asked out loud are read out loud.
    static var readAnswers: Bool {
        get { UserDefaults.standard.object(forKey: "voiceReadAnswers") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceReadAnswers") }
    }

    /// What you say can be a command ("fill this form") or a question, not just a note.
    static var commands: Bool {
        get { UserDefaults.standard.object(forKey: "voiceCommands") as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: "voiceCommands") }
    }

    static var micStatus: AVAuthorizationStatus { AVCaptureDevice.authorizationStatus(for: .audio) }

    static func openMicSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Microphone") {
            NSWorkspace.shared.open(url)
        }
    }
}

struct VoiceError: LocalizedError {
    let message: String
    init(_ m: String) { message = m }
    var errorDescription: String? { message }
}

// MARK: - Recording and transcribing

/// Records from the microphone and turns speech into text on this Mac (Apple's SpeechAnalyzer),
/// with live text as you talk. Optionally keeps the recording as an .m4a file.
final class VoiceRecorder: @unchecked Sendable {
    private let engine = AVAudioEngine()
    private var analyzer: SpeechAnalyzer?
    private var input: AsyncStream<AnalyzerInput>.Continuation?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var targetFormat: AVAudioFormat?
    private var file: AVAudioFile?
    private let lock = NSLock()
    private var finalized = ""
    private var volatile = ""
    private(set) var audioURL: URL?

    var onText: (@Sendable (String) -> Void)?
    var onLevel: (@Sendable (Float) -> Void)?
    var onStatus: (@Sendable (String) -> Void)?

    var text: String {
        lock.lock(); defer { lock.unlock() }
        return (finalized + volatile).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// The speech model for this Mac's language, downloaded the first time.
    static func transcriber(locale: Locale = .current, preset: SpeechTranscriber.Preset = .progressiveTranscription,
                            status: (@Sendable (String) -> Void)? = nil) async throws -> SpeechTranscriber {
        var supported = await SpeechTranscriber.supportedLocale(equivalentTo: locale)
        if supported == nil { supported = await SpeechTranscriber.supportedLocale(equivalentTo: Locale(identifier: "en-US")) }
        guard let loc = supported else {
            throw VoiceError("Speech to text isn't available on this Mac")
        }
        let t = SpeechTranscriber(locale: loc, preset: preset)
        if let req = try await AssetInventory.assetInstallationRequest(supporting: [t]) {
            status?("Getting the speech model ready (first time only)…")
            try await req.downloadAndInstall()
        }
        return t
    }

    func start(keepAudio: Bool) async throws {
        let transcriber = try await Self.transcriber(status: onStatus)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        self.analyzer = analyzer
        let node = engine.inputNode
        let hw = node.outputFormat(forBus: 0)
        guard hw.sampleRate > 0, hw.channelCount > 0 else { throw VoiceError("No microphone found") }
        let target = await SpeechAnalyzer.bestAvailableAudioFormat(compatibleWith: [transcriber], considering: hw) ?? hw
        targetFormat = target
        try await analyzer.prepareToAnalyze(in: target)
        if hw != target { converter = AVAudioConverter(from: hw, to: target) }

        if keepAudio {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("Voice note \(UUID().uuidString.prefix(8)).m4a")
            file = try? AVAudioFile(forWriting: url, settings: [AVFormatIDKey: kAudioFormatMPEG4AAC,
                                                                AVSampleRateKey: hw.sampleRate,
                                                                AVNumberOfChannelsKey: hw.channelCount,
                                                                AVEncoderBitRateKey: 64_000],
                                    commonFormat: hw.commonFormat, interleaved: hw.isInterleaved)
            audioURL = file == nil ? nil : url
        }

        let (stream, cont) = AsyncStream<AnalyzerInput>.makeStream()
        input = cont
        resultsTask = Task { [weak self] in
            do {
                for try await r in transcriber.results {
                    guard let self else { return }
                    self.add(String(r.text.characters), final: r.isFinal)
                    self.onText?(self.text)
                }
            } catch {
                voiceLog.error("transcription stopped: \(error.localizedDescription, privacy: .public)")
            }
        }
        node.installTap(onBus: 0, bufferSize: 4096, format: hw) { [weak self] buf, _ in self?.handle(buf) }
        engine.prepare()
        try engine.start()
        try await analyzer.start(inputSequence: stream)
    }

    private func add(_ piece: String, final: Bool) {
        lock.lock(); defer { lock.unlock() }
        if final { finalized += piece; volatile = "" } else { volatile = piece }
    }

    private func handle(_ buf: AVAudioPCMBuffer) {
        try? file?.write(from: buf)
        if let ch = buf.floatChannelData?[0], buf.frameLength > 0 {
            var sum: Float = 0
            for i in 0..<Int(buf.frameLength) { sum += ch[i] * ch[i] }
            let rms = (sum / Float(buf.frameLength)).squareRoot()
            onLevel?(min(1, rms * 12))
        }
        guard let converter, let target = targetFormat else { input?.yield(AnalyzerInput(buffer: buf)); return }
        let cap = AVAudioFrameCount(Double(buf.frameLength) * target.sampleRate / buf.format.sampleRate) + 1024
        guard let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap) else { return }
        var fed = false
        var err: NSError?
        converter.convert(to: out, error: &err) { _, status in
            if fed { status.pointee = .noDataNow; return nil }
            fed = true
            status.pointee = .haveData
            return buf
        }
        if err == nil, out.frameLength > 0 { input?.yield(AnalyzerInput(buffer: out)) }
    }

    /// Stops listening and returns everything that was said.
    func stop() async -> String {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        try? await analyzer?.finalizeAndFinishThroughEndOfInput()
        if let t = resultsTask {
            // The results end when the analyzer finishes; don't wait forever if they don't.
            await withTaskGroup(of: Void.self) { g in
                g.addTask { await t.value }
                g.addTask { try? await Task.sleep(for: .seconds(4)) }
                await g.next()
                g.cancelAll()
            }
        }
        file = nil // closes the .m4a
        return text
    }

    func cancel() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        input?.finish()
        resultsTask?.cancel()
        Task { [analyzer] in await analyzer?.cancelAndFinishNow() }
        file = nil
        if let u = audioURL { try? FileManager.default.removeItem(at: u) }
        audioURL = nil
    }

    /// Transcribes an audio file (developer check: `Shapr --transcribe file.aiff`).
    static func transcribe(file url: URL) async throws -> String {
        let t = try await transcriber(locale: Locale(identifier: "en-US"), preset: .transcription)
        let audio = try AVAudioFile(forReading: url)
        let analyzer = try await SpeechAnalyzer(inputAudioFile: audio, modules: [t], finishAfterFile: true)
        var text = ""
        for try await r in t.results where r.isFinal { text += String(r.text.characters) }
        _ = analyzer
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Overlay

@MainActor
final class VoiceModel: ObservableObject {
    @Published var text = ""
    @Published var level: Float = 0
    @Published var status = "Listening…"
    @Published var hint = ""
    @Published var pack: Pack?
    @Published var started = Date()
    @Published var preparing = true
    /// After you let go, while Shapr works out what you said and does it.
    @Published var thinking = false
    /// Tapped instead of held: keeps listening until Done.
    @Published var sticky = false
}

/// The voice card: a Liquid Glass pill next to your cursor, with an orb that moves with your voice,
/// your words as you say them, and what will happen. No buttons while you hold the key.
struct VoiceView: View {
    @ObservedObject var model: VoiceModel
    var onSave: () -> Void = {}
    var onCancel: () -> Void = {}
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var placeholder: String {
        if model.preparing { return model.status }
        return VoiceSettings.commands ? "Say “add this”, or ask anything…" : "Say what you want to remember…"
    }

    var body: some View {
        HStack(spacing: 12) {
            VoiceOrb(level: model.level, busy: model.thinking || model.preparing,
                     color: model.pack.map { PackStyle.deep($0.id) } ?? DS.accentFill, reduceMotion: reduceMotion)
                .frame(width: 42, height: 42)
            VStack(alignment: .leading, spacing: 3) {
                Text(model.text.isEmpty ? placeholder : String(model.text.suffix(180)))
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(model.text.isEmpty ? DS.text2 : DS.text)
                    .lineLimit(2)
                    .truncationMode(.head) // your latest words stay in view
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 5) {
                    if let p = model.pack {
                        PackIcon(pack: p, size: 13)
                        Text(p.name).lineLimit(1)
                        Text("·")
                    }
                    Text(model.thinking ? "Thinking…" : model.hint).lineLimit(1)
                }
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(DS.text3)
            }
            if model.sticky && !model.thinking {
                Button("Done", action: onSave)
                    .buttonStyle(DSButtonStyle(kind: .primary, small: true))
                    .disabled(model.preparing)
            }
        }
        .padding(.leading, 10).padding(.trailing, 16).padding(.vertical, 10)
        .frame(width: 400)
        .glassSurface(RoundedRectangle(cornerRadius: 30, style: .continuous))
        .padding(14)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Talking to Shapr")
    }
}

/// A flat disc with a halo that swells with your voice; a small arc turns on it while Shapr is thinking.
struct VoiceOrb: View {
    let level: Float
    let busy: Bool
    let color: Color
    let reduceMotion: Bool

    var body: some View {
        TimelineView(.animation(paused: reduceMotion)) { ctx in
            let t = ctx.date.timeIntervalSinceReferenceDate
            ZStack {
                Circle().fill(color.opacity(0.18))
                    .scaleEffect(reduceMotion || busy ? 0.86 : 0.8 + CGFloat(min(level, 1)) * 0.36)
                    .animation(.easeOut(duration: 0.12), value: level)
                Circle().fill(color).frame(width: 30, height: 30)
                if busy {
                    Circle()
                        .trim(from: 0, to: reduceMotion ? 1 : 0.3)
                        .stroke(.white.opacity(0.95), style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 16, height: 16)
                        .rotationEffect(.degrees(reduceMotion ? 0 : t * 300))
                } else {
                    Image(systemName: "waveform")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white)
                }
            }
        }
        .accessibilityHidden(true)
    }
}

// MARK: - Controller

/// ⌥V: hold and talk, let go to save. Or tap it once, talk as long as you like, and tap again (or
/// click Save). The note goes to the equipped pack, or Auto-sort picks one.
@MainActor
final class VoiceNoteController {
    enum State { case idle, starting, listening, saving }

    private let toast: ToastController
    private let model = VoiceModel()
    private let panel = FloatingPanel(size: NSSize(width: 472, height: 140), level: .statusBar)
    private var recorder: VoiceRecorder?
    private(set) var state: State = .idle
    private var pressedAt = Date.distantPast
    private var sticky = false
    private var monitors: [Any] = []

    /// The pack the note will go to (shown on the overlay).
    var destination: () -> Pack? = { nil }
    /// Saves the note like any capture; returns the pack it went to.
    var onSave: (CaptureDraft) async -> UUID? = { _ in nil }
    /// Runs what you said if it's a command or a question; returns false to save it as a note.
    var onCommand: (String) async -> Bool = { _ in false }

    init(toast: ToastController) {
        self.toast = toast
        panel.hasShadow = false
        panel.contentView = FirstMouseHostingView(rootView: VoiceView(
            model: model,
            onSave: { [weak self] in MainActor.assumeIsolated { self?.finish() } },
            onCancel: { [weak self] in MainActor.assumeIsolated { self?.cancel() } }
        ))
    }

    func hotkeyDown() {
        switch state {
        case .idle:
            pressedAt = Date()
            sticky = false
            begin()
        case .listening where sticky, .starting where sticky:
            finish()
        default:
            break
        }
    }

    func hotkeyUp() {
        guard state == .listening || state == .starting, !sticky else { return }
        if Date().timeIntervalSince(pressedAt) < 0.45 {
            // A tap: keep listening until the next tap.
            sticky = true
            model.sticky = true
            model.hint = "Tap ⌥V or click Done · esc cancels"
        } else {
            finish()
        }
    }

    private func begin() {
        switch VoiceSettings.micStatus {
        case .denied, .restricted:
            toast.show(ToastContent(icon: .symbol("mic.slash"), title: "Shapr can't use the microphone",
                                    subtitle: "Turn on Shapr under Microphone in System Settings, then try again.",
                                    actions: [ToastAction(title: "Open Settings", style: .primary) { VoiceSettings.openMicSettings() }],
                                    tint: DS.warning), duration: 8)
            return
        case .notDetermined:
            state = .starting
            AVCaptureDevice.requestAccess(for: .audio) { ok in
                Task { @MainActor in
                    self.state = .idle
                    if ok {
                        self.toast.show(ToastContent(icon: .symbol("mic"), title: "Microphone allowed",
                                                     subtitle: "Hold ⌥V and talk to add a voice note."), duration: 4)
                    }
                }
            }
            return
        default:
            break
        }
        state = .starting
        Speaker.stop()
        model.text = ""
        model.level = 0
        model.preparing = true
        model.status = "Starting…"
        model.hint = VoiceSettings.commands ? "Let go when you're done · esc cancels" : "Let go of ⌥V to save · esc cancels"
        model.sticky = false
        model.thinking = false
        model.pack = destination()
        show()
        let r = VoiceRecorder()
        r.onText = { [weak self] t in Task { @MainActor in self?.model.text = t } }
        r.onLevel = { [weak self] l in Task { @MainActor in self?.model.level = l } }
        r.onStatus = { [weak self] s in Task { @MainActor in self?.model.status = s } }
        recorder = r
        Task {
            do {
                try await r.start(keepAudio: VoiceSettings.keepAudio)
                guard state == .starting, recorder === r else { r.cancel(); return }
                state = .listening
                model.preparing = false
                model.started = Date()
                model.status = "Listening"
            } catch {
                voiceLog.error("voice note failed to start: \(error.localizedDescription, privacy: .public)")
                r.cancel()
                hide()
                state = .idle
                toast.show(ToastContent(icon: .symbol("mic.slash"), title: "Couldn't start the voice note",
                                        subtitle: error.localizedDescription, tint: DS.warning), duration: 6)
            }
        }
    }

    func finish() {
        guard let r = recorder, state == .listening || state == .starting else { return }
        if state == .starting {
            // Let go before it was ready: nothing was recorded yet.
            let downloading = model.status.hasPrefix("Getting")
            cancel()
            toast.show(ToastContent(icon: .symbol("waveform"), title: downloading ? "The speech model is still downloading" : "It wasn't listening yet",
                                    subtitle: downloading ? "Try again in a minute. This only happens the first time." : "Hold ⌥V a moment longer before you start talking.",
                                    tint: DS.warning), duration: 4)
            return
        }
        state = .saving
        model.status = "Saving…"
        model.thinking = true
        Task {
            let text = await r.stop()
            recorder = nil
            // Keep the card up, thinking, until Shapr has done what you said.
            defer { hide(); state = .idle; model.thinking = false }
            if let t = text.nonEmpty { model.text = t }
            guard let text = text.nonEmpty else {
                if let u = r.audioURL { try? FileManager.default.removeItem(at: u) }
                toast.show(ToastContent(icon: .symbol("waveform.slash"), title: "Didn't catch anything",
                                        subtitle: "Hold ⌥V and speak, then let go.", tint: DS.warning), duration: 3)
                return
            }
            if VoiceSettings.commands, await onCommand(text) {
                if let u = r.audioURL { try? FileManager.default.removeItem(at: u) }
                return
            }
            let draft = CaptureDraft(text: text, appName: "Voice note", title: Self.title(for: text), attachment: r.audioURL)
            _ = await onSave(draft)
            if let u = r.audioURL { try? FileManager.default.removeItem(at: u) } // the pack keeps its own copy
        }
    }

    func cancel() {
        recorder?.cancel()
        recorder = nil
        state = .idle
        hide()
    }

    /// "Voice note: Call Ana about the Q3 numbers…"
    static func title(for text: String) -> String {
        let first = text.firstLine
        var sentence = first
        first.enumerateSubstrings(in: first.startIndex..., options: .bySentences) { s, _, _, stop in
            if let s = s?.trimmingCharacters(in: .whitespaces).nonEmpty { sentence = s; stop = true }
        }
        return "Voice note: " + sentence.truncated(60)
    }

    private func show() {
        let host = panel.contentView!
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        // Next to the cursor, like a companion: below and to the right, kept on screen.
        let m = NSEvent.mouseLocation
        var origin = CGPoint(x: m.x + 6, y: m.y - size.height - 2)
        if let vf = (NSScreen.underMouse ?? NSScreen.main)?.visibleFrame {
            if origin.x + size.width > vf.maxX { origin.x = m.x - size.width - 6 }
            if origin.y < vf.minY { origin.y = m.y + 10 }
            origin.x = min(max(origin.x, vf.minX), vf.maxX - size.width)
            origin.y = min(max(origin.y, vf.minY), vf.maxY - size.height)
        }
        panel.setFrame(NSRect(origin: origin, size: size), display: true)
        panel.alphaValue = 1
        panel.orderFrontRegardless()
        installMonitors()
    }

    private func hide() {
        monitors.forEach(NSEvent.removeMonitor)
        monitors.removeAll()
        panel.orderOut(nil)
    }

    private func installMonitors() {
        guard monitors.isEmpty else { return }
        let handle: (NSEvent) -> Void = { [weak self] e in
            MainActor.assumeIsolated {
                guard let self else { return }
                if e.keyCode == UInt16(kVK_Escape) { self.cancel() }
                else if e.keyCode == UInt16(kVK_Return), self.sticky { self.finish() }
            }
        }
        if let g = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: handle) { monitors.append(g) }
        if let l = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { e in handle(e); return e }) { monitors.append(l) }
    }
}

/// Reads answers out loud (for questions you asked out loud), without the [1] citation marks.
@MainActor
enum Speaker {
    private static let synth = AVSpeechSynthesizer()

    static func say(_ text: String) {
        stop()
        let clean = text.replacingOccurrences(of: #"\s*\[\d+(,\s*\d+)*\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: #"[*_`#]+"#, with: "", options: .regularExpression)
        guard let t = clean.nonEmpty else { return }
        let u = AVSpeechUtterance(string: String(t.prefix(1500)))
        u.rate = AVSpeechUtteranceDefaultSpeechRate * 1.05
        synth.speak(u)
    }

    static func stop() {
        if synth.isSpeaking { synth.stopSpeaking(at: .immediate) }
    }
}
