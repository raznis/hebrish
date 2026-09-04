import Foundation

/// Virtual keycodes we care about structurally, named so the tap and the
/// buffer are not littered with magic numbers.
public enum VK {
    public static let delete: UInt16 = 51        // backspace
    public static let forwardDelete: UInt16 = 117
    public static let tab: UInt16 = 48
    public static let space: UInt16 = 49
    public static let ret: UInt16 = 36
    public static let keypadEnter: UInt16 = 76
    public static let escape: UInt16 = 53
    public static let leftArrow: UInt16 = 123
    public static let rightArrow: UInt16 = 124
    public static let downArrow: UInt16 = 125
    public static let upArrow: UInt16 = 126
    public static let home: UInt16 = 115
    public static let end: UInt16 = 119
    public static let pageUp: UInt16 = 116
    public static let pageDown: UInt16 = 121

    /// Keys that always end a word regardless of the active layout.
    public static let universalBoundaries: Set<UInt16> = [space, ret, keypadEnter, tab]

    /// Keys that mean the caret moved or the context changed, so whatever we
    /// think is on screen may no longer be there.
    public static let navigation: Set<UInt16> = [
        leftArrow, rightArrow, upArrow, downArrow, home, end, pageUp, pageDown,
        escape, forwardDelete,
    ]
}

/// Why the buffer was discarded. Surfaced for debugging and the status menu.
public enum ResetReason: String, Sendable {
    case navigation
    case deletion
    case modifierChord
    case focusChange
    case inputSourceChange
    case mouseClick
    case idleTimeout
    case correctionApplied
    case capacity
    case secureInput
    /// The focused field is a secure text field, even though the global
    /// secure-input flag is not set -- typical of web password fields.
    case secureField
    case manual
}

/// A word the user just finished typing, with everything needed to replace it.
public struct CompletedToken: Sendable {
    public let strokes: [KeyStroke]
    /// The boundary key that ended it, if any. `nil` when the token was closed
    /// by something other than a keypress.
    public let boundary: KeyStroke?
    /// Characters this token put on screen under the layout that was live --
    /// this, plus the boundary, is what a correction has to delete.
    public let producedLength: Int
    public let activeScript: Script
}

/// Accumulates keystrokes into words and decides when the accumulated text can
/// no longer be trusted to still be on screen.
///
/// Pure logic: it is told about events, it never observes them. The event tap
/// drives it, and the tests drive it too.
///
/// Nothing here is ever written to disk, and the buffer is bounded and zeroed
/// on every reset -- this type holds live keystrokes and is treated
/// accordingly.
public struct TypingBuffer {

    /// Longest word we will consider. Also bounds how much we ever retain.
    public let capacity: Int
    /// A gap longer than this means the user paused; the caret may have moved
    /// by other means in the meantime.
    public let idleTimeout: TimeInterval
    /// Which keys continue a word. Derived from the live layouts.
    public let rules: TokenizerRules

    /// Keystrokes of the word currently being typed.
    public private(set) var current: [KeyStroke] = []
    /// Words already completed in this uninterrupted run, most recent last.
    /// Used for lookback once a later word proves the run was mis-keyed.
    public private(set) var run: [CompletedToken] = []
    public private(set) var lastEventTime: TimeInterval = 0
    public private(set) var lastResetReason: ResetReason?

    public init(rules: TokenizerRules, capacity: Int = 64, idleTimeout: TimeInterval = 4.0) {
        self.rules = rules
        self.capacity = capacity
        self.idleTimeout = idleTimeout
    }

    public var isEmpty: Bool { current.isEmpty && run.isEmpty }

    public mutating func reset(_ reason: ResetReason) {
        // Overwrite rather than just dropping the reference.
        for i in current.indices { current[i] = KeyStroke(keycode: 0) }
        current.removeAll(keepingCapacity: true)
        run.removeAll(keepingCapacity: true)
        lastResetReason = reason
    }

    /// What the tap should do about a key event.
    public enum Outcome: Equatable {
        /// Nothing to evaluate yet.
        case accumulating
        /// A word just ended and is ready to be scored.
        case tokenCompleted
        /// The buffer was discarded.
        case reset(ResetReason)
        /// Not a text-producing key and not interesting.
        case ignored
    }

    /// Feed one key-down event.
    ///
    /// - Parameters:
    ///   - keycode: hardware keycode.
    ///   - shift: whether Shift was held.
    ///   - hasCommandControlOrOption: any of Cmd/Ctrl/Opt held. Such a
    ///     combination is a command, not typing, and may have moved the caret.
    ///   - producedCharacter: what the key put on screen under the live layout,
    ///     or nil if it produced nothing.
    ///   - activeScript: script of the live input source.
    ///   - timestamp: monotonic seconds.
    public mutating func handleKeyDown(keycode: UInt16,
                                       shift: Bool,
                                       hasCommandControlOrOption: Bool,
                                       producedCharacter: String?,
                                       activeScript: Script,
                                       timestamp: TimeInterval) -> Outcome {
        // A pause long enough that the caret may have moved by other means.
        if !isEmpty, lastEventTime > 0, timestamp - lastEventTime > idleTimeout {
            reset(.idleTimeout)
            // Fall through: this keystroke starts a fresh run.
        }
        lastEventTime = timestamp

        if hasCommandControlOrOption {
            // Cmd-V, Ctrl-A, Opt-arrow: a command, and we cannot know what it
            // did to the text. Shift alone is ordinary typing.
            if !isEmpty { reset(.modifierChord); return .reset(.modifierChord) }
            return .ignored
        }

        if VK.navigation.contains(keycode) {
            if !isEmpty { reset(.navigation); return .reset(.navigation) }
            return .ignored
        }

        if keycode == VK.delete {
            // Backspace inside the current word could be tracked, but the user
            // is editing, so the cheap and safe move is to stop trusting the
            // buffer.
            if !isEmpty { reset(.deletion); return .reset(.deletion) }
            return .ignored
        }

        // Tokenize on keycodes, not on the character the live layout produced:
        // a key that is punctuation now may be a letter in the language the
        // user actually meant.
        let isBoundary = VK.universalBoundaries.contains(keycode) || !rules.isWordKey(keycode)

        if isBoundary {
            guard !current.isEmpty else {
                // Boundary with nothing before it: whitespace runs, leading
                // punctuation. Keep the run intact for lookback, but a newline
                // means a new line of text.
                if keycode == VK.ret || keycode == VK.keypadEnter {
                    reset(.navigation)
                    return .reset(.navigation)
                }
                return .accumulating
            }
            let stroke = KeyStroke(keycode: keycode, shift: shift)
            let produced = pendingProducedLength
            run.append(CompletedToken(strokes: current,
                                      boundary: stroke,
                                      producedLength: produced,
                                      activeScript: activeScript))
            current.removeAll(keepingCapacity: true)
            pendingProducedLength = 0
            trimRun()
            return .tokenCompleted
        }

        // Membership is decided by the keycode, above; whether the key put
        // anything on screen is a separate question. Shift on the Hebrew layout
        // emits nothing for most letters, and such a keystroke is still part of
        // what the user meant -- it belongs in the token, and contributes
        // nothing to the count of characters a correction has to delete.
        current.append(KeyStroke(keycode: keycode, shift: shift))
        pendingProducedLength += producedCharacter?.count ?? 0

        if current.count > capacity {
            reset(.capacity)
            return .reset(.capacity)
        }
        return .accumulating
    }

    /// The token just completed, or nil.
    public var lastCompleted: CompletedToken? { run.last }

    /// Tokens before the last completed one, oldest first — the lookback
    /// candidates.
    public var lookbackCandidates: [CompletedToken] {
        run.count > 1 ? Array(run.dropLast()) : []
    }

    /// Called after a correction is applied: the text on screen now matches the
    /// corrected form, and the input source has changed, so start fresh.
    public mutating func noteCorrectionApplied() {
        reset(.correctionApplied)
    }

    // MARK: internals

    private var pendingProducedLength = 0

    /// Keep the run bounded: only the recent past is ever replaceable anyway.
    private mutating func trimRun() {
        let maxTokens = 12
        var totalStrokes = run.reduce(0) { $0 + $1.strokes.count }
        while run.count > maxTokens || totalStrokes > capacity {
            guard !run.isEmpty else { break }
            totalStrokes -= run[0].strokes.count
            run.removeFirst()
        }
    }

}

/// Which keys continue a word, derived from the two live layouts.
///
/// A key must stay inside a word if it is a letter in *either* script, because
/// at typing time we do not yet know which language the user meant. The comma
/// key is the motivating case: punctuation under a Latin layout, but tav under
/// Hebrew -- and tav is a very common word-final letter, so breaking the token
/// there would silently truncate `וילדות` to `וילדו`.
public struct TokenizerRules: Sendable {
    /// Keycodes that produce a letter under at least one of the two layouts.
    public let wordKeycodes: Set<UInt16>

    public init(wordKeycodes: Set<UInt16>) {
        self.wordKeycodes = wordKeycodes
    }

    public init(pair: LayoutPair) {
        var keys = Set<UInt16>()
        for script in Script.allCases {
            let table = pair.table(for: script)
            for (keycode, char) in table.unshifted {
                guard let first = char.first else { continue }
                if WordNormalizer.isLetter(first, script: script) {
                    keys.insert(keycode)
                }
            }
        }
        // Never let a universal separator be treated as word-internal, whatever
        // the layout tables happen to say about it.
        keys.subtract(VK.universalBoundaries)
        self.wordKeycodes = keys
    }

    public func isWordKey(_ keycode: UInt16) -> Bool { wordKeycodes.contains(keycode) }
}
