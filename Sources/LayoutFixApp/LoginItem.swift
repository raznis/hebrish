import Foundation
import ServiceManagement
import os

/// Start-at-login, via the modern `SMAppService` API.
///
/// Only meaningful for an installed bundle: registering a binary running out of
/// `.build` would point the login item at a path that changes.
enum LoginItem {

    static var isRegistered: Bool {
        SMAppService.mainApp.status == .enabled
    }

    static var isAvailable: Bool {
        // Registering only makes sense once the app lives somewhere stable.
        Bundle.main.bundlePath.hasSuffix(".app")
    }

    @discardableResult
    static func setRegistered(_ register: Bool) -> Bool {
        do {
            if register {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            return true
        } catch {
            Log.app.error("login item \(register ? "register" : "unregister", privacy: .public) failed: \(error.localizedDescription, privacy: .public)")
            return false
        }
    }
}
