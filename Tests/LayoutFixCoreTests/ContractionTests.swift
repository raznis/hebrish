import Foundation
import Testing
@testable import LayoutFixCore

/// English contractions are absent from the corpus: the frequency list stores
/// `'m`, `'re` and `'t` as separate tokens and never `i'm`, `you're` or
/// `don't`. Without a split analysis every contraction is out of vocabulary and
/// is refused, which is what made typing "I'm" on a Hebrew layout do nothing.
@Suite("Contractions", .enabled(if: BakedLexicon.available))
struct ContractionTests {

    func makeScorer() throws -> Scorer {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        return Scorer(lexicon: lexicon)
    }

    @Test("the corpus really has no whole contractions", arguments: [
        "i'm", "don't", "you're", "it's", "let's",
    ])
    func corpusLacksContractions(word: String) throws {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        #expect(!lexicon.isKnownWord(word, script: .latin),
                "\(word) is in the vocabulary after all -- the split analysis may be unnecessary")
    }

    /// Stored without apostrophes: `WordNormalizer.latin` trims them from the
    /// edges before baking, so the corpus entry `'re` is filed under `re`.
    @Test("but the clitics themselves are there", arguments: [
        "s", "t", "m", "re", "ll", "ve", "d",
    ])
    func corpusHasClitics(clitic: String) throws {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        let known = lexicon.isKnownWord(clitic, script: .latin)
        #expect(known, "clitic \(clitic) missing from the vocabulary")
    }

    @Test("a contraction counts as known via base + clitic", arguments: [
        "i'm", "i'd", "i'll", "i've", "you're", "you'll", "don't", "can't",
        "it's", "that's", "let's", "we're", "they've", "she'd",
    ])
    func contractionsAreKnown(word: String) throws {
        let scorer = try makeScorer()
        let known = scorer.isKnown(word, script: .latin)
        #expect(known, "\(word) still unknown")
    }

    /// The anchor: a split must not accept nonsense just because it contains an
    /// apostrophe.
    @Test("nonsense is not rescued by the apostrophe", arguments: [
        "xqz'm", "'m", "i'q", "akuo's", "zzz'll",
    ])
    func nonsenseStaysUnknown(word: String) throws {
        let scorer = try makeScorer()
        let known = scorer.isKnown(word, script: .latin)
        #expect(!known, "\(word) was wrongly accepted")
    }

    @Test("splitting improves the score, and only for real contractions")
    func scoringImproves() throws {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        // A real contraction scores far better than its unsplit form.
        #expect(lexicon.logProbWithLatinClitics("i'm") > lexicon.logProb("i'm", script: .latin))
        // A word with no apostrophe is untouched.
        #expect(lexicon.logProbWithLatinClitics("hello") == lexicon.logProb("hello", script: .latin))
    }

    /// End to end: the reported bug. Typed on a Hebrew layout, these should be
    /// recovered as English.
    @Test("contractions typed on a Hebrew layout convert back", arguments: [
        "don't", "you're", "it's", "let's", "that's", "we're",
    ])
    func contractionsConvertFromHebrew(word: String) throws {
        let scorer = try makeScorer()
        let strokes = word.compactMap { ch -> KeyStroke? in
            Fixture.pair.latin.keycodeForChar[String(ch)].map { KeyStroke(keycode: $0) }
        }
        let detail = scorer.evaluate(strokes: strokes, pair: Fixture.pair, activeScript: .hebrew)
        let verdict = detail.verdict
        #expect(verdict == .convert(to: .latin, text: word),
                "\(word): margin \(detail.margin), latin \(detail.latinScore), hebrew \(detail.hebrewScore)")
    }

    /// Correctly typed English contractions must still be left alone.
    @Test("contractions typed correctly are not touched", arguments: [
        "don't", "you're", "it's", "let's", "i'm", "that's",
    ])
    func correctContractionsUntouched(word: String) throws {
        let scorer = try makeScorer()
        let strokes = word.compactMap { ch -> KeyStroke? in
            Fixture.pair.latin.keycodeForChar[String(ch)].map { KeyStroke(keycode: $0) }
        }
        let detail = scorer.evaluate(strokes: strokes, pair: Fixture.pair, activeScript: .latin)
        let verdict = detail.verdict
        #expect(verdict == .keep, "\(word) was converted: margin \(detail.margin)")
    }
}

/// Shift on the Hebrew layout emits nothing for letter keys. The keystroke is
/// still part of what the user meant, so it belongs in the token -- but it must
/// not be counted among the characters a correction has to delete.
@Suite("Capitals typed on a layout with no shifted output")
struct ShiftedOutputTests {

    @Test("a key with no shifted output produces nothing")
    func noShiftedOutput() {
        let shifted = KeyStroke(keycode: 4, shift: true)   // h / yod
        #expect(Fixture.pair.hebrew.char(for: shifted) == nil,
                "must not fall back to the unshifted letter")
        #expect(Fixture.pair.latin.char(for: shifted) == "H")
    }

    @Test("the keystroke stays in the token but adds nothing to the delete count")
    func producedLengthExcludesInvisibleKeys() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        var t = 1.0
        // "Hi" with Hebrew live: Shift+H emits nothing, i emits nun-final.
        for (keycode, shift) in [(UInt16(4), true), (UInt16(34), false), (VK.space, false)] {
            let produced = Fixture.pair.hebrew.char(for: KeyStroke(keycode: keycode, shift: shift))
            _ = buffer.handleKeyDown(keycode: keycode, shift: shift,
                                     hasCommandControlOrOption: false,
                                     producedCharacter: produced,
                                     activeScript: .hebrew, timestamp: t)
            t += 0.05
        }
        let token = buffer.lastCompleted
        #expect(token?.strokes.count == 2, "both keystrokes belong to the token")
        #expect(token?.producedLength == 1, "only the visible character counts")
        // The capital survives into the recovered English.
        #expect(Fixture.pair.reading(token!.strokes, as: .latin) == "Hi")
    }

    @Test("produced text matches what the layout actually emits")
    func producedMatchesLayout() {
        let strokes = Fixture.strokes("Hello")
        #expect(Fixture.pair.produced(strokes, activeScript: .latin) == "Hello")
        // Shift+H emits nothing on Hebrew, so four characters, not five.
        #expect(Fixture.pair.produced(strokes, activeScript: .hebrew) == "קךךם")
        #expect(Fixture.pair.reading(strokes, as: .latin) == "Hello")
    }
}
