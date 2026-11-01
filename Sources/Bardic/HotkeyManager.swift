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

    /// Device-dependent bit for this physical key (NX_DEVICER*KEYMASK in IOKit's IOLLEvent.h).
    /// The generic `.option`/`.command` flags stay set while the *left* key is held, which would
    /// hide the release of the right one and leave recording stuck on. Fn has a single key.
    private var deviceMask: UInt? {
        switch self {
        case .rightOption: return 0x40
        case .rightCommand: return 0x10
        case .rightControl: return 0x2000
        case .fn: return nil
        }
    }

    func isPressed(in flags: NSEvent.ModifierFlags) -> Bool {
        if let deviceMask { return flags.rawValue & deviceMask != 0 }
        return flags.contains(.function)
    }

    var displayName: String {
        switch self {
        case .rightOption: return "Right Option ⌥"
        case .rightCommand: return "Right Command ⌘"
        case .rightControl: return "Right Control ⌃"
        case .fn: return "Fn / Globe 🌐"
        }
    }

    /// Short form for tight spaces like the menu bar dropdown.
    var shortName: String {
        switch self {
        case .rightOption: return "Right ⌥"
        case .rightCommand: return "Right ⌘"
        case .rightControl: return "Right ⌃"
        case .fn: return "Fn 🌐"
        }
    }

    static let fnHint = "If you choose Fn, set System Settings › Keyboard › \"Press 🌐 key to\" to \"Do Nothing\"."
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
    private var armedTrigger: TriggerKey?
    private var isDown = false
    private var downAt = Date.distantPast
    private var lastTapAt = Date.distantPast
    private var active = false     // currently recording because of us
    private var handsFree = false

    private let tapThreshold: TimeInterval = 0.3
    private let doubleTapWindow: TimeInterval = 0.45

    func start() {
        stop()
        armedTrigger = trigger
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

    /// Recording was started from the menu in hands-free mode: arm the same exits as a double-tap
    /// (tap the key to finish, Esc to cancel).
    func beginHandsFree() {
        armedTrigger = trigger  // so the first key event isn't mistaken for a key change
        active = true
        handsFree = true
    }

    /// Called by the app when recording ends for another reason (e.g. menu button).
    func reset() {
        active = false
        handsFree = false
    }

    private func flagsChanged(_ e: NSEvent) {
        let trigger = self.trigger
        if trigger != armedTrigger {
            // The key was changed (menu or Settings): drop any half-finished press of the old one.
            armedTrigger = trigger
            isDown = false
            lastTapAt = .distantPast
            if active { cancel("dictation key changed") }
            reset()
        }
        guard e.keyCode == trigger.keyCode else { return }
        let pressed = trigger.isPressed(in: e.modifierFlags)
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
                    cancel(String(format: "quick tap (%.2fs)", held))
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
            cancel("Esc")
        } else if isDown && !handsFree {
            // Another key pressed while holding the modifier: it's a shortcut, not dictation.
            active = false
            cancel("key \(e.keyCode) pressed while holding")
        }
    }

    private func cancel(_ reason: String) {
        AppState.log.notice("hotkey: cancel (\(reason, privacy: .public))")
        onEvent?(.cancel)
    }
}
