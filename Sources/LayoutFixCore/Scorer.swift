import Foundation

/// Tunable knobs for the decision rule.
///
/// Defaults are the values chosen by `LayoutFixEval`; see README for the
/// measured false-positive / recall tradeoff behind them.
public struct ScorerConfig: Sendable, Codable, Equatable {
    /// Base log-likelihood-ratio margin, in nats, required before we touch text.
    public var threshold: Double = 6.0

    /// Evidence scales with token length: a five-letter coincidence is
    /// overwhelming, a two-letter one is noise. Rather than a hard minimum
    /// length (which would gut recall, since common Hebrew words are short),
    /// short tokens must clear a proportionally larger margin.
    public var reliableLength: Int = 5
    public var shortTokenPenalty: Double = 4.5

    /// Tokens shorter than this are never converted.
    public var minTokenLength: Int = 2

    /// The winning reading must be at least this plausible per character
    /// (times length + 2, for the word boundaries). Length-relative so long
    /// words are not rejected merely for being long.
    public var absoluteFloorPerChar: Double = -6.5

    /// Require the converted reading to be a real word in the target language.
    public var requireKnownWord: Bool = true
    /// ...unless the margin is this overwhelming, which lets long inflections
    /// and proper nouns outside the 50k vocabulary still be corrected.
    public var knownWordExemptMargin: Double = 30.0

    /// Penalty for a reading that is not well-formed in its script at all
    /// (e.g. a "Hebrew" reading containing slashes or commas).
    public var foreignCharPenalty: Double = 12.0
    /// A final-form letter in non-final position is orthographically
    /// impossible in Hebrew -- the strongest single signal available.
    public var misplacedFinalFormPenalty: Double = 20.0
    /// A vowelless Latin token of length >= 3 is essentially not English.
    public var noVowelPenalty: Double = 7.0
    /// Bonus for the script the user has most recently been writing in.
    public var stickyBonus: Double = 2.0

    // MARK: Lookback
    //
    // Once a later token has proved the run was typed in the wrong layout, the
    // words already on screen are no longer being judged in isolation: the
    // context is established, so they get a much more permissive rule. This is
    // safe because a manual input-source change resets the buffer, so a
    // lookback run can never span a language the user switched into on purpose.
    //
    // Membership in the target vocabulary stays mandatory here -- it is the one
    // anchor that stops a relaxed threshold from inventing words.
    public var lookbackThreshold: Double = 0.0
    public var lookbackShortTokenPenalty: Double = 0.0
    public var lookbackMinLength: Int = 1

    public init() {}

    /// The relaxed configuration used when re-examining already-typed tokens.
    public func relaxedForLookback() -> ScorerConfig {
        var c = self
        c.threshold = lookbackThreshold
        c.shortTokenPenalty = lookbackShortTokenPenalty
        c.minTokenLength = lookbackMinLength
        c.requireKnownWord = true
        c.knownWordExemptMargin = .infinity
        return c
    }

    /// Margin required for a token of this length.
    public func requiredMargin(strokeCount: Int) -> Double {
        threshold + shortTokenPenalty * Double(max(0, reliableLength - strokeCount))
    }
}

/// What the scorer decided about one token.
public enum Verdict: Equatable, Sendable {
    case keep
    case convert(to: Script, text: String)

    public var isConvert: Bool {
        if case .convert = self { return true }
        return false
    }
}

/// Everything the decision rule needs, separated from how it was computed.
///
/// Exists so the calibration harness can cache scores once and replay the rule
/// under many configurations, using the *same* code path as the live app. If
/// the harness reimplemented the rule, its numbers would eventually be lies.
public struct ReadingScores: Sendable {
    public let strokeCount: Int
    public let currentScore: Double
    public let otherScore: Double
    /// The converted reading is spellable in the target script.
    public let otherNormalizable: Bool
    /// The converted reading is in the target vocabulary (allowing for Hebrew
    /// particles).
    public let otherKnown: Bool
    /// Character count of the converted reading, for the length-relative floor.
    public let otherLength: Int

    public var margin: Double { otherScore - currentScore }

    public init(strokeCount: Int, currentScore: Double, otherScore: Double,
                otherNormalizable: Bool, otherKnown: Bool, otherLength: Int) {
        self.strokeCount = strokeCount
        self.currentScore = currentScore
        self.otherScore = otherScore
        self.otherNormalizable = otherNormalizable
        self.otherKnown = otherKnown
        self.otherLength = otherLength
    }
}

/// Full working for one token, for debugging and the calibration report.
public struct ScoreDetail: Sendable {
    public let latinReading: String
    public let hebrewReading: String
    public let latinScore: Double
    public let hebrewScore: Double
    public let activeScript: Script
    public let scores: ReadingScores
    public let verdict: Verdict

    public var margin: Double { scores.margin }
}

/// Decides whether a token was typed under the wrong keyboard layout.
///
/// The comparison is a log-likelihood ratio between two readings of the *same
/// keystrokes*. Both readings come from an identical number of key presses, so
/// their lengths match and the ratio is a fair comparison rather than a
/// length artefact.
public struct Scorer: Sendable {
    public let lexicon: Lexicon
    public var config: ScorerConfig

    public init(lexicon: Lexicon, config: ScorerConfig = ScorerConfig()) {
        self.lexicon = lexicon
        self.config = config
    }

    // MARK: - The decision rule (single source of truth)

    public func shouldConvert(_ s: ReadingScores) -> Bool {
        guard s.strokeCount >= config.minTokenLength else { return false }
        guard s.otherNormalizable else { return false }
        guard s.margin > config.requiredMargin(strokeCount: s.strokeCount) else { return false }
        guard s.otherScore > config.absoluteFloorPerChar * Double(s.otherLength + 2) else { return false }
        if config.requireKnownWord && !s.otherKnown
            && s.margin < config.knownWordExemptMargin { return false }
        return true
    }

    // MARK: - Scoring

    /// Plausibility of reading `text` as a word of `script`, in nats.
    public func scoreReading(_ text: String, script: Script) -> Double {
        guard !text.isEmpty else { return -Double.infinity }

        guard let normalized = WordNormalizer.normalize(text, script: script),
              !normalized.isEmpty else {
            // Not even spellable in this script. Score the shape alone and
            // penalise, rather than returning -infinity, so the margin stays a
            // finite comparable number.
            return lexicon.model(for: script).ngram.logProb(text) - config.foreignCharPenalty
        }

        var score = lexicon.score(normalized, script: script)

        // Characters had to be dropped to make it spellable, i.e. it contained
        // punctuation foreign to this script.
        if normalized.count != text.count {
            score -= config.foreignCharPenalty
        }

        switch script {
        case .hebrew:
            if WordNormalizer.hasMisplacedFinalForm(normalized) {
                score -= config.misplacedFinalFormPenalty
            }
        case .latin:
            if normalized.count >= 3 && WordNormalizer.hasNoVowel(normalized) {
                score -= config.noVowelPenalty
            }
        }
        return score
    }

    /// Build the decision inputs for one token without applying the rule.
    /// Used by both `evaluate` and the calibration harness.
    public func scores(strokes: [KeyStroke],
                       pair: LayoutPair,
                       activeScript: Script,
                       sticky: Script? = nil) -> (detailInputs: (String, String, Double, Double),
                                                  scores: ReadingScores) {
        let latinReading = pair.reading(strokes, as: .latin)
        let hebrewReading = pair.reading(strokes, as: .hebrew)

        var latinScore = scoreReading(latinReading, script: .latin)
        var hebrewScore = scoreReading(hebrewReading, script: .hebrew)

        if let sticky {
            if sticky == .latin { latinScore += config.stickyBonus }
            else { hebrewScore += config.stickyBonus }
        }

        let other = activeScript.other
        let otherReading = other == .latin ? latinReading : hebrewReading
        let normalizedOther = WordNormalizer.normalize(otherReading, script: other)

        let readingScores = ReadingScores(
            strokeCount: strokes.count,
            currentScore: activeScript == .latin ? latinScore : hebrewScore,
            otherScore: other == .latin ? latinScore : hebrewScore,
            otherNormalizable: !(normalizedOther?.isEmpty ?? true),
            otherKnown: normalizedOther.map { isKnown($0, script: other) } ?? false,
            otherLength: normalizedOther?.count ?? otherReading.count)

        return ((latinReading, hebrewReading, latinScore, hebrewScore), readingScores)
    }

    /// Evaluate one token end to end.
    ///
    /// - Parameters:
    ///   - strokes: the physical keys pressed, in order.
    ///   - activeScript: the script of the input source that was live.
    ///   - sticky: the script the user was most recently judged to be writing
    ///     in, if any. Carries context across a multi-word run.
    public func evaluate(strokes: [KeyStroke],
                         pair: LayoutPair,
                         activeScript: Script,
                         sticky: Script? = nil) -> ScoreDetail {
        let (inputs, readingScores) = scores(strokes: strokes, pair: pair,
                                            activeScript: activeScript, sticky: sticky)
        let (latinReading, hebrewReading, latinScore, hebrewScore) = inputs
        let other = activeScript.other
        let otherReading = other == .latin ? latinReading : hebrewReading

        let verdict: Verdict = shouldConvert(readingScores)
            ? .convert(to: other, text: otherReading)
            : .keep

        return ScoreDetail(latinReading: latinReading,
                           hebrewReading: hebrewReading,
                           latinScore: latinScore,
                           hebrewScore: hebrewScore,
                           activeScript: activeScript,
                           scores: readingScores,
                           verdict: verdict)
    }

    /// Vocabulary membership, allowing for Hebrew's attached particles.
    public func isKnown(_ word: String, script: Script) -> Bool {
        if lexicon.isKnownWord(word, script: script) { return true }
        guard script == .hebrew else { return false }
        let particles: Set<Character> = ["ו", "ה", "ב", "ל", "כ", "מ", "ש"]
        var stem = Substring(word)
        var stripped = 0
        while stripped < 2, let first = stem.first, particles.contains(first), stem.count > 2 {
            stem = stem.dropFirst()
            stripped += 1
            if lexicon.isKnownWord(String(stem), script: .hebrew) { return true }
        }
        return false
    }
}
