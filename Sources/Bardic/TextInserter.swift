import AppKit
import ApplicationServices

/// Inserts text at the cursor of the frontmost app by pasting, then restores the user's clipboard.
@MainActor
enum TextInserter {
    static func insert(_ text: String) async {
        let pb = NSPasteboard.general
        let saved = snapshot(pb)

        pb.clearContents()
        pb.setString(text, forType: .string)
        // Ask clipboard managers to ignore this temporary entry.
        pb.setString("", forType: NSPasteboard.PasteboardType("org.nspasteboard.TransientType"))
        let changeCount = pb.changeCount

        pressCmdV()

        // Give the target app time to read the pasteboard before restoring it.
        try? await Task.sleep(nanoseconds: 300_000_000)
        if pb.changeCount == changeCount {
            restore(saved, to: pb)
        }
    }

    private static func pressCmdV() {
        let src = CGEventSource(stateID: .combinedSessionState)
        let vKey: CGKeyCode = 9
        let down = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: true)
        let up = CGEvent(keyboardEventSource: src, virtualKey: vKey, keyDown: false)
        down?.flags = .maskCommand
        up?.flags = .maskCommand
        down?.post(tap: .cgAnnotatedSessionEventTap)
        up?.post(tap: .cgAnnotatedSessionEventTap)
    }

    private static func snapshot(_ pb: NSPasteboard) -> [[NSPasteboard.PasteboardType: Data]] {
        (pb.pasteboardItems ?? []).map { item in
            var dict: [NSPasteboard.PasteboardType: Data] = [:]
            for type in item.types {
                if let data = item.data(forType: type) { dict[type] = data }
            }
            return dict
        }
    }

    private static func restore(_ items: [[NSPasteboard.PasteboardType: Data]], to pb: NSPasteboard) {
        pb.clearContents()
        guard !items.isEmpty else { return }
        let objects: [NSPasteboardItem] = items.map { dict in
            let item = NSPasteboardItem()
            for (type, data) in dict { item.setData(data, forType: type) }
            return item
        }
        pb.writeObjects(objects)
    }
}
