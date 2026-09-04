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

    /// One rejected word, with the layout it was typed under.
    ///
    /// The script is carried rather than discarded because the same characters
    /// can be rejected under either layout, and removing one must not silently
    /// take the other with it.
    public struct Entry: Sendable, Equatable, Hashable {
        public let word: String
        public let script: Script

        public var storageKey: String {
            LearnedExceptions.key(typed: word, script: script)
        }

        public init(word: String, script: Script) {
            self.word = word
            self.script = script
        }

        /// Parse a stored key back into an entry. Words are normalised to
        /// letters and apostrophes, so the first colon is unambiguously the
        /// separator.
        public init?(storageKey: String) {
            guard let separator = storageKey.firstIndex(of: ":") else { return nil }
            guard let script = Script(rawValue: String(storageKey[..<separator])) else { return nil }
            let word = String(storageKey[storageKey.index(after: separator)...])
            guard !word.isEmpty else { return nil }
            self.init(word: word, script: script)
        }
    }

    /// Rejected words, most recently rejected first -- the order to show them
    /// in, since the newest is the one most likely to have been a mistake.
    public var entries: [Entry] {
        keys.reversed().compactMap(Entry.init(storageKey:))
    }

    /// Stop blocking one specific word, leaving the rest alone.
    public mutating func remove(_ entry: Entry) {
        remove(storageKey: entry.storageKey)
    }

    public mutating func remove(storageKey: String) {
        keys.removeAll { $0 == storageKey }
    }

    /// Human-readable, most recent first.
    public var descriptions: [String] {
        entries.map(\.word)
    }
}
