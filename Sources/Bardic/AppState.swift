import AppKit
import Combine
import OSLog
import ServiceManagement
import SwiftUI
import BardicCore

struct HistoryItem: Codable, Identifiable {
    var id = UUID()
    let date: Date
    let raw: String
    let text: String
    let app: String?
    let usedLLM: Bool
    let timing: String
}

enum Phase: Equatable {
    case loading(String)
    case idle
    case recording(handsFree: Bool)
    case processing
    case error(String)
}

@MainActor
final class AppState: ObservableObject {
    static let shared = AppState()
    static let log = Logger(subsystem: Bundle.main.bundleIdentifier ?? "bardic", category: "app")

    // Persisted preferences
    @AppStorage("triggerKey") var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @AppStorage("speechModel") var speechModelRaw = SpeechModel.largeV3Turbo.rawValue
    @AppStorage("cleanupModel") var cleanupModelRaw = CleanupModel.qwen25_3B.rawValue
    @AppStorage("aiCleanup") var aiCleanup = true
    @AppStorage("contextAware") var contextAware = true
    @AppStorage("vocabulary") var vocabularyText = ""
    @AppStorage("language") var language = "en"
    @AppStorage("addTrailingSpace") var addTrailingSpace = true
    @AppStorage("hasCompletedOnboarding") var hasCompletedOnboarding = false

    @Published var phase: Phase = .loading("Starting…") {
        didSet { if phase != oldValue { AppState.log.notice("phase: \(String(describing: self.phase), privacy: .public)") } }
    }
    @Published var level: Float = 0
    /// Short message shown in the HUD while idle, e.g. when nothing was heard.
    @Published var notice: String?
    @Published var history: [HistoryItem] = []
    @Published var micGranted = Permissions.microphoneGranted
    @Published var accessibilityGranted = Permissions.accessibilityGranted

    let recorder = AudioRecorder()
    let transcriber = Transcriber()
    let cleaner = Cleaner()
    let hotkeys = HotkeyManager()
    lazy var hud = HUDController(state: self)
    lazy var onboarding = OnboardingController(state: self)

    private var targetApp: NSRunningApplication?
    private(set) var recordStart = Date()
    /// Last time the mic picked up something louder than room noise. Not @Published: the HUD
    /// polls it on a timer rather than redrawing for every audio chunk.
    private(set) var lastVoiceAt = Date()
    private var permissionTimer: Timer?

    var vocabulary: [String] {
        vocabularyText.split(whereSeparator: { $0 == "," || $0.isNewline })
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    var triggerKey: TriggerKey { TriggerKey(rawValue: triggerKeyRaw) ?? .rightOption }

    var launchAtLogin: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
            } catch {
                AppState.log.error("launch at login failed: \(error.localizedDescription, privacy: .public)")
            }
            objectWillChange.send()
        }
    }

    // MARK: - Startup

    /// The app used to be called Whiskr Flow, with a different bundle ID and so a separate
    /// preferences domain. Copy the user's choices (key, models, dictionary…) over once.
    /// Onboarding state is deliberately not copied: macOS permissions don't carry over to the new ID.
    nonisolated static func migrateLegacySettings() {
        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: "migratedLegacySettings") else { return }
        defaults.set(true, forKey: "migratedLegacySettings")
        guard let legacy = UserDefaults(suiteName: "com.jesseboyes.whiskrflow") else { return }
        let keys = ["triggerKey", "speechModel", "cleanupModel", "aiCleanup", "contextAware",
                    "vocabulary", "language", "addTrailingSpace"]
        for key in keys where defaults.object(forKey: key) == nil {
            if let value = legacy.object(forKey: key) { defaults.set(value, forKey: key) }
        }
    }

    func start() {
        chooseDefaultModelsForThisMac()
        loadHistory()
        recorder.onLevel = { [weak self] rms in
            Task { @MainActor in
                guard let self else { return }
                self.level = AudioRecorder.meterLevel(rms)
                if rms > AudioRecorder.voiceLevel { self.lastVoiceAt = Date() }
            }
        }
        hotkeys.onEvent = { [weak self] e in self?.handle(e) }
        hotkeys.start()
        watchPermissions()

        // People who already granted both permissions (e.g. upgrading from an earlier build) have
        // effectively been through setup.
        if !hasCompletedOnboarding && micGranted && accessibilityGranted {
            hasCompletedOnboarding = true
        }
        if hasCompletedOnboarding {
            Task {
                if Permissions.microphoneUndetermined { micGranted = await Permissions.requestMicrophone() }
                if !Permissions.accessibilityGranted { Permissions.promptAccessibility() }
            }
        } else {
            // The setup window asks for permissions one at a time, with an explanation.
            onboarding.show()
        }
        Task { await loadModels() }
    }

    /// The 3B cleanup model needs ~1.8 GB of RAM on top of Whisper; on 8 GB Macs that competes with
    /// everything else, so start them on the 1.5B model. Only applies until the user picks one.
    private func chooseDefaultModelsForThisMac() {
        guard UserDefaults.standard.object(forKey: "cleanupModel") == nil else { return }
        let gb = Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824
        if gb <= 8.5 {
            cleanupModelRaw = CleanupModel.qwen25_1_5B.rawValue
            AppState.log.notice("\(Int(gb.rounded())) GB RAM: defaulting to the 1.5B cleanup model")
        }
    }

    func loadModels() async {
        let speech = SpeechModel(rawValue: speechModelRaw) ?? .largeV3Turbo
        let llm = CleanupModel(rawValue: cleanupModelRaw) ?? .qwen25_3B
        let report: @Sendable (String) -> Void = { msg in Task { @MainActor in AppState.shared.phase = .loading(msg) } }
        do {
            phase = .loading("Loading speech model…")
            try await transcriber.load(speech, progress: report)
            if aiCleanup {
                try await cleaner.load(llm, progress: report)
            }
            phase = .idle
        } catch {
            phase = .error("Model load failed: \(error.localizedDescription)")
        }
    }

    /// Accessibility is granted in System Settings while we run; poll so the UI updates and
    /// global key monitors are re-registered once trust is granted.
    private func watchPermissions() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                let ax = Permissions.accessibilityGranted
                if ax != self.accessibilityGranted {
                    self.accessibilityGranted = ax
                    if ax { self.hotkeys.start() }
                }
                self.micGranted = Permissions.microphoneGranted
            }
        }
    }

    // MARK: - Dictation flow

    private func handle(_ e: HotkeyManager.Event) {
        switch e {
        case .start: startRecording(handsFree: false)
        case .handsFreeLocked: if case .recording = phase { phase = .recording(handsFree: true) }
        case .stop: Task { await stopAndProcess() }
        case .cancel: cancelRecording()
        }
    }

    func toggleFromMenu() {
        if case .recording = phase {
            hotkeys.reset()
            Task { await stopAndProcess() }
        } else {
            startRecording(handsFree: true)
        }
    }

    func startRecording(handsFree: Bool) {
        guard phase == .idle || { if case .error = phase { return true }; return false }() else {
            hotkeys.reset()
            if case .loading = phase { NSSound.beep() }
            return
        }
        guard micGranted else {
            phase = .error("Microphone access is off. Enable it in System Settings.")
            hotkeys.reset()
            hud.show()
            return
        }
        targetApp = NSWorkspace.shared.frontmostApplication
        notice = nil
        do {
            try recorder.start()
            recordStart = Date()
            lastVoiceAt = recordStart
            phase = .recording(handsFree: handsFree)
            hud.show()
        } catch {
            phase = .error(error.localizedDescription)
            hotkeys.reset()
            hud.flashAndHide()
        }
    }

    func cancelRecording() {
        guard case .recording = phase else { return }
        recorder.stop()
        phase = .idle
        hud.hide()
    }

    func stopAndProcess() async {
        guard case .recording = phase else { return }
        let samples = recorder.stop()
        let seconds = Double(samples.count) / AudioRecorder.sampleRate
        let rms = AudioRecorder.rms(samples)
        let speech = AudioRecorder.speechLevel(samples)
        let levels = String(format: "%.1fs, speech %d dBFS, rms %d dBFS, peak %d dBFS", seconds,
                            AudioRecorder.dB(speech), AudioRecorder.dB(rms),
                            AudioRecorder.dB(AudioRecorder.peak(samples)))

        // Ignore accidental taps and silence (Whisper hallucinates "Thank you." on silence).
        guard seconds > 0.4 else {
            AppState.log.notice("dictation: \(levels, privacy: .public) → too short, ignored")
            phase = .idle
            hud.hide()
            return
        }
        guard speech > AudioRecorder.silenceLevel else {
            AppState.log.notice("dictation: \(levels, privacy: .public) → below silence threshold")
            saveDebugAudio(samples, outcome: "silent")
            phase = .idle
            flashNotice("Didn't catch that. Is the mic too quiet?")
            return
        }

        phase = .processing
        let appName = targetApp?.localizedName
        let style: DictationStyle = contextAware ? .forBundleID(targetApp?.bundleIdentifier) : .standard

        do {
            let t0 = Date()
            let raw = try await transcriber.transcribe(samples, language: language.isEmpty ? nil : language,
                                                       vocabulary: vocabulary)
            let tASR = Date().timeIntervalSince(t0)
            guard !raw.isEmpty else {
                AppState.log.notice("dictation: \(levels, privacy: .public) → no words recognized")
                saveDebugAudio(samples, outcome: "empty")
                phase = .idle
                flashNotice("Didn't catch any words. Try again?")
                return
            }

            var text = raw
            var usedLLM = false
            let t1 = Date()
            if aiCleanup, CleanupPrompt.needsLLM(raw), await cleaner.isLoaded {
                let result = try await cleaner.clean(raw, style: style, vocabulary: vocabulary)
                text = result.text
                usedLLM = result.usedLLM
            }
            let tLLM = Date().timeIntervalSince(t1)
            if addTrailingSpace, !text.hasSuffix("\n") { text += " " }

            // Make sure the original app still has focus before pasting.
            if let app = targetApp, NSWorkspace.shared.frontmostApplication != app {
                app.activate()
                try? await Task.sleep(nanoseconds: 150_000_000)
            }
            await TextInserter.insert(text)
            AppState.log.notice("dictation: \(levels, privacy: .public) → inserted \(text.count) chars into \(appName ?? "?", privacy: .public)")
            saveDebugAudio(samples, outcome: "ok")

            let timing = String(format: "%.1fs audio · whisper %.2fs · llm %.2fs", seconds, tASR, tLLM)
            addHistory(HistoryItem(date: Date(), raw: raw, text: text.trimmingCharacters(in: .whitespaces),
                                   app: appName, usedLLM: usedLLM, timing: timing))
            phase = .idle
            hud.hide()
        } catch {
            phase = .error(error.localizedDescription)
            hud.flashAndHide()
        }
    }

    /// Briefly shows a message in the HUD pill without changing the phase.
    private func flashNotice(_ message: String) {
        notice = message
        hud.flashAndHide(after: 2.5)
    }

    /// Off by default. `defaults write com.jesseboyes.bardic debugSaveAudio -bool YES` keeps the
    /// last 20 recordings in ~/Library/Application Support/Bardic/DebugAudio for diagnosing problems.
    private func saveDebugAudio(_ samples: [Float], outcome: String) {
        guard UserDefaults.standard.bool(forKey: "debugSaveAudio") else { return }
        let dir = Paths.appSupport.appendingPathComponent("DebugAudio", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let stamp = Date().formatted(.iso8601.year().month().day().time(includingFractionalSeconds: false))
            .replacingOccurrences(of: ":", with: "")
        try? AudioRecorder.writeWAV(samples, to: dir.appendingPathComponent("\(stamp)-\(outcome).wav"))
        let files = (try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)) ?? []
        for old in files.sorted(by: { $0.lastPathComponent > $1.lastPathComponent }).dropFirst(20) {
            try? FileManager.default.removeItem(at: old)
        }
    }

    // MARK: - History

    private var historyURL: URL { Paths.appSupport.appendingPathComponent("history.json") }

    private func addHistory(_ item: HistoryItem) {
        history.insert(item, at: 0)
        if history.count > 100 { history.removeLast(history.count - 100) }
        if let data = try? JSONEncoder().encode(history) { try? data.write(to: historyURL) }
    }

    private func loadHistory() {
        guard let data = try? Data(contentsOf: historyURL),
              let items = try? JSONDecoder().decode([HistoryItem].self, from: data) else { return }
        history = items
    }

    func clearHistory() {
        history.removeAll()
        try? FileManager.default.removeItem(at: historyURL)
    }

    func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}
