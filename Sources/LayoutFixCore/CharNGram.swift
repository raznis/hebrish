import Foundation

/// Character trigram model with stupid-backoff, used to score words the
/// unigram lexicon has never seen (inflections, names, typos).
///
/// Scores are *total* log-probabilities of the whole character sequence, which
/// puts them on the same scale as a unigram word log-probability — so the two
/// can be mixed and, more importantly, compared across languages.
public struct CharNGram: Sendable {
    /// Sentinel padded onto both ends of a word so the model learns which
    /// characters start and end words. Chosen outside both alphabets.
    public static let boundary: Character = "\u{0001}"

    public let unigrams: [String: UInt32]
    public let bigrams: [String: UInt32]
    public let trigrams: [String: UInt32]
    public let totalUnigrams: UInt32
    /// Distinct characters observed, for add-k smoothing.
    public let alphabetSize: Int

    /// Add-k smoothing constant.
    private let k: Double = 0.5
    /// Stupid-backoff discount, applied once per level dropped.
    private let backoffPenalty: Double = 0.4

    public init(unigrams: [String: UInt32], bigrams: [String: UInt32], trigrams: [String: UInt32]) {
        self.unigrams = unigrams
        self.bigrams = bigrams
        self.trigrams = trigrams
        self.totalUnigrams = unigrams.values.reduce(0, &+)
        self.alphabetSize = max(1, unigrams.count)
    }

    /// Pad a word with boundary sentinels: `\x01\x01word\x01`.
    public static func padded(_ word: String) -> [Character] {
        [boundary, boundary] + Array(word) + [boundary]
    }

    /// Total log P(word) under the character model. Natural log.
    public func logProb(_ word: String) -> Double {
        guard !word.isEmpty else { return -Double.infinity }
        let chars = CharNGram.padded(word)
        var total = 0.0
        // Predict every position after the two-character pad.
        for i in 2..<chars.count {
            total += logConditional(c1: chars[i - 2], c2: chars[i - 1], c3: chars[i])
        }
        return total
    }

    /// log P(c3 | c1 c2) with backoff to bigram, then unigram.
    private func logConditional(c1: Character, c2: Character, c3: Character) -> Double {
        let tri = String([c1, c2, c3])
        let context2 = String([c1, c2])
        if let triCount = trigrams[tri], let ctxCount = bigrams[context2], ctxCount > 0 {
            return log((Double(triCount) + k) / (Double(ctxCount) + k * Double(alphabetSize)))
        }
        let bi = String([c2, c3])
        let context1 = String(c2)
        if let biCount = bigrams[bi], let ctxCount = unigrams[context1], ctxCount > 0 {
            return log(backoffPenalty) + log((Double(biCount) + k) / (Double(ctxCount) + k * Double(alphabetSize)))
        }
        let uniCount = Double(unigrams[String(c3)] ?? 0)
        let denominator = Double(totalUnigrams) + k * Double(alphabetSize)
        return 2 * log(backoffPenalty) + log((uniCount + k) / denominator)
    }
}

/// Accumulates trigram statistics while baking the lexicon.
public struct CharNGramBuilder {
    private var unigrams: [String: UInt32] = [:]
    private var bigrams: [String: UInt32] = [:]
    private var trigrams: [String: UInt32] = [:]

    public init() {}

    /// Add a word, weighted by how often it occurs. Weighting by corpus
    /// frequency (rather than counting each vocabulary entry once) makes the
    /// model reflect real text rather than the shape of a word list.
    public mutating func add(_ word: String, weight: UInt32) {
        guard !word.isEmpty, weight > 0 else { return }
        let chars = CharNGram.padded(word)
        for i in 0..<chars.count {
            unigrams[String(chars[i]), default: 0] &+= weight
            if i >= 1 { bigrams[String([chars[i - 1], chars[i]]), default: 0] &+= weight }
            if i >= 2 { trigrams[String([chars[i - 2], chars[i - 1], chars[i]]), default: 0] &+= weight }
        }
    }

    public func build() -> CharNGram {
        CharNGram(unigrams: unigrams, bigrams: bigrams, trigrams: trigrams)
    }
}
