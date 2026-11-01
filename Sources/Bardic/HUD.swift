import AppKit
import SwiftUI

/// Small floating pill at the bottom of the screen showing listening / processing state.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init(state: AppState) {
        // Wider than the pill itself, which sizes to its content; the rest is transparent.
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 380, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        // Clickable for the Finish/Cancel buttons; the transparent area around the pill passes
        // clicks through, and the panel never takes focus from the app being dictated into.
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = FirstClickHostingView(rootView: HUDView().environmentObject(state))
    }

    func show() {
        hideTask?.cancel()
        if let screen = NSScreen.main {
            let f = screen.visibleFrame
            panel.setFrameOrigin(NSPoint(x: f.midX - panel.frame.width / 2, y: f.minY + 40))
        }
        panel.orderFrontRegardless()
    }

    func hide() {
        hideTask?.cancel()
        panel.orderOut(nil)
    }

    func flashAndHide(after seconds: Double = 3) {
        show()
        hideTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.panel.orderOut(nil)
        }
    }
}

/// Buttons in a panel that never becomes key would otherwise swallow the first click.
private final class FirstClickHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}

struct HUDView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording(let handsFree):
                RecordingStatus(handsFree: handsFree)
            case .processing:
                ProgressView().controlSize(.small)
                Text("Thinking…").font(.callout)
            case .error(let msg):
                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.yellow)
                Text(msg).font(.caption).lineLimit(2)
            case .loading(let msg):
                ProgressView().controlSize(.small)
                Text(msg).font(.caption).lineLimit(1)
            case .idle:
                if let notice = state.notice {
                    Image(systemName: "ear.trianglebadge.exclamationmark").foregroundStyle(.orange)
                    Text(notice).font(.caption).lineLimit(2)
                }
            }
        }
        .padding(.horizontal, 16)
        .frame(minWidth: 180, maxWidth: 360, minHeight: 44, maxHeight: 44)
        .fixedSize()
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
        .frame(width: 380, height: 44)
    }
}

/// Live feedback while recording, so a long dictation never turns out to be lost: a running
/// timer, bars that follow the voice, and a warning if the mic has picked up nothing for a while.
private struct RecordingStatus: View {
    @EnvironmentObject var state: AppState
    let handsFree: Bool

    /// How long without voice before warning; long enough to cover a pause to think.
    private let quietWarning: TimeInterval = 2.5

    var body: some View {
        TimelineView(.periodic(from: state.recordStart, by: 0.25)) { context in
            let elapsed = context.date.timeIntervalSince(state.recordStart)
            let quiet = context.date.timeIntervalSince(state.lastVoiceAt) > quietWarning
            HStack(spacing: 10) {
                Circle().fill(.red).frame(width: 8, height: 8)
                    .opacity(quiet ? 0.5 : 1)
                LiveLevelBars(meter: state.meter)
                    .foregroundStyle(quiet ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
                Text(Duration.seconds(elapsed).formatted(.time(pattern: .minuteSecond)))
                    .font(.callout.monospacedDigit())
                if quiet {
                    Label("Can't hear you", systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(.orange)
                }
                if handsFree {
                    // Always a visible way out of hands-free mode, whatever started it.
                    Button(action: state.finishFromUI) {
                        Label("Done", systemImage: "checkmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.green)
                    .help("Stop and insert the text (or tap \(state.triggerKey.shortName))")
                    Button(action: state.cancelFromUI) {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Cancel (Esc)")
                }
            }
        }
    }
}

/// Observes only the meter, so the fast level updates redraw the bars and nothing else.
private struct LiveLevelBars: View {
    @ObservedObject var meter: LevelMeter
    var body: some View { LevelBars(level: meter.level) }
}

struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.7, 0.9, 0.6, 0.4]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.foreground)
                    .frame(width: 3, height: CGFloat(4 + 18 * level * weights[i]))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
