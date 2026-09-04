import ApplicationServices
import Foundation

/// What has keyboard focus, and whether it is a password field.
///
/// This exists because `IsSecureEventInputEnabled()` is not enough. That flag
/// only goes true when an app explicitly calls `EnableSecureEventInput()`,
/// which native `NSSecureTextField` does -- the login window, System Settings,
/// Keychain Access. Web password fields in browsers generally do not, and
/// neither do most Electron apps, so the most common place people type a
/// password was fully visible to the tap.
///
/// Asking Accessibility for the focused element's subrole closes that gap where
/// apps expose it. Deliberately kept to a single on-demand query: no observers,
/// no cached state, nothing to keep in step. It measured well under a
/// millisecond, and it runs on the tap's queue rather than in the tap callback,
/// so the callback deadline is untouched.
///
/// It reads the field's *role*, never `kAXValueAttribute`. Hebrish has no
/// business reading what is in a field, only what kind of field it is.
enum FocusedField {

    struct Info {
        let role: String
        let subrole: String

        var isSecure: Bool { subrole == (kAXSecureTextFieldSubrole as String) }
        /// For logging: structural identifiers only, never content.
        var identity: String { "\(role)/\(subrole)" }
    }

    /// - Returns: nil when the query fails, which is the fail-open case: apps
    ///   with no Accessibility support behave exactly as they did before, so
    ///   this can only add protection, never take it away.
    static func inspect() -> Info? {
        let system = AXUIElementCreateSystemWide()
        // One line of insurance against a wedged app stalling the caller.
        AXUIElementSetMessagingTimeout(system, 0.05)

        var focused: CFTypeRef?
        guard AXUIElementCopyAttributeValue(system, kAXFocusedUIElementAttribute as CFString,
                                            &focused) == .success,
              let focused, CFGetTypeID(focused) == AXUIElementGetTypeID() else { return nil }
        let element = focused as! AXUIElement

        var roleRef: CFTypeRef?
        var subroleRef: CFTypeRef?
        AXUIElementCopyAttributeValue(element, kAXRoleAttribute as CFString, &roleRef)
        AXUIElementCopyAttributeValue(element, kAXSubroleAttribute as CFString, &subroleRef)

        return Info(role: (roleRef as? String) ?? "-",
                    subrole: (subroleRef as? String) ?? "-")
    }
}
