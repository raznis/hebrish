import AppKit
import ApplicationServices
import Carbon

/// Accessibility permission, which a keyboard event tap cannot work without.
enum Permissions {

    static var isTrusted: Bool {
        AXIsProcessTrusted()
    }

    /// Ask macOS to show the "grant access" prompt. Returns the current state,
    /// which is almost always false the first time -- the user has to act in
    /// System Settings and the app has to be relaunched.
    @discardableResult
    static func requestTrust() -> Bool {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as NSString
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    static func openAccessibilitySettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
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
