import Foundation
import CoreGraphics
import LayoutFixCore

/// Listens to the keyboard through a Quartz event tap.
///
/// Listen-only by design. We cannot suppress the keystroke that triggers a
/// correction, so a correction deletes the boundary character and retypes it --
/// in exchange, it is structurally impossible for a bug here to swallow the
/// user's typing.
///
/// The callback must stay fast: macOS disables a tap whose callback overruns
/// its deadline. So the callback does the minimum -- reject our own events,
/// read keycode and flags, hand off to a serial queue -- and every dictionary
/// lookup and synthesised keystroke happens off it.
final class KeyTap {

    enum Event {
        case keyDown(keycode: UInt16, shift: Bool, hasCommandControlOrOption: Bool)
        /// Anything meaning the caret may have moved or the context changed.
        case interrupt(ResetReason)
    }

    /// Called on `queue` for every event of interest.
    var onEvent: ((Event) -> Void)?

    /// Serial queue on which `onEvent` runs, and on which corrections are applied.
    let queue = DispatchQueue(label: "com.raznissim.layoutfix.events", qos: .userInteractive)

    private var tap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    private static let mask: CGEventMask =
        (1 << CGEventType.keyDown.rawValue) |
        (1 << CGEventType.leftMouseDown.rawValue) |
        (1 << CGEventType.rightMouseDown.rawValue) |
        (1 << CGEventType.otherMouseDown.rawValue)

    var isRunning: Bool { tap != nil }

    /// - Returns: false if the tap could not be created, which in practice
    ///   always means Accessibility permission has not been granted.
    func start() -> Bool {
        guard tap == nil else { return true }

        let callback: CGEventTapCallBack = { _, type, event, refcon in
            guard let refcon else { return nil }
            let tap = Unmanaged<KeyTap>.fromOpaque(refcon).takeUnretainedValue()
            return tap.handle(type: type, event: event)
        }

        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .listenOnly,
            eventsOfInterest: KeyTap.mask,
            callback: callback,
            userInfo: Unmanaged.passUnretained(self).toOpaque())
        else { return false }

        tap = port
        runLoopSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        CGEvent.tapEnable(tap: port, enable: true)
        return true
    }

    func stop() {
        if let runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetMain(), runLoopSource, .commonModes)
        }
        if let tap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        runLoopSource = nil
        tap = nil
    }

    // MARK: the hot path

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS switched us off, usually for overrunning the callback deadline.
        // Turn back on rather than silently dying.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            deliver(.interrupt(.manual))
            return Unmanaged.passUnretained(event)
        }

        // Our own synthesised keystrokes, echoed back. Ignoring these is what
        // stops a correction from feeding itself.
        if event.getIntegerValueField(.eventSourceUserData) == Injector.selfEventMarker {
            return Unmanaged.passUnretained(event)
        }

        switch type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown:
            // A click moves the caret, so whatever we buffered may no longer be
            // where we think it is.
            deliver(.interrupt(.mouseClick))

        case .keyDown:
            let keycode = UInt16(event.getIntegerValueField(.keyboardEventKeycode))
            let flags = event.flags
            let shift = flags.contains(.maskShift)
            let chord = flags.contains(.maskCommand)
                || flags.contains(.maskControl)
                || flags.contains(.maskAlternate)
            deliver(.keyDown(keycode: keycode, shift: shift,
                             hasCommandControlOrOption: chord))

        default:
            break
        }

        return Unmanaged.passUnretained(event)
    }

    private func deliver(_ event: Event) {
        queue.async { [weak self] in
            self?.onEvent?(event)
        }
    }
}
