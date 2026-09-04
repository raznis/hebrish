import Foundation
import LayoutFixCore

/// User preferences, persisted in UserDefaults.
///
/// One entry does derive from typing, and it is worth being explicit about:
/// `learnedExceptions` holds words the user has actively rejected a correction
/// for. Nothing else typed is retained -- the buffer is in-memory only and is
/// overwritten on reset. The exception list is capped, visible in the menu, and
/// clearable in one action, because it is the only durable trace the app keeps.
final class Settings {
    private let defaults: UserDefaults

    private enum Key {
        static let enabled = "enabled"
        static let deniedBundleIDs = "deniedBundleIDs"
        static let interKeyDelay = "interKeyDelayMilliseconds"
        static let threshold = "threshold"
        static let learnedExceptions = "learnedExceptions"
        static let showToast = "showToast"
    }

    /// Apps Hebrish stays out of. Seeded with password managers and
    /// credential UIs, where a mis-fire would be worst and where text is often
    /// not language at all.
    static let defaultDeniedBundleIDs = [
        "com.apple.keychainaccess",
        "com.1password.1password",
        "com.agilebits.onepassword7",
        "com.lastpass.LastPass",
        "com.bitwarden.desktop",
        "com.apple.SecurityAgent",
        "com.apple.loginwindow",
    ]

    /// The identifier before the rename to Hebrish. Read once, so an existing
    /// install does not silently lose its rejected words when the bundle
    /// identifier changes and with it the preferences domain.
    private static let previousDomain = "com.raznissim.layoutfix"

    /// - Parameter defaults: injectable so diagnostics can run against a
    ///   scratch domain instead of the user's real preferences.
    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        // Before register(defaults:), deliberately: registered defaults are
        // returned by array(forKey:), so a check afterwards cannot tell "never
        // stored" from "stored as empty" and the migration silently no-ops.
        migrateFromPreviousDomain()
        defaults.register(defaults: [
            Key.enabled: true,
            Key.deniedBundleIDs: Settings.defaultDeniedBundleIDs,
            Key.interKeyDelay: 1.0,
            Key.threshold: ScorerConfig().threshold,
            Key.learnedExceptions: [String](),
            Key.showToast: true,
        ])
    }

    /// One-way, one-time: only fills a key the new domain has never had.
    /// Deliberately narrow -- it moves the rejected words and nothing else,
    /// since every other setting is a preference the user can simply set again.
    private func migrateFromPreviousDomain() {
        guard defaults.array(forKey: Key.learnedExceptions) == nil else { return }
        // persistentDomain rather than UserDefaults(suiteName:): suiteName is
        // for app groups and is not a dependable way to read another bundle
        // identifier's preferences.
        guard let old = defaults.persistentDomain(forName: Settings.previousDomain),
              let words = old[Key.learnedExceptions] as? [String],
              !words.isEmpty else { return }
        defaults.set(words, forKey: Key.learnedExceptions)
        Log.app.info("migrated \(words.count, privacy: .public) rejected word(s) from the previous identifier")
    }

    var isEnabled: Bool {
        get { defaults.bool(forKey: Key.enabled) }
        set { defaults.set(newValue, forKey: Key.enabled) }
    }

    var deniedBundleIDs: Set<String> {
        get { Set(defaults.stringArray(forKey: Key.deniedBundleIDs) ?? []) }
        set { defaults.set(Array(newValue).sorted(), forKey: Key.deniedBundleIDs) }
    }

    var interKeyDelay: TimeInterval {
        get { defaults.double(forKey: Key.interKeyDelay) / 1000.0 }
        set { defaults.set(newValue * 1000.0, forKey: Key.interKeyDelay) }
    }

    var threshold: Double {
        get { defaults.double(forKey: Key.threshold) }
        set { defaults.set(newValue, forKey: Key.threshold) }
    }

    var showToast: Bool {
        get { defaults.bool(forKey: Key.showToast) }
        set { defaults.set(newValue, forKey: Key.showToast) }
    }

    /// Words the user has rejected a correction for. The only stored value
    /// derived from what they typed.
    var learnedExceptions: LearnedExceptions {
        get { LearnedExceptions(defaults.stringArray(forKey: Key.learnedExceptions) ?? []) }
        set { defaults.set(newValue.storage, forKey: Key.learnedExceptions) }
    }
}
