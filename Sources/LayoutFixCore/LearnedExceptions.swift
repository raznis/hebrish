import Foundation

/// Words the user has explicitly rejected a correction for, which are never
/// converted again.
///
/// Keyed by what the user *typed*, not by what we proposed: the point is to
/// preserve the characters they wanted. Someone typing the name `gus` in
/// English wants `gus`, and telling us so once should settle it permanently --
/// otherwise the same fight recurs every time they type their colleague's name.
///
/// Note on privacy: this is the only thing LayoutFix retains that derives from
/// typing, and it holds only tokens the user deliberately rejected. It is
/// capped, inspectable from the menu, and clearable in one action.
public struct LearnedExceptions: Sendable, Equatable {

    /// Upper bound on retention. Far more than anyone accumulates by hand, and
    /// it stops a stuck hotkey from growing the list without limit.
    public static let maxEntries = 500

    private var keys: [String]

    public init(_ keys: [String] = []) {
        self.keys = Array(keys.suffix(LearnedExceptions.maxEntries))
    }

    /// Storage key for a token as typed under a given layout.
    ///
    /// Script-qualified because the same characters mean different things
    /// depending on which layout produced them: `gus` typed on a Latin layout
    /// is an English word to protect, while the same three keys on a Hebrew
    /// layout are a different decision entirely.
    public static func key(typed: String, script: Script) -> String {
        "\(script.rawValue):\(typed.lowercased())"
    }

    public func contains(typed: String, script: Script) -> Bool {
        keys.contains(LearnedExceptions.key(typed: typed, script: script))
    }

    /// Record a rejection. Most-recent-last, deduplicated, bounded.
    public mutating func insert(typed: String, script: Script) {
        let key = LearnedExceptions.key(typed: typed, script: script)
        keys.removeAll { $0 == key }
        keys.append(key)
        if keys.count > LearnedExceptions.maxEntries {
            keys.removeFirst(keys.count - LearnedExceptions.maxEntries)
        }
    }

    public mutating func removeAll() {
        keys.removeAll()
    }

    /// Raw storage form, for persisting.
    public var storage: [String] { keys }

    public var count: Int { keys.count }
    public var isEmpty: Bool { keys.isEmpty }

    /// Human-readable, most recent first, for the menu.
    public var descriptions: [String] {
        keys.reversed().map { key in
            guard let separator = key.firstIndex(of: ":") else { return key }
            return String(key[key.index(after: separator)...])
        }
    }
}
