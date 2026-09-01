import Foundation
import Testing
@testable import LayoutFixCore

// MARK: - The decision rule, in isolation

@Suite("Decision rule")
struct ScorerRuleTests {

    /// A scorer whose lexicon is never consulted: these tests drive the rule
    /// directly through `ReadingScores`.
    let scorer = Scorer(lexicon: Lexicon(
        latin: .init(unigrams: [:], ngram: CharNGram(unigrams: [:], bigrams: [:], trigrams: [:])),
        hebrew: .init(unigrams: [:], ngram: CharNGram(unigrams: [:], bigrams: [:], trigrams: [:]))))

    func scores(strokes: Int, margin: Double, known: Bool = true,
                otherScore: Double = -10, normalizable: Bool = true) -> ReadingScores {
        ReadingScores(strokeCount: strokes,
                      currentScore: otherScore - margin,
                      otherScore: otherScore,
                      otherNormalizable: normalizable,
                      otherKnown: known,
                      otherLength: strokes)
    }

    @Test("a long token with a clear margin converts")
    func longTokenConverts() {
        #expect(scorer.shouldConvert(scores(strokes: 6, margin: 10)))
    }

    @Test("a long token below the base threshold is left alone")
    func belowThreshold() {
        #expect(!scorer.shouldConvert(scores(strokes: 6, margin: 3)))
    }

    /// Short tokens must clear a larger margin, because two letters of
    /// agreement is coincidence where six is proof.
    @Test("short tokens need a bigger margin", arguments: [
        (2, 6.0, false),    // 6 nats is plenty at length 6, nowhere near enough at 2
        (2, 20.0, true),
        (3, 10.0, false),
        (3, 16.0, true),
        (4, 8.0, false),
        (4, 12.0, true),
        (5, 7.0, true),
    ])
    func lengthGrading(strokes: Int, margin: Double, expected: Bool) {
        #expect(scorer.shouldConvert(scores(strokes: strokes, margin: margin)) == expected)
    }

    @Test("required margin decreases with length up to reliableLength")
    func requiredMarginShape() {
        let c = ScorerConfig()
        #expect(c.requiredMargin(strokeCount: 2) > c.requiredMargin(strokeCount: 3))
        #expect(c.requiredMargin(strokeCount: 4) > c.requiredMargin(strokeCount: 5))
        // Flat once the token is long enough to be self-evidencing.
        #expect(c.requiredMargin(strokeCount: 5) == c.requiredMargin(strokeCount: 9))
    }

    @Test("tokens below the minimum length never convert")
    func minimumLength() {
        #expect(!scorer.shouldConvert(scores(strokes: 1, margin: 100)))
    }

    @Test("an unspellable target reading never converts")
    func unspellableTarget() {
        #expect(!scorer.shouldConvert(scores(strokes: 6, margin: 100, normalizable: false)))
    }

    @Test("an unknown target word needs an overwhelming margin")
    func unknownWordNeedsOverwhelmingMargin() {
        #expect(!scorer.shouldConvert(scores(strokes: 6, margin: 12, known: false)))
        #expect(scorer.shouldConvert(scores(strokes: 6, margin: 35, known: false)))
    }

    @Test("an implausible target reading is rejected however large the margin")
    func absoluteFloor() {
        // otherScore of -200 over 6 characters is far below the per-character floor.
        #expect(!scorer.shouldConvert(scores(strokes: 6, margin: 100, otherScore: -200)))
    }

    /// Lookback drops the length grading and the threshold, but keeps the
    /// known-word requirement as its safety anchor.
    @Test("lookback relaxes length grading but still demands a real word")
    func lookbackRelaxation() {
        var relaxed = scorer
        relaxed.config = scorer.config.relaxedForLookback()
        #expect(relaxed.shouldConvert(scores(strokes: 2, margin: 1)))
        #expect(!relaxed.shouldConvert(scores(strokes: 2, margin: 100, known: false)))
    }
}

// MARK: - Orthographic structure rules

@Suite("Word structure")
struct WordNormalizerTests {

    @Test("a final-form letter out of place is flagged", arguments: [
        ("יקךךם", true),    // "hello" typed on a Hebrew layout
        ("שלום", false),
        ("ילדים", false),
        ("םם", true),
        ("ם", false),       // a single final form is still word-final
    ])
    func misplacedFinalForms(word: String, expected: Bool) {
        #expect(WordNormalizer.hasMisplacedFinalForm(word) == expected)
    }

    @Test("Hebrew normalisation strips niqqud and rejects foreign characters")
    func hebrewNormalisation() {
        #expect(WordNormalizer.hebrew("שָׁלוֹם") == "שלום")
        #expect(WordNormalizer.hebrew("שלום/") == nil)
        #expect(WordNormalizer.hebrew("hello") == nil)
    }

    @Test("Latin normalisation lowercases, keeps apostrophes, trims edges")
    func latinNormalisation() {
        #expect(WordNormalizer.latin("Hello") == "hello")
        #expect(WordNormalizer.latin("don't") == "don't")
        #expect(WordNormalizer.latin("'quoted'") == "quoted")
        #expect(WordNormalizer.latin("שלום") == nil)
    }

    @Test("vowelless Latin tokens are detected", arguments: [
        ("hello", false), ("rhythm", false), ("bcdfg", true), ("shh", true),
    ])
    func vowels(word: String, expected: Bool) {
        #expect(WordNormalizer.hasNoVowel(word) == expected)
    }
}

// MARK: - Lexicon serialisation

@Suite("Lexicon format")
struct LexiconFormatTests {

    @Test("encode/decode round-trips exactly")
    func roundTrip() throws {
        let lexicon = Lexicon(
            latin: .init(unigrams: ["hello": -5.5, "world": -6.25],
                         ngram: CharNGram(unigrams: ["h": 3], bigrams: ["he": 2],
                                          trigrams: ["hel": 1])),
            hebrew: .init(unigrams: ["שלום": -4.125],
                          ngram: CharNGram(unigrams: ["ש": 7], bigrams: ["של": 5],
                                           trigrams: ["שלו": 4])),
            unigramWeight: 0.75)

        let decoded = try LexiconFormat.decode(LexiconFormat.encode(lexicon))
        #expect(decoded.latin.unigrams == lexicon.latin.unigrams)
        #expect(decoded.hebrew.unigrams == lexicon.hebrew.unigrams)
        #expect(decoded.latin.ngram.trigrams == lexicon.latin.ngram.trigrams)
        #expect(decoded.hebrew.ngram.bigrams == lexicon.hebrew.ngram.bigrams)
        #expect(decoded.unigramWeight == 0.75)
    }

    @Test("encoding is byte-stable, so builds are reproducible")
    func deterministic() {
        let lexicon = Lexicon(
            latin: .init(unigrams: ["a": -1, "b": -2, "c": -3],
                         ngram: CharNGram(unigrams: ["a": 1], bigrams: [:], trigrams: [:])),
            hebrew: .init(unigrams: ["ש": -1],
                          ngram: CharNGram(unigrams: [:], bigrams: [:], trigrams: [:])))
        #expect(LexiconFormat.encode(lexicon) == LexiconFormat.encode(lexicon))
    }

    @Test("garbage is rejected rather than misread")
    func rejectsGarbage() {
        #expect(throws: (any Error).self) {
            try LexiconFormat.decode(Data([0, 1, 2, 3, 4, 5, 6, 7]))
        }
    }
}

// MARK: - End-to-end against the real baked lexicon

/// Needs `make lexicon` to have run. Skipped otherwise so a fresh checkout
/// still has a green suite.
enum BakedLexicon {
    static let url = LexiconFormat.defaultURL()
    static let available = url != nil
    static let shared: Lexicon? = url.flatMap { try? LexiconFormat.load(from: $0) }
}

@Suite("Real-lexicon behaviour", .enabled(if: BakedLexicon.available))
struct ScorerIntegrationTests {

    func makeScorer() throws -> Scorer {
        guard let lexicon = BakedLexicon.shared else {
            throw LexiconFormat.Error.badMagic
        }
        return Scorer(lexicon: lexicon)
    }

    /// The whole point of the app.
    @Test("the original request converts, word by word", arguments: [
        ("akuo", "שלום"),
        ("kfo", "לכם"),
        ("hksho", "ילדים"),
        ("uhksu,", "וילדות"),
    ])
    func originalRequest(typed: String, expected: String) throws {
        let scorer = try makeScorer()
        let detail = scorer.evaluate(strokes: Fixture.strokes(typed),
                                     pair: Fixture.pair, activeScript: .latin)
        #expect(detail.verdict == .convert(to: .hebrew, text: expected),
                "\(typed): margin \(detail.margin), he \(detail.hebrewScore), en \(detail.latinScore)")
    }

    @Test("English typed on a Hebrew layout is corrected back", arguments: [
        "hello", "everyone", "meeting", "tomorrow", "please", "review",
    ])
    func englishRecovered(word: String) throws {
        let scorer = try makeScorer()
        let detail = scorer.evaluate(strokes: Fixture.strokes(word),
                                     pair: Fixture.pair, activeScript: .hebrew)
        #expect(detail.verdict == .convert(to: .latin, text: word),
                "\(word): margin \(detail.margin)")
    }

    /// The safety direction: correct text must survive untouched.
    @Test("correctly typed English is left alone", arguments: [
        "hello", "the", "meeting", "tomorrow", "everyone", "because", "system",
        "please", "review", "request", "thanks", "morning", "about", "would",
    ])
    func correctEnglishUntouched(word: String) throws {
        let scorer = try makeScorer()
        let detail = scorer.evaluate(strokes: Fixture.strokes(word),
                                     pair: Fixture.pair, activeScript: .latin)
        #expect(detail.verdict == .keep, "\(word) was converted: margin \(detail.margin)")
    }

    @Test("correctly typed Hebrew is left alone", arguments: [
        "שלום", "ילדים", "תודה", "בוקר", "אנחנו", "בבקשה", "מחשב", "עבודה",
    ])
    func correctHebrewUntouched(word: String) throws {
        let scorer = try makeScorer()
        // Strokes that produce this word under the Hebrew layout.
        let strokes = word.compactMap { ch -> KeyStroke? in
            guard let kc = Fixture.pair.hebrew.keycodeForChar[String(ch)] else { return nil }
            return KeyStroke(keycode: kc)
        }
        let detail = scorer.evaluate(strokes: strokes, pair: Fixture.pair, activeScript: .hebrew)
        #expect(detail.verdict == .keep, "\(word) was converted: margin \(detail.margin)")
    }

    @Test("single characters are never converted")
    func singleCharactersSafe() throws {
        let scorer = try makeScorer()
        for typed in ["a", "i", "o", "t"] {
            let detail = scorer.evaluate(strokes: Fixture.strokes(typed),
                                         pair: Fixture.pair, activeScript: .latin)
            #expect(detail.verdict == .keep, "\(typed) was converted")
        }
    }
}
