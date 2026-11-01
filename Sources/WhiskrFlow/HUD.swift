import AppKit
import SwiftUI

/// Small floating pill at the bottom of the screen showing listening / processing state.
@MainActor
final class HUDController {
    private let panel: NSPanel
    private var hideTask: Task<Void, Never>?

    init(state: AppState) {
        panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 220, height: 44),
                        styleMask: [.borderless, .nonactivatingPanel],
                        backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.ignoresMouseEvents = true
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        panel.contentView = NSHostingView(rootView: HUDView().environmentObject(state))
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

struct HUDView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack(spacing: 10) {
            switch state.phase {
            case .recording(let handsFree):
                Circle().fill(.red).frame(width: 8, height: 8)
                LevelBars(level: state.level)
                if handsFree { Text("tap to finish").font(.caption).foregroundStyle(.secondary) }
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
                EmptyView()
            }
        }
        .padding(.horizontal, 16)
        .frame(width: 220, height: 44)
        .background(.ultraThinMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(.white.opacity(0.15)))
    }
}

struct LevelBars: View {
    let level: Float
    private let weights: [Float] = [0.5, 0.8, 1.0, 0.7, 0.9, 0.6, 0.4]

    var body: some View {
        HStack(spacing: 3) {
            ForEach(weights.indices, id: \.self) { i in
                Capsule()
                    .fill(.primary)
                    .frame(width: 3, height: CGFloat(4 + 18 * level * weights[i]))
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: level)
    }
}
