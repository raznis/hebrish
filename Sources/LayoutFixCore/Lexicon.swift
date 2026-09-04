import Foundation

/// Per-language word statistics plus a character model, for both scripts.
public struct Lexicon: Sendable {

    public struct Model: Sendable {
        /// Natural-log unigram probability per word.
        public let unigrams: [String: Double]
        public let ngram: CharNGram

        public init(unigrams: [String: Double], ngram: CharNGram) {
            self.unigrams = unigrams
            self.ngram = ngram
        }
    }

    public let latin: Model
    public let hebrew: Model

    /// Weight on the unigram component of the mixture; the remainder goes to
    /// the character model.
    public let unigramWeight: Double

    public init(latin: Model, hebrew: Model, unigramWeight: Double = 0.85) {
        self.latin = latin
        self.hebrew = hebrew
        self.unigramWeight = unigramWeight
    }

    public func model(for script: Script) -> Model {
        script == .latin ? latin : hebrew
    }

    /// Whether the word appears in the language's vocabulary at all.
    public func isKnownWord(_ word: String, script: Script) -> Bool {
        model(for: script).unigrams[word] != nil
    }

    public func unigramLogProb(_ word: String, script: Script) -> Double? {
        model(for: script).unigrams[word]
    }

    /// Total log P(word) under this language: a mixture of the unigram lexicon
    /// and the character model.
    ///
    /// Mixing rather than falling back means a known word still benefits from a
    /// plausible spelling, and an unknown-but-well-formed word is not written
    /// off entirely. Both components are total log-probabilities of the same
    /// string, so they are on the same scale.
    public func logProb(_ word: String, script: Script) -> Double {
        guard !word.isEmpty else { return -Double.infinity }
        let m = model(for: script)
        let ngramLog = m.ngram.logProb(word)
        guard let uniLog = m.unigrams[word] else {
            return log(1 - unigramWeight) + ngramLog
        }
        return logSumExp(log(unigramWeight) + uniLog,
                         log(1 - unigramWeight) + ngramLog)
    }

    /// Hebrew is heavily prefixed (ו/ה/ב/ל/כ/מ/ש conjunctions and prepositions
    /// attach directly to the word). A 50k vocabulary misses many inflected
    /// forms, so retry the lookup after peeling one or two leading particles.
    /// Returns the log-probability of the best analysis found, discounted for
    /// each particle removed.
    public func logProbWithHebrewMorphology(_ word: String) -> Double {
        var best = logProb(word, script: .hebrew)
        guard word.count >= 3 else { return best }

        let particles: Set<Character> = ["ו", "ה", "ב", "ל", "כ", "מ", "ש"]
        // Cost of positing a particle, in nats. Keeps a real word ahead of a
        // strip-until-it-matches analysis.
        let particleCost = 2.5

        var stem = Substring(word)
        var stripped = 0
        while stripped < 2, let first = stem.first, particles.contains(first), stem.count > 2 {
            stem = stem.dropFirst()
            stripped += 1
            if let uni = model(for: .hebrew).unigrams[String(stem)] {
                let candidate = logSumExp(log(unigramWeight) + uni,
                                          log(1 - unigramWeight) + model(for: .hebrew).ngram.logProb(String(stem)))
                    - particleCost * Double(stripped)
                best = max(best, candidate)
            }
        }
        return best
    }

    /// English clitics, in the form the *baked lexicon* holds them.
    ///
    /// The frequency list tokenises contractions apart -- it holds `'m`, `'re`
    /// and `'t` with real counts but never `i'm`, `you're` or `don't`, and
    /// /usr/share/dict/words has no apostrophes at all. So every contraction is
    /// out of vocabulary, `requireKnownWord` refuses it, and the correction
    /// never fires. (The corpus even has `don` at 4.1M, which is `don't`
    /// counted as two tokens.)
    ///
    /// Stored without their apostrophes, because `WordNormalizer.latin` trims
    /// apostrophes from the edges of a word before baking -- reasonable for
    /// quoted text, and it means the corpus entry `'re` is filed under `re`.
    /// This set is therefore what makes the analysis precise: membership in it,
    /// not the shape of the string, is what distinguishes a clitic from any
    /// other short suffix.
    public static let latinClitics: Set<String> = ["s", "t", "m", "re", "ll", "ve", "d"]

    /// Score a Latin word, allowing for a contraction split at the apostrophe.
    ///
    /// Deliberately analytic rather than a hardcoded list of contractions: it
    /// costs no new data and extends to possessives and names the 50k
    /// vocabulary will never contain -- `Sarah's`, `Dave'd`.
    public func logProbWithLatinClitics(_ word: String) -> Double {
        let best = logProb(word, script: .latin)
        guard let apostrophe = word.firstIndex(of: "'") else { return best }

        let base = String(word[word.startIndex..<apostrophe])
        let clitic = String(word[word.index(after: apostrophe)...])
        guard base.count >= 1, Lexicon.latinClitics.contains(clitic),
              let cliticProb = latin.unigrams[clitic] else { return best }

        // Cost of positing a contraction, so a real single word stays ahead of
        // a split analysis of the same characters.
        let joinCost = 1.0
        return max(best, logProb(base, script: .latin) + cliticProb - joinCost)
    }

    /// Script-aware entry point used by the scorer.
    public func score(_ word: String, script: Script) -> Double {
        script == .hebrew ? logProbWithHebrewMorphology(word)
                          : logProbWithLatinClitics(word)
    }
}

@inline(__always)
func logSumExp(_ a: Double, _ b: Double) -> Double {
    if a == -Double.infinity { return b }
    if b == -Double.infinity { return a }
    let hi = max(a, b), lo = min(a, b)
    return hi + log1p(exp(lo - hi))
}
