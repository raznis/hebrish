import Foundation

/// Canonicalises words before they enter or are looked up in the lexicon.
/// The bake step and the runtime scorer MUST agree, so both go through here.
public enum WordNormalizer {

    /// Hebrew letters alef..tav, including the five final forms.
    static let hebrewLetters: ClosedRange<UInt32> = 0x05D0...0x05EA
    /// Niqqud, cantillation and other combining marks.
    static let hebrewMarks: ClosedRange<UInt32> = 0x0591...0x05C7

    /// The five final forms, which may only appear word-finally in real Hebrew.
    public static let hebrewFinalForms: Set<Character> = ["ך", "ם", "ן", "ף", "ץ"]

    /// Latin: lowercase, keep a-z and the apostrophe, trim edge apostrophes.
    /// Returns nil if anything else is present.
    public static func latin(_ raw: String) -> String? {
        let lowered = raw.lowercased()
        var out = ""
        out.reserveCapacity(lowered.count)
        for ch in lowered {
            if ch.isASCII && ch >= "a" && ch <= "z" { out.append(ch) }
            else if ch == "'" || ch == "\u{2019}" { out.append("'") }
            else { return nil }
        }
        while out.hasPrefix("'") { out.removeFirst() }
        while out.hasSuffix("'") { out.removeLast() }
        return out.isEmpty ? nil : out
    }

    /// Hebrew: strip combining marks and geresh/gershayim, keep alef..tav.
    /// Returns nil if anything else is present.
    public static func hebrew(_ raw: String) -> String? {
        var out = ""
        out.reserveCapacity(raw.count)
        for scalar in raw.unicodeScalars {
            let v = scalar.value
            if hebrewLetters.contains(v) {
                out.unicodeScalars.append(scalar)
            } else if hebrewMarks.contains(v) || v == 0x05F3 || v == 0x05F4 {
                continue  // niqqud / geresh: drop
            } else {
                return nil
            }
        }
        return out.isEmpty ? nil : out
    }

    public static func normalize(_ raw: String, script: Script) -> String? {
        script == .latin ? latin(raw) : hebrew(raw)
    }

    /// True when a final-form letter sits somewhere other than the last
    /// position — orthographically impossible in Hebrew, and the single
    /// strongest signal that a "Hebrew" string is really mis-keyed English.
    public static func hasMisplacedFinalForm(_ word: String) -> Bool {
        let chars = Array(word)
        guard chars.count >= 2 else { return false }
        for ch in chars.dropLast() where hebrewFinalForms.contains(ch) {
            return true
        }
        return false
    }

    /// A word split into its letter core and the punctuation around it.
    public struct Split {
        /// The normalised letters, ready for a lexicon lookup.
        public let core: String
        /// Characters trimmed from the front and back (ordinary punctuation).
        public let leading: String
        public let trailing: String
        /// Characters inside the core that do not belong to this script.
        public let internalForeignCount: Int
    }

    /// Whether a character is a letter of this script.
    /// The apostrophe counts for Latin so contractions stay whole.
    public static func isLetter(_ ch: Character, script: Script) -> Bool {
        switch script {
        case .latin:
            if ch == "'" || ch == "\u{2019}" { return true }
            return ch.isASCII && (ch.lowercased().first.map { $0 >= "a" && $0 <= "z" } ?? false)
        case .hebrew:
            guard let scalar = ch.unicodeScalars.first, ch.unicodeScalars.count == 1 else {
                // A letter plus combining niqqud.
                return ch.unicodeScalars.allSatisfy {
                    hebrewLetters.contains($0.value) || hebrewMarks.contains($0.value)
                }
            }
            return hebrewLetters.contains(scalar.value)
        }
    }

    /// Separate a token into surrounding punctuation and a letter core.
    ///
    /// Needed because the same key can be punctuation in one script and a
    /// letter in the other: under a Latin layout the comma key is a comma, but
    /// under Hebrew it is tav -- an extremely common word-final letter. Reading
    /// "uhksu," as Hebrew must yield the whole word `וילדות`, while reading
    /// "hello," as Latin must yield `hello` with the comma set aside rather
    /// than counted against it.
    public static func split(_ text: String, script: Script) -> Split? {
        let chars = Array(text)
        var start = 0, end = chars.count
        while start < end, !isLetter(chars[start], script: script) { start += 1 }
        while end > start, !isLetter(chars[end - 1], script: script) { end -= 1 }
        guard start < end else { return nil }

        let coreChars = chars[start..<end]
        let internalForeign = coreChars.filter { !isLetter($0, script: script) }.count

        // Normalise the core, dropping anything foreign that survived inside it.
        var core = ""
        core.reserveCapacity(coreChars.count)
        for ch in coreChars where isLetter(ch, script: script) {
            switch script {
            case .latin:
                core += (ch == "\u{2019}") ? "'" : ch.lowercased()
            case .hebrew:
                for scalar in ch.unicodeScalars where hebrewLetters.contains(scalar.value) {
                    core.unicodeScalars.append(scalar)
                }
            }
        }
        var trimmed = core
        while trimmed.hasPrefix("'") { trimmed.removeFirst() }
        while trimmed.hasSuffix("'") { trimmed.removeLast() }
        guard !trimmed.isEmpty else { return nil }

        return Split(core: trimmed,
                     leading: String(chars[0..<start]),
                     trailing: String(chars[end..<chars.count]),
                     internalForeignCount: internalForeign)
    }

    /// Latin words of any length need a vowel (or y) to be pronounceable.
    public static func hasNoVowel(_ word: String) -> Bool {
        !word.contains { "aeiouy".contains($0) }
    }
}
