import AppKit

/// Modifier keys that can act as the push-to-talk key on their own.
enum TriggerKey: String, CaseIterable, Identifiable {
    case rightOption, rightCommand, rightControl, fn

    var id: String { rawValue }

    var keyCode: UInt16 {
        switch self {
        case .rightOption: return 61
        case .rightCommand: return 54
        case .rightControl: return 62
        case .fn: return 63
        }
    }

    var flag: NSEvent.ModifierFlags {
        switch self {
        case .rightOption: return .option
        case .rightCommand: return .command
        case .rightControl: return .control
        case .fn: return .function
        }
    }

    var displayName: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "Fn / Globe 🌐"
        }
    }
}

/// Hold the trigger key to talk; double-tap it for hands-free mode (tap again to finish).
/// Uses NSEvent global monitors, which require the Accessibility permission.
@MainActor
final class HotkeyManager {
    enum Event { case start, stop, cancel, handsFreeLocked }

    /// Read live so changes in Settings apply immediately.
    var trigger: TriggerKey {
        TriggerKey(rawValue: UserDefaults.standard.string(forKey: "triggerKey") ?? "") ?? .rightOption
    }
    var onEvent: ((Event) -> Void)?

    private var monitors: [Any] = []
    private var isDown = false
    private var downAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var active = false     // currently recording because of us
    private var handsFree = false

    private let tapThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.45

    func start() {
        stop()
        let flags: (NSEvent) -> Void = { [weak self] e in MainActor.assumeIsolated { self?.flagsChanged(e) } }
        let keys: (NSEvent) -> Void = { [weak self] e in MainActor.assumeIsolated { self?.keyDown(e) } }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .flagsChanged, handler: flags) { monitors.append(m) }
        if let m = NSEvent.addGlobalMonitorForEvents(matching: .keyDown, handler: keys) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged, handler: { flags($0); return $0 }) { monitors.append(m) }
        if let m = NSEvent.addLocalMonitorForEvents(matching: .keyDown, handler: { keys($0); return $0 }) { monitors.append(m) }
    }

    func stop() {
        monitors.forEach { NSEvent.removeMonitor($0) }
        monitors.removeAll()
    }

    /// Called by the app when recording ends for another reason (e.g. menu button).
    func reset() {
        active = false
        handsFree = false
    }

    private func flagsChanged(_ e: NSEvent) {
        guard e.keyCode == trigger.keyCode else { return }
        let pressed = e.modifierFlags.contains(trigger.flag)
        if pressed && !isDown {
            isDown = true
            downAt = Date()
            if handsFree {
                handsFree = false
                active = false
                onEvent?(.stop)
            } else if !active {
                active = true
                onEvent?(.start)
            }
        } else if !pressed && isDown {
            isDown = false
            guard active, !handsFree else { return }
            let held = Date().timeIntervalSince(downAt)
            if held < tapThreshold {
                if Date().timeIntervalSince(lastTapAt) < doubleTapWindow {
                    handsFree = true
                    lastTapAt = .distantPast
                    onEvent?(.handsFreeLocked)
                } else {
                    lastTapAt = Date()
                    active = false
                    onEvent?(.cancel)
                }
            } else {
                active = false
                onEvent?(.stop)
            }
        }
    }

    private func keyDown(_ e: NSEvent) {
        guard active else { return }
        if e.keyCode == 53 { // Escape cancels any recording
            reset()
            onEvent?(.cancel)
        } else if isDown && !handsFree {
            // Another key pressed while holding the modifier: it's a shortcut, not dictation.
            active = false
            onEvent?(.cancel)
        }
    }
}
