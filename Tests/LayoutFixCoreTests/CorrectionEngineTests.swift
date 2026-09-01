import Foundation
import Testing
@testable import LayoutFixCore

/// End-to-end over the real baked lexicon: keystrokes in, corrections out.
/// Requires `make lexicon`; skipped otherwise.
@Suite("Correction engine", .enabled(if: BakedLexicon.available))
struct CorrectionEngineTests {

    func makeEngine() throws -> CorrectionEngine {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        return CorrectionEngine(pair: Fixture.pair, scorer: Scorer(lexicon: lexicon))
    }

    /// Type a literal on the physical keys of the Latin layout.
    /// Returns every correction the engine emitted, in order.
    func drive(_ text: String, engine: CorrectionEngine, activeScript: Script) -> [Correction] {
        var out: [Correction] = []
        var t = 1.0
        var active = activeScript
        for ch in text {
            let s = String(ch)
            let lower = s.lowercased()
            guard let keycode = Fixture.pair.latin.keycodeForChar[lower] else { continue }
            if let correction = engine.handleKeyDown(keycode: keycode, shift: s != lower,
                                                    hasCommandControlOrOption: false,
                                                    activeScript: active, timestamp: t) {
                out.append(correction)
                // The app switches the input source, so subsequent keys land in
                // the corrected language -- mirror that here.
                active = correction.switchTo
            }
            t += 0.05
        }
        return out
    }

    /// The original request, driven through tokenization rather than fed
    /// pre-split. This is the case where the trailing comma key matters.
    @Test("the original request is corrected on the first word")
    func originalRequest() throws {
        let engine = try makeEngine()
        let corrections = drive("akuo kfo hksho uhksu, ", engine: engine, activeScript: .latin)

        #expect(corrections.count == 1, "should fire once, then the layout is right")
        let first = try #require(corrections.first)
        #expect(first.switchTo == .hebrew)
        #expect(first.replacement == "שלום ")
        #expect(first.original == "akuo ")
        #expect(first.deleteCount == 5, "four letters plus the space")
    }

    /// A Hebrew word whose last letter comes from the comma key: the token must
    /// not be truncated.
    @Test("a word ending in tav keeps its final letter")
    func trailingTavSurvives() throws {
        let engine = try makeEngine()
        let corrections = drive("uhksu, ", engine: engine, activeScript: .latin)
        let first = try #require(corrections.first)
        #expect(first.replacement == "וילדות ")
        #expect(first.deleteCount == 7, "six typed characters plus the space")
    }

    /// "מה קורה" -- the first word is two letters, too little evidence to act
    /// on alone. The second word settles it, and lookback must repair the first
    /// in the same replacement.
    @Test("lookback repairs a word already typed")
    func lookbackRepairsPrefix() throws {
        let engine = try makeEngine()
        // n->מ v->ה  space  e->ק u->ו r->ר v->ה
        let corrections = drive("nv eurv ", engine: engine, activeScript: .latin)

        let first = try #require(corrections.first, "should have caught it by the second word")
        #expect(first.switchTo == .hebrew)
        #expect(first.wordCount == 2, "both words corrected in one replacement")
        #expect(first.original == "nv eurv ")
        #expect(first.replacement == "מה קורה ")
        #expect(first.deleteCount == 8)
    }

    @Test("correctly typed English produces no correction")
    func correctEnglishUntouched() throws {
        let engine = try makeEngine()
        let corrections = drive("the meeting is tomorrow morning please review ",
                                engine: engine, activeScript: .latin)
        #expect(corrections.isEmpty, "would have wrecked: \(corrections.map(\.replacement))")
    }

    @Test("English typed on a Hebrew layout is corrected back")
    func englishOnHebrewCorrected() throws {
        let engine = try makeEngine()
        let corrections = drive("hello everyone ", engine: engine, activeScript: .hebrew)
        let first = try #require(corrections.first)
        #expect(first.switchTo == .latin)
        #expect(first.replacement == "hello ")
        #expect(first.original == "יקךךם ", "what was actually on screen")
        #expect(first.deleteCount == 6)
    }

    @Test("delete count always matches what was on screen")
    func deleteCountConsistency() throws {
        let engine = try makeEngine()
        for phrase in ["akuo ", "uhksu, ", ",usv ", "vfk "] {
            let e = try makeEngine()
            for c in drive(phrase, engine: e, activeScript: .latin) {
                #expect(c.deleteCount == c.original.count,
                        "\(phrase): delete \(c.deleteCount) vs original '\(c.original)'")
            }
        }
        _ = engine
    }

    /// A reset in the middle must stop lookback reaching across it.
    @Test("a reset stops lookback reaching further back")
    func resetBoundsLookback() throws {
        let engine = try makeEngine()
        _ = drive("bt ", engine: engine, activeScript: .latin)
        engine.reset(.mouseClick)
        let corrections = drive("akuo ", engine: engine, activeScript: .latin)
        let first = try #require(corrections.first)
        #expect(first.wordCount == 1)
        #expect(first.original == "akuo ", "must not reach back past the reset")
    }

    @Test("the engine can be disabled")
    func disabled() throws {
        let engine = try makeEngine()
        engine.enabled = false
        #expect(drive("akuo ", engine: engine, activeScript: .latin).isEmpty)
        // ...but it still evaluates, so the debug view has something to show.
        #expect(engine.lastDetail != nil)
    }
}
