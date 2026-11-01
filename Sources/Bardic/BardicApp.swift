import AppKit
import SwiftUI
import BardicCore

@main
struct BardicApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    @StateObject private var state = AppState.shared

    init() {
        // Before any @AppStorage is read.
        AppState.migrateLegacySettings()
    }

    var body: some Scene {
        MenuBarExtra {
            MenuContent().environmentObject(state)
        } label: {
            Image(systemName: menuIcon)
        }
        .menuBarExtraStyle(.window)

        Window("Bardic Settings", id: "settings") {
            SettingsView().environmentObject(state)
        }
        .windowResizability(.contentSize)
    }

    private var menuIcon: String {
        switch state.phase {
        case .recording: return "waveform.circle.fill"
        case .processing: return "ellipsis.circle"
        case .loading: return "arrow.down.circle"
        case .error: return "exclamationmark.circle"
        case .idle: return "waveform"
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        MainActor.assumeIsolated { AppState.shared.start() }
    }
}

struct MenuContent: View {
    @EnvironmentObject var state: AppState
    @ObservedObject private var updates = UpdateChecker.shared
    @AppStorage("aiCleanup") private var aiCleanup = true
    @AppStorage("triggerKey") private var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @AppStorage("checkForUpdates") private var checkForUpdates = true
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Bardic").font(.headline)
                Spacer()
                statusBadge
            }

            if !state.micGranted || !state.accessibilityGranted {
                PermissionBanner()
            }

            if state.modelLoadFailed {
                HStack {
                    Text("The models didn't load.").font(.caption)
                    Spacer()
                    Button("Retry", action: state.retryModelLoad).controlSize(.small)
                }
            } else if state.cleanupUnavailable && aiCleanup {
                HStack {
                    Image(systemName: "exclamationmark.triangle").foregroundStyle(.orange)
                    Text("AI cleanup unavailable; pasting raw text").font(.caption)
                    Spacer()
                    Button("Retry", action: state.retryModelLoad).controlSize(.small)
                }
            }

            if checkForUpdates, let update = updates.available {
                Button { NSWorkspace.shared.open(update.url) } label: {
                    Label("Bardic \(update.version) is available ›", systemImage: "arrow.down.app")
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.tint)
            }

            Button(action: state.toggleFromMenu) {
                Label(isRecording ? "Stop & insert" : "Start dictation (hands-free)",
                      systemImage: isRecording ? "stop.circle" : "mic")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .disabled(!canToggle)

            HStack {
                Label("Push-to-talk key", systemImage: "keyboard")
                Spacer()
                Picker("Push-to-talk key", selection: $triggerKeyRaw) {
                    ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0.rawValue) }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                .fixedSize()
            }

            Text("Hold \(triggerKey.shortName) to talk · double-tap for hands-free · Esc cancels")
                .font(.caption).foregroundStyle(.secondary)
            if triggerKey == .fn {
                Text(TriggerKey.fnHint).font(.caption2).foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Divider()

            Text("Recent").font(.subheadline).foregroundStyle(.secondary)
            if state.history.isEmpty {
                Text("Nothing dictated yet.").font(.caption).foregroundStyle(.tertiary)
            } else {
                ForEach(state.history.prefix(5)) { item in
                    Button { state.copy(item.text) } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(item.text).lineLimit(2).frame(maxWidth: .infinity, alignment: .leading)
                            Text("\(item.app ?? "–") · \(item.timing)").font(.caption2).foregroundStyle(.tertiary)
                        }
                    }
                    .buttonStyle(.plain)
                    .help("Click to copy")
                }
            }

            Divider()

            HStack {
                Toggle("AI cleanup", isOn: $aiCleanup).toggleStyle(.switch).controlSize(.mini)
                Spacer()
                Button { state.onboarding.show() } label: { Image(systemName: "questionmark.circle") }
                    .buttonStyle(.borderless)
                    .help("Setup guide")
                Button("Settings…") {
                    openWindow(id: "settings")
                    NSApp.activate(ignoringOtherApps: true)
                }
                Button("Quit") { NSApp.terminate(nil) }
            }
        }
        .padding(14)
        .frame(width: 340)
    }

    private var triggerKey: TriggerKey { TriggerKey(rawValue: triggerKeyRaw) ?? .rightOption }
    private var isRecording: Bool { if case .recording = state.phase { return true }; return false }
    private var canToggle: Bool {
        switch state.phase { case .idle, .recording, .error: return true; default: return false }
    }

    @ViewBuilder private var statusBadge: some View {
        switch state.phase {
        case .idle: Text("Ready").font(.caption).foregroundStyle(.green)
        case .recording: Text("Listening").font(.caption).foregroundStyle(.red)
        case .processing: Text("Processing").font(.caption).foregroundStyle(.orange)
        case .loading(let msg): Text(msg).font(.caption).foregroundStyle(.secondary).lineLimit(1)
        case .error(let msg): Text(msg).font(.caption).foregroundStyle(.red).lineLimit(2)
        }
    }
}

struct PermissionBanner: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if !state.micGranted {
                HStack {
                    Image(systemName: "mic.slash").foregroundStyle(.orange)
                    Text("Microphone access needed").font(.caption)
                    Spacer()
                    Button("Open") { Permissions.openMicrophoneSettings() }.controlSize(.small)
                }
            }
            if !state.accessibilityGranted {
                HStack {
                    Image(systemName: "hand.raised").foregroundStyle(.orange)
                    Text("Accessibility needed for hotkey & typing").font(.caption)
                    Spacer()
                    Button("Open") { Permissions.openAccessibilitySettings() }.controlSize(.small)
                }
            }
        }
        .padding(8)
        .background(.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }
}
