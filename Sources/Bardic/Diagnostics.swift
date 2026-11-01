import AppKit
import OSLog
import BardicCore

/// Plain-text report a user can paste into an issue or a message: versions, hardware, model state,
/// permissions and the app's recent log lines. Never includes transcripts or history.
@MainActor
enum Diagnostics {
    static var buildNumber: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "?"
    }

    static func report(_ state: AppState) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersion
        let gb = { (b: Int64) in String(format: "%.1f GB", Double(b) / 1_000_000_000) }
        let ram = Int((Double(ProcessInfo.processInfo.physicalMemory) / 1_073_741_824).rounded())
        let speech = state.speechModel, llm = state.cleanupModel

        var lines = [
            "Bardic \(UpdateChecker.currentVersion) (build \(buildNumber))",
            "macOS \(os.majorVersion).\(os.minorVersion).\(os.patchVersion)",
            "Mac: \(sysctl("hw.model")) · \(sysctl("machdep.cpu.brand_string")) · \(ram) GB RAM",
            "Free disk: \(Paths.freeDiskBytes.map(gb) ?? "?")",
            "Speech model: \(speech.rawValue) (\(Transcriber.isDownloaded(speech) ? "downloaded" : "not downloaded"))",
            "Cleanup model: \(state.aiCleanup ? llm.rawValue : "off")"
                + (state.aiCleanup ? " (\(Cleaner.isDownloaded(llm) ? "downloaded" : "not downloaded"))" : ""),
            "State: \(state.phase)" + (state.cleanupUnavailable ? " · cleanup unavailable" : ""),
            "Microphone: \(state.micGranted ? "granted" : "not granted") · Accessibility: \(state.accessibilityGranted ? "granted" : "not granted")",
            "Key: \(state.triggerKey.displayName) · Language: \(state.language.isEmpty ? "auto" : state.language)",
            "",
            "Recent log:",
        ]
        lines += recentLog(limit: 100)
        return lines.joined(separator: "\n")
    }

    static func copyReport(_ state: AppState) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report(state), forType: .string)
    }

    /// The app's own log entries since launch. Dictation log lines carry levels and lengths, not words.
    private static func recentLog(limit: Int) -> [String] {
        guard let store = try? OSLogStore(scope: .currentProcessIdentifier) else { return ["(log unavailable)"] }
        let subsystem = Bundle.main.bundleIdentifier ?? "bardic"
        let predicate = NSPredicate(format: "subsystem == %@", subsystem)
        guard let entries = try? store.getEntries(matching: predicate) else { return ["(log unavailable)"] }
        let time = Date.FormatStyle().hour(.twoDigits(amPM: .omitted)).minute().second()
        let lines = entries.compactMap { $0 as? OSLogEntryLog }
            .map { "\($0.date.formatted(time)) [\($0.category)] \($0.composedMessage)" }
        return lines.isEmpty ? ["(no entries)"] : Array(lines.suffix(limit))
    }

    private static func sysctl(_ name: String) -> String {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return "?" }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return "?" }
        return String(cString: buffer)
    }
}
