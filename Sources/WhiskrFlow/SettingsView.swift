import SwiftUI
import WhiskrCore

struct SettingsView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        TabView {
            GeneralTab().tabItem { Label("General", systemImage: "gearshape") }
            ModelsTab().tabItem { Label("Models", systemImage: "cpu") }
            DictionaryTab().tabItem { Label("Dictionary", systemImage: "character.book.closed") }
            HistoryTab().tabItem { Label("History", systemImage: "clock") }
        }
        .padding(20)
        .frame(width: 560, height: 440)
    }
}

private struct GeneralTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("triggerKey") private var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @AppStorage("aiCleanup") private var aiCleanup = true
    @AppStorage("contextAware") private var contextAware = true
    @AppStorage("addTrailingSpace") private var addTrailingSpace = true
    @AppStorage("language") private var language = "en"

    var body: some View {
        Form {
            Picker("Push-to-talk key", selection: $triggerKeyRaw) {
                ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("Hold to dictate, release to insert. Double-tap for hands-free; tap again to finish. Esc cancels. If you choose Fn, set System Settings › Keyboard › \"Press 🌐 key to\" to \"Do Nothing\".")
                .font(.caption).foregroundStyle(.secondary)

            Toggle("AI cleanup (remove fillers, fix punctuation, apply corrections)", isOn: $aiCleanup)
            Toggle("Adapt tone to the current app (Slack, Mail, Xcode…)", isOn: $contextAware)
            Toggle("Add a space after inserted text", isOn: $addTrailingSpace)
            Picker("Language", selection: $language) {
                Text("English").tag("en")
                Text("Auto-detect").tag("")
                Text("Spanish").tag("es")
                Text("French").tag("fr")
                Text("German").tag("de")
            }
            Toggle("Launch at login", isOn: Binding(get: { state.launchAtLogin }, set: { state.launchAtLogin = $0 }))

            Section("Permissions") {
                LabeledContent("Microphone") {
                    Text(state.micGranted ? "Granted" : "Not granted").foregroundStyle(state.micGranted ? .green : .red)
                }
                LabeledContent("Accessibility") {
                    HStack {
                        Text(state.accessibilityGranted ? "Granted" : "Not granted")
                            .foregroundStyle(state.accessibilityGranted ? .green : .red)
                        if !state.accessibilityGranted {
                            Button("Open Settings") { Permissions.openAccessibilitySettings() }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

private struct ModelsTab: View {
    @EnvironmentObject var state: AppState
    @AppStorage("speechModel") private var speechModelRaw = SpeechModel.largeV3Turbo.rawValue
    @AppStorage("cleanupModel") private var cleanupModelRaw = CleanupModel.qwen25_3B.rawValue

    var body: some View {
        Form {
            Picker("Speech recognition", selection: $speechModelRaw) {
                ForEach(SpeechModel.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Picker("Cleanup LLM", selection: $cleanupModelRaw) {
                ForEach(CleanupModel.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            Text("Everything runs on this Mac. Models download once from Hugging Face, then work offline.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Button("Apply & reload models") { Task { await state.loadModels() } }
                if case .loading(let msg) = state.phase { ProgressView().controlSize(.small); Text(msg).font(.caption) }
            }
        }
        .formStyle(.grouped)
    }
}

private struct DictionaryTab: View {
    @AppStorage("vocabulary") private var vocabularyText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Personal dictionary").font(.headline)
            Text("Names, products and jargon (one per line or comma-separated). Used to bias recognition and spelling.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $vocabularyText)
                .font(.body.monospaced())
                .border(.quaternary)
        }
    }
}

private struct HistoryTab: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading) {
            List(state.history) { item in
                VStack(alignment: .leading, spacing: 4) {
                    Text(item.text).textSelection(.enabled)
                    if item.raw != item.text {
                        Text("raw: \(item.raw)").font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                    }
                    Text("\(item.date.formatted(date: .abbreviated, time: .shortened)) · \(item.app ?? "–") · \(item.usedLLM ? "AI" : "raw") · \(item.timing)")
                        .font(.caption2).foregroundStyle(.tertiary)
                }
                .contextMenu { Button("Copy") { state.copy(item.text) } }
            }
            HStack {
                Text("Stored only on this Mac.").font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Clear history", role: .destructive) { state.clearHistory() }
            }
        }
    }
}
