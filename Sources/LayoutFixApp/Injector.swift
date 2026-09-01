import Foundation
import CoreGraphics
import Carbon.HIToolbox
import LayoutFixCore

/// Applies a correction by synthesising keyboard events.
///
/// Backspace-and-retype rather than the Accessibility API, because it works in
/// every app -- AppKit, Electron, terminals -- whereas settable `AXValue` does
/// not. Text is posted as Unicode strings rather than keycodes, so the
/// characters we insert do not depend on which layout happens to be live.
final class Injector {

    /// Stamped into every event we generate, so the tap can recognise its own
    /// output and not feed it back into the buffer.
    static let selfEventMarker: Int64 = 0x4C46_5831  // 'LFX1'

    struct Timing {
        /// Wait before the first backspace, so the keystroke that triggered the
        /// correction has certainly been delivered to the app first.
        var preDelay: TimeInterval = 0.008
        /// Between synthesised events. Some apps drop events posted too fast.
        var interKeyDelay: TimeInterval = 0.001
        /// After the text, before switching the input source.
        var postDelay: TimeInterval = 0.004
    }

    var timing = Timing()
    private let source = CGEventSource(stateID: .privateState)

    /// Delete `deleteCount` characters and type `replacement`.
    /// Blocking; call from a background queue, never from the tap callback.
    func apply(_ correction: Correction) {
        sleep(timing.preDelay)

        for _ in 0..<correction.deleteCount {
            postKey(VK.delete, down: true)
            postKey(VK.delete, down: false)
        }

        // One event per character. Some apps mishandle a long Unicode payload
        // on a single event, and per-character is what text expanders do.
        for character in correction.replacement {
            postText(String(character))
        }

        sleep(timing.postDelay)
    }

    // MARK: internals

    private func sleep(_ interval: TimeInterval) {
        guard interval > 0 else { return }
        usleep(useconds_t(interval * 1_000_000))
    }

    private func stamp(_ event: CGEvent) {
        // Clear inherited modifier state: a Shift the user happens to be
        // holding must not alter what we insert.
        event.flags = []
        event.setIntegerValueField(.eventSourceUserData, value: Injector.selfEventMarker)
    }

    private func postKey(_ keycode: UInt16, down: Bool) {
        guard let event = CGEvent(keyboardEventSource: source,
                                  virtualKey: keycode, keyDown: down) else { return }
        stamp(event)
        event.post(tap: .cgSessionEventTap)
        sleep(timing.interKeyDelay)
    }

    private func postText(_ text: String) {
        let utf16 = Array(text.utf16)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: source,
                                      virtualKey: 0, keyDown: down) else { return }
            stamp(event)
            event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
            event.post(tap: .cgSessionEventTap)
            sleep(timing.interKeyDelay)
        }
    }
}
