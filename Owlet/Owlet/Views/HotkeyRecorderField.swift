import SwiftUI
import AppKit
import Carbon.HIToolbox

/// Borderless field that captures the next modifier-bearing keyDown after
/// the user clicks the "Record" button. The captured `Chord` flows back
/// to SwiftUI via the binding; SettingsView decides whether to persist it.
///
/// The field accepts only events with at least one of cmd/option/control/
/// shift/fn — bare keypresses are ignored so the user can't accidentally
/// record `Space` or `R` alone (which would conflict with normal typing
/// the moment the field loses focus).
struct HotkeyRecorderField: NSViewRepresentable {

    @Binding var chord: Chord
    @Binding var isRecording: Bool

    func makeNSView(context: Context) -> RecorderNSView {
        let view = RecorderNSView()
        view.onChordCaptured = { newChord in
            chord = newChord
            isRecording = false
        }
        view.onCancel = { isRecording = false }
        return view
    }

    func updateNSView(_ nsView: RecorderNSView, context: Context) {
        nsView.displayChord = chord
        nsView.isRecording = isRecording
        nsView.needsDisplay = true
        if isRecording {
            DispatchQueue.main.async {
                nsView.window?.makeFirstResponder(nsView)
            }
        }
    }

    // MARK: NSView subclass

    final class RecorderNSView: NSView {

        var onChordCaptured: ((Chord) -> Void)?
        var onCancel: (() -> Void)?
        var displayChord: Chord = .default
        var isRecording: Bool = false

        override var acceptsFirstResponder: Bool { true }
        override var canBecomeKeyView: Bool { true }
        override var isFlipped: Bool { true }

        override func draw(_ dirtyRect: NSRect) {
            super.draw(dirtyRect)
            // Border
            let path = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.5, dy: 0.5),
                                    xRadius: 6, yRadius: 6)
            (isRecording ? NSColor.controlAccentColor : NSColor.separatorColor).setStroke()
            path.lineWidth = isRecording ? 2 : 1
            path.stroke()

            // Text
            let label = isRecording ? "Press a chord…" : displayChord.displayString
            let attrs: [NSAttributedString.Key: Any] = [
                .font: NSFont.systemFont(ofSize: 13, weight: .medium),
                .foregroundColor: NSColor.labelColor,
            ]
            let attr = NSAttributedString(string: label, attributes: attrs)
            let textSize = attr.size()
            let textRect = NSRect(
                x: (bounds.width - textSize.width) / 2,
                y: (bounds.height - textSize.height) / 2,
                width: textSize.width,
                height: textSize.height
            )
            attr.draw(in: textRect)
        }

        override func keyDown(with event: NSEvent) {
            guard isRecording else { super.keyDown(with: event); return }
            if event.keyCode == UInt16(kVK_Escape) {
                onCancel?()
                return
            }
            let raw = event.modifierFlags
            let flags = ModifierFlags(
                fn: raw.contains(.function),
                ctrl: raw.contains(.control),
                cmd: raw.contains(.command),
                alt: raw.contains(.option),
                shift: raw.contains(.shift)
            )
            // Require at least one modifier — bare keys are out of scope.
            guard flags.ctrl || flags.alt || flags.cmd || flags.shift || flags.fn else { return }
            let chord = Chord(keyCode: Int(event.keyCode), modifiers: flags)
            onChordCaptured?(chord)
        }

        override func resignFirstResponder() -> Bool {
            if isRecording { onCancel?() }
            return super.resignFirstResponder()
        }
    }
}
