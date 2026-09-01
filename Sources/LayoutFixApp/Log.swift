import Foundation
import os

/// Logging for a process that can see every keystroke.
///
/// Rule: no typed text at any level above `.debug`, and always marked
/// `.private` so it is redacted in system logs unless the machine is
/// explicitly configured to reveal it. Reset reasons, counts and status are
/// safe and go out at `.info`.
enum Log {
    static let subsystem = "com.raznissim.layoutfix"

    static let app = Logger(subsystem: subsystem, category: "app")
    static let tap = Logger(subsystem: subsystem, category: "tap")
    static let engine = Logger(subsystem: subsystem, category: "engine")
}
