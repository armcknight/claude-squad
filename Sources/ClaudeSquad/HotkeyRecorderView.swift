import SwiftUI
import Carbon.HIToolbox

/// A button that, when clicked, listens for the next key combo and reports it back.
struct HotkeyRecorderView: View {
    let currentCombo: GlobalHotkey.KeyCombo
    let onRecord: (GlobalHotkey.KeyCombo) -> Void

    @State private var isRecording = false
    @State private var monitor: Any?

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            if isRecording {
                Text("Press shortcut…")
                    .foregroundStyle(.secondary)
            } else {
                Text(currentCombo.displayString)
            }
        }
        .buttonStyle(.bordered)
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let carbonModifiers = event.cocoaToCarbonModifiers
            // Require at least one modifier key
            guard carbonModifiers != 0 else { return event }

            let combo = GlobalHotkey.KeyCombo(
                keyCode: UInt32(event.keyCode),
                carbonModifiers: carbonModifiers
            )
            onRecord(combo)
            stopRecording()
            return nil // consume the event
        }
    }

    private func stopRecording() {
        isRecording = false
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }
}

private extension NSEvent {
    var cocoaToCarbonModifiers: UInt32 {
        var carbon: UInt32 = 0
        if modifierFlags.contains(.command) { carbon |= UInt32(cmdKey) }
        if modifierFlags.contains(.shift) { carbon |= UInt32(shiftKey) }
        if modifierFlags.contains(.option) { carbon |= UInt32(optionKey) }
        if modifierFlags.contains(.control) { carbon |= UInt32(controlKey) }
        return carbon
    }
}
