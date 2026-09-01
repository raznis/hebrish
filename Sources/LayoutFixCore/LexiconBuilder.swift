import Foundation

/// Builds a `Lexicon` from raw frequency lists.
///
/// Lives in Core rather than in the bake tool because the calibration harness
/// needs to build *held-out* lexicons (vocabulary minus a slice) to measure how
/// the character-model fallback behaves on words the lexicon has never seen.
public struct LexiconBuilder {

    /// Character-model training weight budget.
    ///
    /// Raw corpus counts reach tens of millions and every word feeds several
    /// n-gram buckets, which would overflow the UInt32 counters. Scaling all
    /// weights by one constant preserves every ratio between them.
    public static let ngramWeightBudget: Double = 2_000_000

    public struct Inputs {
        public var latinCounts: [String: UInt64]
        public var hebrewCounts: [String: UInt64]
        /// Membership-only English vocabulary (typically /usr/share/dict/words).
        public var latinFloorWords: [String]

        public init(latinCounts: [String: UInt64],
                    hebrewCounts: [String: UInt64],
                    latinFloorWords: [String] = []) {
            self.latinCounts = latinCounts
            self.hebrewCounts = hebrewCounts
            self.latinFloorWords = latinFloorWords
        }
    }

    public struct Stats {
        public var latinCorpusWords = 0
        public var latinFloorWords = 0
        public var hebrewCorpusWords = 0
        public var latinTotal: UInt64 = 0
        public var hebrewTotal: UInt64 = 0
        public var floorLogProb = 0.0
    }

    // MARK: - Parsing

    /// Parse a "word count" frequency list, normalising and aggregating.
    /// Normalisation can merge distinct raw entries (niqqud variants, casing),
    /// so counts are summed rather than overwritten.
    public static func readFrequencyList(
        path: String, script: Script, maxWordLength: Int = 30
    ) throws -> (counts: [String: UInt64], rejected: Int) {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var counts: [String: UInt64] = [:]
        var rejected = 0
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            let parts = line.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: true)
            guard parts.count == 2,
                  let count = UInt64(parts[1].trimmingCharacters(in: .whitespaces)) else {
                rejected += 1
                continue
            }
            guard let word = WordNormalizer.normalize(String(parts[0]), script: script),
                  word.count <= maxWordLength else {
                rejected += 1
                continue
            }
            counts[word, default: 0] += count
        }
        return (counts, rejected)
    }

    /// Parse a plain one-word-per-line list (e.g. /usr/share/dict/words).
    public static func readWordList(
        path: String, script: Script = .latin, maxWordLength: Int = 30
    ) throws -> [String] {
        let text = try String(contentsOfFile: path, encoding: .utf8)
        var out: [String] = []
        out.reserveCapacity(250_000)
        for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let word = WordNormalizer.normalize(String(line), script: script),
                  word.count <= maxWordLength else { continue }
            out.append(word)
        }
        return out
    }

    // MARK: - Building

    /// - Parameter exclude: words to withhold from the vocabulary *and* from
    ///   character-model training, per script. Used only by the calibration
    ///   harness to simulate out-of-vocabulary input.
    public static func build(
        _ inputs: Inputs,
        exclude: [Script: Set<String>] = [:],
        unigramWeight: Double = 0.85
    ) -> (lexicon: Lexicon, stats: Stats) {
        var stats = Stats()

        let excludedLatin = exclude[.latin] ?? []
        let excludedHebrew = exclude[.hebrew] ?? []

        let latinCounts = inputs.latinCounts.filter { !excludedLatin.contains($0.key) }
        let hebrewCounts = inputs.hebrewCounts.filter { !excludedHebrew.contains($0.key) }

        // Character models see only corpus words, weighted by real frequency.
        //
        // The floor vocabulary is deliberately excluded: 200k+ archaic
        // dictionary headwords would drag the spelling model away from the
        // language people actually type.
        let latinNGram = buildNGram(latinCounts)
        let hebrewNGram = buildNGram(hebrewCounts)

        var latinUnigrams = logProbs(latinCounts)
        let hebrewUnigrams = logProbs(hebrewCounts)

        stats.latinCorpusWords = latinUnigrams.count
        stats.hebrewCorpusWords = hebrewUnigrams.count
        stats.latinTotal = latinCounts.values.reduce(0, +)
        stats.hebrewTotal = hebrewCounts.values.reduce(0, +)

        // Rare, technical and proper-noun English that a 50k subtitle list
        // misses. These are exactly the words we must never mangle, so they
        // enter the vocabulary at a floor probability: "as if seen half a time".
        if !inputs.latinFloorWords.isEmpty {
            let floor = log(0.5 / Double(max(stats.latinTotal, 1)))
            stats.floorLogProb = floor
            for word in inputs.latinFloorWords where !excludedLatin.contains(word) {
                if latinUnigrams[word] == nil {
                    latinUnigrams[word] = floor
                    stats.latinFloorWords += 1
                }
            }
        }

        let lexicon = Lexicon(
            latin: Lexicon.Model(unigrams: latinUnigrams, ngram: latinNGram),
            hebrew: Lexicon.Model(unigrams: hebrewUnigrams, ngram: hebrewNGram),
            unigramWeight: unigramWeight)
        return (lexicon, stats)
    }

    static func buildNGram(_ counts: [String: UInt64]) -> CharNGram {
        let total = counts.values.reduce(UInt64(0), +)
        let divisor = max(1.0, Double(total) / ngramWeightBudget)
        var builder = CharNGramBuilder()
        for (word, count) in counts {
            let weight = UInt32(max(1.0, (Double(count) / divisor).rounded()))
            builder.add(word, weight: weight)
        }
        return builder.build()
    }

    static func logProbs(_ counts: [String: UInt64]) -> [String: Double] {
        let total = counts.values.reduce(UInt64(0), +)
        guard total > 0 else { return [:] }
        let denominator = Double(total)
        var out = [String: Double](minimumCapacity: counts.count)
        for (word, count) in counts {
            out[word] = log(Double(count) / denominator)
        }
        return out
    }
}
