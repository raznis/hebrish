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

    /// Latin words of any length need a vowel (or y) to be pronounceable.
    public static func hasNoVowel(_ word: String) -> Bool {
        !word.contains { "aeiouy".contains($0) }
    }
}
