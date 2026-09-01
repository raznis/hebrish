import Foundation
import LayoutFixCore

let usage = """
usage: LayoutFixEval --en <en_50k.txt> --he <he_50k.txt> [options]

  --sys-words <path>   English membership floor list (default /usr/share/dict/words)
  --top-n <N>          evaluate the N most frequent words per language (default 20000)
  --holdout <frac>     also report on words withheld from the lexicon (default 0.2)
  --seed <n>           PRNG seed for the holdout split (default 42)
  --threshold <nats>   report detail at this threshold instead of auto-picking
  --target-fpr <frac>  weighted false-positive budget (default 0.000005)
  --target-fpr-unw <f> unweighted false-positive budget (default 0.0001)
  --no-known-word      do not require the converted reading to be a known word
  --min-length <n>     minimum token length to convert (default 2)

Fires a synthetic "typed in the wrong layout" corpus through the scorer and
reports precision/recall as a function of the decision threshold.
"""

let args = CLIArgs()
if args.flag("help") { print(usage); exit(0) }

let enPath = args.require("en", usage: usage)
let hePath = args.require("he", usage: usage)
let sysWordsPath = args.string("sys-words") ?? "/usr/share/dict/words"
let topN = args.int("top-n") ?? 20_000
let holdoutFraction = args.double("holdout") ?? 0.2
let seed = UInt64(args.int("seed") ?? 42)
let targetFPR = args.double("target-fpr") ?? 0.000005
let targetFPRUnweighted = args.double("target-fpr-unw") ?? 0.0001

func note(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

// MARK: - Deterministic PRNG, so a reported number can be reproduced.

struct SplitMix64: RandomNumberGenerator {
    private var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state = state &+ 0x9E3779B97F4A7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58476D1CE4E5B9
        z = (z ^ (z >> 27)) &* 0x94D049BB133111EB
        return z ^ (z >> 31)
    }
}

// MARK: - Inputs

note("reading frequency lists")
let (enCounts, _) = try LexiconBuilder.readFrequencyList(path: enPath, script: .latin)
let (heCounts, _) = try LexiconBuilder.readFrequencyList(path: hePath, script: .hebrew)
let floorWords = (try? LexiconBuilder.readWordList(path: sysWordsPath)) ?? []
note("  latin \(enCounts.count), hebrew \(heCounts.count), floor \(floorWords.count)")

let inputs = LexiconBuilder.Inputs(latinCounts: enCounts, hebrewCounts: heCounts,
                                   latinFloorWords: floorWords)

let layouts: SystemLayouts
do {
    layouts = try SystemLayouts.discover()
} catch {
    note("error: \(error)")
    exit(1)
}
let pair = layouts.pair
note("layouts: \(pair.latin.sourceID) / \(pair.hebrew.sourceID)")

// MARK: - Case construction

/// One synthetic typing event: `word` was intended in `intended`, but the live
/// input source was `active`. When they differ the scorer should fire.
struct Case {
    let word: String
    let count: UInt64
    let intended: Script
    let active: Script
    let scores: ReadingScores
    let otherReading: String

    var isPositive: Bool { intended != active }
    var strokeCount: Int { scores.strokeCount }
    var margin: Double { scores.margin }
    /// Did the conversion actually recover the intended word?
    var recovers: Bool { otherReading == word }
}

/// The physical keys that would produce `word` under `script`.
func strokes(for word: String, script: Script) -> [KeyStroke]? {
    let table = pair.table(for: script)
    var out: [KeyStroke] = []
    out.reserveCapacity(word.count)
    for ch in word {
        guard let kc = table.keycodeForChar[String(ch)] else { return nil }
        out.append(KeyStroke(keycode: kc, shift: false))
    }
    return out
}

func topWords(_ counts: [String: UInt64], _ n: Int) -> [(String, UInt64)] {
    counts.sorted { lhs, rhs in
        lhs.value != rhs.value ? lhs.value > rhs.value : lhs.key < rhs.key
    }.prefix(n).map { ($0.key, $0.value) }
}

/// Build all four case groups. Scores come from `Scorer.scores`, the same
/// entry point the live app uses, so the harness cannot drift from runtime.
func buildCases(scorer: Scorer,
                latinWords: [(String, UInt64)],
                hebrewWords: [(String, UInt64)]) -> [Case] {
    var cases: [Case] = []
    cases.reserveCapacity((latinWords.count + hebrewWords.count) * 2)

    func add(word: String, count: UInt64, intended: Script, strokes: [KeyStroke]) {
        for active in Script.allCases {
            let (inputs, rs) = scorer.scores(strokes: strokes, pair: pair, activeScript: active)
            let (latinReading, hebrewReading, _, _) = inputs
            let otherReading = active.other == .latin ? latinReading : hebrewReading
            cases.append(Case(word: word, count: count, intended: intended,
                              active: active, scores: rs, otherReading: otherReading))
        }
    }

    for (word, count) in latinWords {
        guard let s = strokes(for: word, script: .latin) else { continue }
        add(word: word, count: count, intended: .latin, strokes: s)
    }
    for (word, count) in hebrewWords {
        guard let s = strokes(for: word, script: .hebrew) else { continue }
        add(word: word, count: count, intended: .hebrew, strokes: s)
    }
    return cases
}

/// Replay the decision at a given threshold, using the scorer's own rule.
func fires(_ c: Case, threshold: Double, scorer: Scorer) -> Bool {
    var s = scorer
    s.config.threshold = threshold
    return s.shouldConvert(c.scores)
}

// MARK: - Metrics

struct Metrics {
    var negatives = 0, falsePositives = 0
    var positives = 0, truePositives = 0, mangled = 0
    var negativeWeight: Double = 0, falsePositiveWeight: Double = 0
    var positiveWeight: Double = 0, truePositiveWeight: Double = 0

    var fpr: Double { negatives == 0 ? 0 : Double(falsePositives) / Double(negatives) }
    var recall: Double { positives == 0 ? 0 : Double(truePositives) / Double(positives) }
    var weightedFPR: Double { negativeWeight == 0 ? 0 : falsePositiveWeight / negativeWeight }
    var weightedRecall: Double { positiveWeight == 0 ? 0 : truePositiveWeight / positiveWeight }
}

func measure(_ cases: [Case], threshold: Double, scorer: Scorer,
             filter: (Case) -> Bool = { _ in true }) -> Metrics {
    var m = Metrics()
    for c in cases where filter(c) {
        let w = Double(c.count)
        let fired = fires(c, threshold: threshold, scorer: scorer)
        if c.isPositive {
            m.positives += 1; m.positiveWeight += w
            if fired {
                if c.recovers { m.truePositives += 1; m.truePositiveWeight += w }
                else { m.mangled += 1 }
            }
        } else {
            m.negatives += 1; m.negativeWeight += w
            if fired { m.falsePositives += 1; m.falsePositiveWeight += w }
        }
    }
    return m
}

func pct(_ v: Double) -> String { String(format: "%7.3f%%", v * 100) }

// MARK: - Run

var config = ScorerConfig()
config.requireKnownWord = !args.flag("no-known-word")
config.minTokenLength = args.int("min-length") ?? 2

note("building full lexicon")
let (fullLexicon, stats) = LexiconBuilder.build(inputs)
note("  latin \(fullLexicon.latin.unigrams.count) (\(stats.latinFloorWords) floor), "
     + "hebrew \(fullLexicon.hebrew.unigrams.count)")

let fullScorer = Scorer(lexicon: fullLexicon, config: config)
let latinTest = topWords(enCounts, topN)
let hebrewTest = topWords(heCounts, topN)
note("scoring \(latinTest.count + hebrewTest.count) words x 2 directions")
let cases = buildCases(scorer: fullScorer, latinWords: latinTest, hebrewWords: hebrewTest)
note("  \(cases.count) cases\n")

let sweep: [Double] = [0, 2, 4, 6, 8, 10, 12, 14, 16, 18, 20, 24, 28, 32, 40]

print("""
================================================================================
IN-VOCABULARY  (top \(topN)/language, requireKnownWord=\(config.requireKnownWord), \
minLength=\(config.minTokenLength))
--------------------------------------------------------------------------------
  FPR = correct text we would have wrecked.  weighted = by corpus frequency,
  i.e. how often it would bite in real typing.
================================================================================
    tau   FPR(unw)  FPR(wgt)   recall(unw) recall(wgt)  mangled
""")
for tau in sweep {
    let m = measure(cases, threshold: tau, scorer: fullScorer)
    print(String(format: "  %5.1f   %@  %@    %@  %@   %d",
                 tau, pct(m.fpr), pct(m.weightedFPR), pct(m.recall), pct(m.weightedRecall), m.mangled))
}

// Pick the smallest tau (best recall) that meets BOTH false-positive budgets.
//
// Both are needed. Weighted FPR alone bottoms out early -- it is dominated by a
// handful of very frequent words and reads as 0.000% while dozens of rarer
// words are still being wrecked. The unweighted budget is what actually
// separates the candidate thresholds.
var chosen = sweep.last!
for tau in sweep {
    let m = measure(cases, threshold: tau, scorer: fullScorer)
    if m.weightedFPR <= targetFPR && m.fpr <= targetFPRUnweighted {
        chosen = tau
        break
    }
}
if let override = args.double("threshold") { chosen = override }

let m = measure(cases, threshold: chosen, scorer: fullScorer)
print("""

--------------------------------------------------------------------------------
CHOSEN tau = \(chosen)   (budgets: weighted \(pct(targetFPR)), unweighted \(pct(targetFPRUnweighted)))
  weighted FPR    \(pct(m.weightedFPR))     unweighted FPR    \(pct(m.fpr))
  weighted recall \(pct(m.weightedRecall))     unweighted recall \(pct(m.recall))
  false positives \(m.falsePositives)/\(m.negatives)     missed \(m.positives - m.truePositives)/\(m.positives)
--------------------------------------------------------------------------------
""")

// Per-direction, so a good average cannot hide one broken direction.
print("BY DIRECTION at tau = \(chosen)")
let directions: [(String, (Case) -> Bool)] = [
    ("HE typed with EN active  (the headline case)", { $0.intended == .hebrew && $0.active == .latin }),
    ("EN typed with HE active", { $0.intended == .latin && $0.active == .hebrew }),
    ("EN typed with EN active  (must not fire)", { $0.intended == .latin && $0.active == .latin }),
    ("HE typed with HE active  (must not fire)", { $0.intended == .hebrew && $0.active == .hebrew }),
]
for (label, filter) in directions {
    let d = measure(cases, threshold: chosen, scorer: fullScorer, filter: filter)
    if d.positives > 0 {
        print(String(format: "  %-42@ recall %@ (wgt %@)", label, pct(d.recall), pct(d.weightedRecall)))
    } else {
        print(String(format: "  %-42@ FPR    %@ (wgt %@)", label, pct(d.fpr), pct(d.weightedFPR)))
    }
}

// Length breakdown: short tokens are where the false positives live.
print("\nBY TOKEN LENGTH at tau = \(chosen)")
print("   len   count   FPR(unw)  recall(unw)")
for len in 1...8 {
    let f: (Case) -> Bool = { len == 8 ? $0.strokeCount >= 8 : $0.strokeCount == len }
    let d = measure(cases, threshold: chosen, scorer: fullScorer, filter: f)
    guard d.negatives + d.positives > 0 else { continue }
    let label = len == 8 ? "  8+" : String(format: "%4d", len)
    print(String(format: "  %@  %6d   %@  %@",
                 label, d.negatives + d.positives, pct(d.fpr), pct(d.recall)))
}

// The actionable list: which real words would we have wrecked, worst first.
print("\nWORST FALSE POSITIVES at tau = \(chosen)  (most frequent real words we would break)")
let fps = cases
    .filter { !$0.isPositive && fires($0, threshold: chosen, scorer: fullScorer) }
    .sorted { $0.count > $1.count }
    .prefix(20)
if fps.isEmpty {
    print("  none")
} else {
    print("       typed        would become    intended  freq        margin")
    for c in fps {
        print(String(format: "  %12@ -> %-14@  %-8@  %-11d %6.1f",
                     c.word, c.otherReading, c.intended.rawValue, Int(c.count), c.margin))
    }
}

// MARK: - Out-of-vocabulary behaviour

if holdoutFraction > 0 {
    note("\nbuilding holdout lexicon (\(Int(holdoutFraction * 100))% withheld)")
    var rng = SplitMix64(seed: seed)
    var heldLatin = Set<String>(), heldHebrew = Set<String>()
    for (w, _) in latinTest where Double.random(in: 0..<1, using: &rng) < holdoutFraction {
        heldLatin.insert(w)
    }
    for (w, _) in hebrewTest where Double.random(in: 0..<1, using: &rng) < holdoutFraction {
        heldHebrew.insert(w)
    }
    // Withhold from the floor list too, or /usr/share/dict/words would put the
    // English words straight back in and the holdout would measure nothing.
    let (holdLexicon, _) = LexiconBuilder.build(
        inputs, exclude: [.latin: heldLatin, .hebrew: heldHebrew])
    let holdScorer = Scorer(lexicon: holdLexicon, config: config)
    let holdCases = buildCases(scorer: holdScorer,
                               latinWords: latinTest.filter { heldLatin.contains($0.0) },
                               hebrewWords: hebrewTest.filter { heldHebrew.contains($0.0) })

    print("""

================================================================================
OUT-OF-VOCABULARY  (\(heldLatin.count) latin + \(heldHebrew.count) hebrew words
withheld from the lexicon and the character model -- this is the honest number
for inflections, names and jargon the lexicon has never seen)
================================================================================
    tau   FPR(unw)  FPR(wgt)   recall(unw) recall(wgt)  mangled
""")
    for tau in sweep {
        let h = measure(holdCases, threshold: tau, scorer: holdScorer)
        print(String(format: "  %5.1f   %@  %@    %@  %@   %d",
                     tau, pct(h.fpr), pct(h.weightedFPR), pct(h.recall), pct(h.weightedRecall), h.mangled))
    }
    let h = measure(holdCases, threshold: chosen, scorer: holdScorer)
    print("""

  at chosen tau = \(chosen):  weighted FPR \(pct(h.weightedFPR))   weighted recall \(pct(h.weightedRecall))
""")
}

// ============================================================================
// PHRASE-LEVEL BEHAVIOUR
//
// Single-token precision/recall is necessary but not what the user feels. What
// they feel is: "how many words did I type before it noticed, and did it fix
// the ones I had already typed?"
//
// Once we convert and switch the input source, the rest of the sentence is
// typed in the correct layout and needs no correction at all -- so the only
// question that matters is how early the *first* catch happens, plus how much
// of the already-typed prefix we can recover by looking back.
// ============================================================================

/// Re-examine an earlier token now that a later one has proved the run was in
/// the wrong layout. The sticky bonus supplies the context evidence.
func lookbackConverts(_ strokes: [KeyStroke], from active: Script, to target: Script,
                      scorer: Scorer, threshold: Double) -> String? {
    var s = scorer
    s.config.threshold = threshold
    s.config = s.config.relaxedForLookback()
    let detail = s.evaluate(strokes: strokes, pair: pair, activeScript: active, sticky: target)
    if case .convert(let to, let text) = detail.verdict, to == target { return text }
    return nil
}

/// Simulate typing `words` in `intended` while `active` was live.
/// Returns the index of the first token we catch (nil if never), and how many
/// of the preceding tokens lookback recovers.
func simulate(words: [String], intended: Script, active: Script,
              scorer: Scorer, threshold: Double)
    -> (caughtAt: Int?, prefixRecovered: Int, prefixTotal: Int) {
    var s = scorer
    s.config.threshold = threshold
    var strokeList: [[KeyStroke]] = []
    for w in words {
        guard let st = strokes(for: w, script: intended) else { return (nil, 0, 0) }
        strokeList.append(st)
    }
    for (i, st) in strokeList.enumerated() {
        let detail = s.evaluate(strokes: st, pair: pair, activeScript: active, sticky: nil)
        if case .convert(let to, _) = detail.verdict, to == intended {
            var recovered = 0
            for j in 0..<i {
                if lookbackConverts(strokeList[j], from: active, to: intended,
                                    scorer: scorer, threshold: threshold) != nil {
                    recovered += 1
                }
            }
            return (i, recovered, i)
        }
    }
    return (nil, 0, words.count)
}

// MARK: hand-written acceptance cases

struct Acceptance {
    let text: String
    let intended: Script
    let active: Script
    let note: String
}

let acceptanceCases: [Acceptance] = [
    .init(text: "שלום לכם ילדים וילדות", intended: .hebrew, active: .latin,
          note: "the original request"),
    .init(text: "אני חוזר הביתה בעוד שעה", intended: .hebrew, active: .latin, note: ""),
    .init(text: "מה קורה איתך", intended: .hebrew, active: .latin, note: "short words"),
    .init(text: "תודה רבה על העזרה", intended: .hebrew, active: .latin, note: ""),
    .init(text: "hello everyone how are you", intended: .latin, active: .hebrew, note: ""),
    .init(text: "the meeting is tomorrow morning", intended: .latin, active: .hebrew, note: ""),
    .init(text: "please review the pull request", intended: .latin, active: .hebrew, note: ""),
    .init(text: "ok thanks", intended: .latin, active: .hebrew, note: "very short"),
]

func reportAcceptance(scorer: Scorer, threshold: Double) {
    print("""

================================================================================
ACCEPTANCE CASES at tau = \(threshold)
  "caught@N" = we noticed on word N (0-based). "+k" = lookback also fixed k of
  the words already typed. "MISSED" = never noticed.
================================================================================
""")
    for c in acceptanceCases {
        let words = c.text.split(separator: " ").map(String.init)
        let r = simulate(words: words, intended: c.intended, active: c.active,
                         scorer: scorer, threshold: threshold)
        let verdict: String
        if let at = r.caughtAt {
            let fixed = at == 0 ? "whole phrase clean" : "\(r.prefixRecovered)/\(r.prefixTotal) prefix words recovered"
            verdict = "caught@\(at)  (\(fixed))"
        } else {
            verdict = "MISSED"
        }
        let suffix = c.note.isEmpty ? "" : "  [\(c.note)]"
        print("  \(c.intended.rawValue)/\(words.count)w  \(verdict.padding(toLength: 46, withPad: " ", startingAt: 0)) \(c.text)\(suffix)")
    }
}

// MARK: frequency-weighted sentence simulation

/// Sample words in proportion to corpus frequency, so the simulated sentences
/// have the same short-common-word problem real typing does.
struct WeightedSampler {
    let words: [String]
    let cumulative: [Double]
    let total: Double

    init(_ counts: [String: UInt64]) {
        let sorted = counts.sorted { $0.value > $1.value }
        var ws: [String] = [], cum: [Double] = []
        var running = 0.0
        ws.reserveCapacity(sorted.count); cum.reserveCapacity(sorted.count)
        for (w, c) in sorted {
            running += Double(c)
            ws.append(w); cum.append(running)
        }
        words = ws; cumulative = cum; total = running
    }

    func sample<G: RandomNumberGenerator>(using rng: inout G) -> String {
        let target = Double.random(in: 0..<total, using: &rng)
        var lo = 0, hi = cumulative.count - 1
        while lo < hi {
            let mid = (lo + hi) / 2
            if cumulative[mid] < target { lo = mid + 1 } else { hi = mid }
        }
        return words[lo]
    }
}

func reportSentences(scorer: Scorer, threshold: Double, sentences: Int, wordsPer: Int) {
    var rng = SplitMix64(seed: seed &+ 1)
    let heSampler = WeightedSampler(heCounts)
    let enSampler = WeightedSampler(enCounts)

    print("""

================================================================================
SENTENCE SIMULATION at tau = \(threshold)
  \(sentences) frequency-weighted sentences of \(wordsPer) words per direction.
  This is the number that predicts how the app feels to use.
================================================================================
""")
    for (label, sampler, intended, active) in [
        ("Hebrew typed with English active", heSampler, Script.hebrew, Script.latin),
        ("English typed with Hebrew active", enSampler, Script.latin, Script.hebrew),
    ] as [(String, WeightedSampler, Script, Script)] {
        var histogram = [Int: Int]()
        var missed = 0
        var prefixWords = 0, prefixRecovered = 0
        for _ in 0..<sentences {
            let words = (0..<wordsPer).map { _ in sampler.sample(using: &rng) }
            let r = simulate(words: words, intended: intended, active: active,
                             scorer: scorer, threshold: threshold)
            if let at = r.caughtAt {
                histogram[at, default: 0] += 1
                prefixWords += r.prefixTotal
                prefixRecovered += r.prefixRecovered
            } else {
                missed += 1
            }
        }
        print("  \(label)")
        var cumulative = 0
        for i in 0..<wordsPer {
            let n = histogram[i] ?? 0
            cumulative += n
            guard n > 0 else { continue }
            print(String(format: "    caught on word %d: %5.1f%%   (cumulative %5.1f%%)",
                         i, Double(n) / Double(sentences) * 100,
                         Double(cumulative) / Double(sentences) * 100))
        }
        print(String(format: "    never caught:      %5.1f%%", Double(missed) / Double(sentences) * 100))
        if prefixWords > 0 {
            print(String(format: "    lookback recovered %d/%d already-typed words (%.1f%%)",
                         prefixRecovered, prefixWords,
                         Double(prefixRecovered) / Double(prefixWords) * 100))
        }
        print("")
    }
}

reportAcceptance(scorer: fullScorer, threshold: chosen)
reportSentences(scorer: fullScorer, threshold: chosen,
                sentences: args.int("sentences") ?? 3000,
                wordsPer: args.int("words-per") ?? 6)

// ============================================================================
// FALSE-ALARM RATE ON CORRECT TEXT
//
// The decisive safety number. There is no undo, so the cost of a spurious
// conversion is real damage to text the user typed correctly -- and it is
// amplified, because a spurious fire also triggers lookback over the correct
// prefix. Single-token FPR understates this; measure it at sentence level.
// ============================================================================

func reportFalseAlarms(scorer: Scorer, thresholds: [Double], sentences: Int, wordsPer: Int) {
    print("""

================================================================================
FALSE ALARMS ON CORRECTLY TYPED TEXT
  \(sentences) frequency-weighted sentences of \(wordsPer) words per language,
  typed with the RIGHT layout. Any fire here is damage, and it drags the
  correct prefix down with it via lookback.
================================================================================
    tau    HE sentences hit   words mangled     EN sentences hit   words mangled
""")
    for tau in thresholds {
        var line = String(format: "  %5.1f  ", tau)
        for (counts, script) in [(heCounts, Script.hebrew), (enCounts, Script.latin)] {
            var rng = SplitMix64(seed: seed &+ 7)
            let sampler = WeightedSampler(counts)
            var hitSentences = 0, mangledWords = 0, totalWords = 0
            var s = scorer
            s.config.threshold = tau

            for _ in 0..<sentences {
                let words = (0..<wordsPer).map { _ in sampler.sample(using: &rng) }
                var strokeList: [[KeyStroke]] = []
                for w in words {
                    guard let st = strokes(for: w, script: script) else { break }
                    strokeList.append(st)
                }
                guard strokeList.count == words.count else { continue }
                totalWords += words.count

                for (i, st) in strokeList.enumerated() {
                    // Typed with the correct layout: any conversion is a false alarm.
                    let detail = s.evaluate(strokes: st, pair: pair,
                                            activeScript: script, sticky: nil)
                    guard detail.verdict.isConvert else { continue }
                    hitSentences += 1
                    mangledWords += 1
                    // Lookback now drags the correct prefix along too.
                    for j in 0..<i {
                        if lookbackConverts(strokeList[j], from: script, to: script.other,
                                            scorer: scorer, threshold: tau) != nil {
                            mangledWords += 1
                        }
                    }
                    break
                }
            }
            line += String(format: "   %6.3f%% (%3d)      %5d/%-6d ",
                           Double(hitSentences) / Double(sentences) * 100, hitSentences,
                           mangledWords, totalWords)
        }
        print(line)
    }
}

reportFalseAlarms(scorer: fullScorer,
                  thresholds: args.double("threshold") != nil ? [chosen] : sweep,
                  sentences: args.int("sentences") ?? 3000,
                  wordsPer: args.int("words-per") ?? 6)
