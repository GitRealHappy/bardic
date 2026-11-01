import AppKit
import SwiftUI

/// First-run setup window: what the app does, permissions, the push-to-talk key, and a place to try
/// it while the models finish downloading. Reopen it any time from the menu bar (? button).
@MainActor
final class OnboardingController: NSObject, NSWindowDelegate {
    private let state: AppState
    private var window: NSWindow?

    init(state: AppState) {
        self.state = state
    }

    func show() {
        if window == nil {
            let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 460),
                             styleMask: [.titled, .closable, .fullSizeContentView],
                             backing: .buffered, defer: false)
            w.title = "Welcome to Bardic"
            w.titlebarAppearsTransparent = true
            w.isReleasedWhenClosed = false
            w.delegate = self
            w.contentView = NSHostingView(rootView: OnboardingView(close: { [weak w] in w?.close() })
                .environmentObject(state))
            w.center()
            window = w
        }
        // Menu-bar (accessory) apps aren't activated by default, so the window would open behind others.
        NSApp.activate(ignoringOtherApps: true)
        window?.makeKeyAndOrderFront(nil)
    }

    func windowWillClose(_ notification: Notification) {
        state.hasCompletedOnboarding = true
        window = nil  // start from the first step next time
    }
}

private enum OnboardingStep: Int, CaseIterable {
    case welcome, permissions, hotkey, tryIt
}

struct OnboardingView: View {
    @EnvironmentObject var state: AppState
    @AppStorage("triggerKey") private var triggerKeyRaw = TriggerKey.rightOption.rawValue
    @State private var step = OnboardingStep.welcome
    @State private var tryText = ""
    @State private var axPrompted = false
    @State private var tryStartedAt = Date()
    let close: () -> Void

    private var triggerKey: TriggerKey { TriggerKey(rawValue: triggerKeyRaw) ?? .rightOption }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch step {
                case .welcome: welcome
                case .permissions: permissions
                case .hotkey: hotkey
                case .tryIt: tryIt
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .padding(.horizontal, 32)
            .padding(.top, 36)

            Divider()
            footer.padding(.horizontal, 20).padding(.vertical, 14)
        }
        .frame(width: 560, height: 460)
    }

    // MARK: Steps

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "waveform")
                .font(.system(size: 40, weight: .medium))
                .foregroundStyle(.tint)
            Text("Talk instead of type").font(.largeTitle.bold())
            VStack(alignment: .leading, spacing: 12) {
                feature("keyboard", "Hold a key, speak, let go",
                        "Polished text appears wherever your cursor is, in any app.")
                feature("sparkles", "Cleaned up for you",
                        "Ums and false starts are removed, and \"Tuesday, no wait, Wednesday\" becomes \"Wednesday\".")
                feature("lock.shield", "Private by design",
                        "Speech and AI models run entirely on this Mac. No account, no cloud.")
            }
            if case .loading = state.phase {
                Label("The models (about 2.5 GB) are downloading in the background while you set up.",
                      systemImage: "arrow.down.circle")
                    .font(.callout).foregroundStyle(.secondary)
            }
        }
    }

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Two permissions").font(.title.bold())
            Text("Bardic needs these to hear you and to type into other apps.")
                .foregroundStyle(.secondary)

            permissionRow(
                granted: state.micGranted, icon: "mic",
                title: "Microphone",
                detail: "Only used while you hold the dictation key. Audio never leaves this Mac.",
                action: Permissions.microphoneUndetermined ? "Allow" : "Open Settings"
            ) {
                if Permissions.microphoneUndetermined {
                    Task { state.micGranted = await Permissions.requestMicrophone() }
                } else {
                    Permissions.openMicrophoneSettings()
                }
            }

            permissionRow(
                granted: state.accessibilityGranted, icon: "hand.raised",
                title: "Accessibility",
                detail: "Lets the dictation key work in every app and pastes the text at your cursor. Turn on Bardic in the list that opens.",
                action: "Open Settings"
            ) {
                // The system prompt adds the app to the Accessibility list and links to it; after
                // that, go straight to Settings.
                if axPrompted {
                    Permissions.openAccessibilitySettings()
                } else {
                    axPrompted = true
                    Permissions.promptAccessibility()
                }
            }

            if state.micGranted && state.accessibilityGranted {
                Label("All set.", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
            } else {
                Text("This page updates on its own once you've switched them on.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var hotkey: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Choose your dictation key").font(.title.bold())
            Text("Pick a key you don't use for shortcuts much. You can change it later from the menu bar.")
                .foregroundStyle(.secondary)
            Picker("Dictation key", selection: $triggerKeyRaw) {
                ForEach(TriggerKey.allCases) { Text($0.displayName).tag($0.rawValue) }
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if triggerKey == .fn {
                Text(TriggerKey.fnHint).font(.callout).foregroundStyle(.orange)
            }
            VStack(alignment: .leading, spacing: 6) {
                tip("Hold", "to talk, release to insert the text.")
                tip("Double-tap", "for hands-free; tap once more to finish.")
                tip("Esc", "cancels.")
            }
            .padding(.top, 4)
        }
    }

    private var tryIt: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Try it").font(.title.bold())
            Text("Click in the box, hold \(triggerKey.displayName), say something, then let go.")
                .foregroundStyle(.secondary)
            TextEditor(text: $tryText)
                .font(.body)
                .frame(height: 110)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(.background, in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
            // Shown even if the paste lands, so the step visibly works in every case.
            if let heard = state.history.first, heard.date > tryStartedAt {
                Label("Heard: \(heard.text)", systemImage: "checkmark.bubble")
                    .font(.callout).foregroundStyle(.green).lineLimit(2)
            }
            modelStatus
            if !state.accessibilityGranted || !state.micGranted {
                Label("Permissions are still missing, so the key won't work yet. Go back a step.",
                      systemImage: "exclamationmark.triangle")
                    .font(.callout).foregroundStyle(.orange)
            }
        }
    }

    @ViewBuilder private var modelStatus: some View {
        switch state.phase {
        case .loading(let msg):
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(msg).font(.callout).foregroundStyle(.secondary).lineLimit(2)
            }
        case .error(let msg):
            HStack(alignment: .firstTextBaseline) {
                Label(msg, systemImage: "exclamationmark.triangle").font(.callout).foregroundStyle(.red)
                if state.modelLoadFailed {
                    Spacer()
                    Button("Retry", action: state.retryModelLoad)
                }
            }
        default:
            Label("Ready", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(.green)
        }
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingStep.allCases, id: \.self) { s in
                    Circle()
                        .fill(s == step ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(width: 7, height: 7)
                }
            }
            Spacer()
            if step != .welcome {
                Button("Back") { move(-1) }
            }
            if step == .tryIt {
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            } else {
                Button(step == .permissions && !(state.micGranted && state.accessibilityGranted)
                       ? "Skip for now" : "Continue") { move(1) }
                    .keyboardShortcut(.defaultAction)
            }
        }
    }

    private func move(_ delta: Int) {
        if let next = OnboardingStep(rawValue: step.rawValue + delta) {
            step = next
            if next == .tryIt { tryStartedAt = Date() }
        }
    }

    // MARK: Pieces

    private func feature(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon).font(.title3).foregroundStyle(.tint).frame(width: 26)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func tip(_ key: String, _ text: String) -> some View {
        HStack(spacing: 6) {
            Text(key).font(.callout.weight(.semibold))
            Text(text).font(.callout).foregroundStyle(.secondary)
        }
    }

    private func permissionRow(granted: Bool, icon: String, title: String, detail: String,
                               action: String, perform: @escaping () -> Void) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: granted ? "checkmark.circle.fill" : icon)
                .font(.title2)
                .foregroundStyle(granted ? AnyShapeStyle(.green) : AnyShapeStyle(.tint))
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            if granted {
                Text("Granted").foregroundStyle(.green)
            } else {
                Button(action, action: perform)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
    }
}
