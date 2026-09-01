import AppKit
import ApplicationServices
import Carbon
import CoreGraphics

/// The two separate permissions LayoutFix needs, and the APIs that answer
/// honestly about them.
///
/// They are easy to conflate and they live in different lists in System
/// Settings:
///
/// - **Input Monitoring** gates *reading* the keyboard. `CGEvent.tapCreate`
///   will happily hand back a valid port without it and then deliver nothing at
///   all, so the port is no evidence of anything. `CGPreflightListenEventAccess`
///   is the real answer.
/// - **Accessibility** gates *posting* synthetic events into other apps, which
///   is how a correction is applied.
///
/// The app needs both. With only Input Monitoring it detects and cannot fix;
/// with only Accessibility it never sees anything to fix.
enum Permissions {

    struct State: Equatable {
        /// Input Monitoring: may we read the keyboard?
        var canListen: Bool
        /// Accessibility: may we post keystrokes into other apps?
        var canPost: Bool

        var isComplete: Bool { canListen && canPost }

        var missing: [String] {
            var out: [String] = []
            if !canListen { out.append("Input Monitoring") }
            if !canPost { out.append("Accessibility") }
            return out
        }
    }

    static var state: State {
        State(canListen: CGPreflightListenEventAccess(), canPost: AXIsProcessTrusted())
    }

    /// Ask macOS to show the system prompts for whatever is missing.
    ///
    /// Both prompts only appear once per app identity; afterwards the user has
    /// to go to System Settings directly, which is why the menu and the
    /// diagnostics both offer to open it.
    static func request(_ state: State = Permissions.state) {
        if !state.canListen {
            CGRequestListenEventAccess()
        }
        if !state.canPost {
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        }
    }

    static func openInputMonitoringSettings() {
        open("Privacy_ListenEvent")
    }

    static func openAccessibilitySettings() {
        open("Privacy_Accessibility")
    }

    private static func open(_ anchor: String) {
        guard let url = URL(string:
            "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        NSWorkspace.shared.open(url)
    }

    /// True while a password field or similar has taken over the keyboard.
    ///
    /// Every keystroke is skipped in this state. LayoutFix must never see, let
    /// alone buffer, a password.
    static var isSecureInputEnabled: Bool {
        IsSecureEventInputEnabled()
    }
}
