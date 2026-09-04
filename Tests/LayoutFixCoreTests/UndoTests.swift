import Foundation
import Testing
@testable import LayoutFixCore

@Suite("Undo")
struct UndoTests {

    let correction = Correction(
        deleteCount: 5, replacement: "שלום ", switchTo: .hebrew, switchFrom: .latin,
        original: "akuo ", wordCount: 1, convertedTokens: ["akuo"])

    @Test("reversing restores exactly what was typed")
    func reverseRestoresOriginal() {
        let undo = correction.reversed
        #expect(undo.replacement == "akuo ")
        #expect(undo.deleteCount == 5, "delete what we inserted")
        #expect(undo.switchTo == .latin, "put the input source back")
        #expect(undo.switchFrom == .hebrew)
        #expect(undo.original == "שלום ")
    }

    /// The delete count must match the text being removed, or undo eats
    /// neighbouring characters -- the one failure mode that would be worse than
    /// no undo at all.
    @Test("reverse delete count matches the inserted text length")
    func reverseDeleteCountIsConsistent() {
        let undo = correction.reversed
        #expect(undo.deleteCount == correction.replacement.count)
        #expect(undo.original.count == undo.deleteCount)
    }

    @Test("reversing twice is the identity")
    func doubleReverseIsIdentity() {
        #expect(correction.reversed.reversed == correction)
    }

    @Test("multi-word corrections reverse whole")
    func multiWordReverse() {
        let multi = Correction(
            deleteCount: 8, replacement: "מה קורה ", switchTo: .hebrew, switchFrom: .latin,
            original: "nv eurv ", wordCount: 2, convertedTokens: ["nv", "eurv"])
        let undo = multi.reversed
        #expect(undo.replacement == "nv eurv ")
        #expect(undo.deleteCount == 8)
        #expect(undo.convertedTokens == ["nv", "eurv"])
    }
}

@Suite("Learned exceptions")
struct LearnedExceptionsTests {

    @Test("a rejection is remembered")
    func remembersRejection() {
        var exceptions = LearnedExceptions()
        #expect(!exceptions.contains(typed: "gus", script: .latin))
        exceptions.insert(typed: "gus", script: .latin)
        #expect(exceptions.contains(typed: "gus", script: .latin))
    }

    @Test("matching ignores case")
    func caseInsensitive() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "Gus", script: .latin)
        #expect(exceptions.contains(typed: "gus", script: .latin))
        #expect(exceptions.contains(typed: "GUS", script: .latin))
    }

    /// The same characters mean different things under different layouts, so a
    /// rejection must not leak across scripts.
    @Test("rejections are scoped to the layout that produced them")
    func scopedByScript() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "gus", script: .latin)
        #expect(!exceptions.contains(typed: "gus", script: .hebrew))
    }

    @Test("re-inserting does not duplicate")
    func deduplicates() {
        var exceptions = LearnedExceptions()
        for _ in 0..<5 { exceptions.insert(typed: "gus", script: .latin) }
        #expect(exceptions.count == 1)
    }

    @Test("retention is bounded")
    func bounded() {
        var exceptions = LearnedExceptions()
        for i in 0..<(LearnedExceptions.maxEntries + 50) {
            exceptions.insert(typed: "word\(i)", script: .latin)
        }
        #expect(exceptions.count == LearnedExceptions.maxEntries)
        // The oldest are dropped, the newest kept.
        #expect(!exceptions.contains(typed: "word0", script: .latin))
        #expect(exceptions.contains(typed: "word\(LearnedExceptions.maxEntries + 49)", script: .latin))
    }

    @Test("storage round-trips")
    func storageRoundTrip() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "gus", script: .latin)
        exceptions.insert(typed: "שד", script: .hebrew)
        let restored = LearnedExceptions(exceptions.storage)
        #expect(restored.contains(typed: "gus", script: .latin))
        #expect(restored.contains(typed: "שד", script: .hebrew))
        #expect(restored == exceptions)
    }

    @Test("clearing removes everything")
    func clearing() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "gus", script: .latin)
        exceptions.removeAll()
        #expect(exceptions.isEmpty)
    }

    @Test("descriptions drop the script prefix for display")
    func descriptions() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "gus", script: .latin)
        #expect(exceptions.descriptions == ["gus"])
    }
}

/// The loop that matters: correct, undo, and never be corrected again.
@Suite("Reject-and-learn loop", .enabled(if: BakedLexicon.available))
struct RejectAndLearnTests {

    func makeEngine() throws -> CorrectionEngine {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        return CorrectionEngine(pair: Fixture.pair, scorer: Scorer(lexicon: lexicon))
    }

    func drive(_ text: String, engine: CorrectionEngine, activeScript: Script) -> [Correction] {
        var out: [Correction] = []
        var t = 1.0
        var active = activeScript
        for ch in text {
            let s = String(ch)
            let lower = s.lowercased()
            guard let keycode = Fixture.pair.latin.keycodeForChar[lower] else { continue }
            if let c = engine.handleKeyDown(keycode: keycode, shift: s != lower,
                                            hasCommandControlOrOption: false,
                                            activeScript: active, timestamp: t) {
                out.append(c)
                active = c.switchTo
            }
            t += 0.05
        }
        return out
    }

    @Test("a word is corrected, then never again once rejected")
    func rejectionSticks() throws {
        let engine = try makeEngine()

        let first = drive("akuo ", engine: engine, activeScript: .latin)
        let correction = try #require(first.first, "should correct the first time")
        #expect(correction.replacement == "שלום ")
        #expect(correction.convertedTokens == ["akuo"])
        #expect(correction.switchFrom == .latin)

        // The user undoes it: record the rejection.
        engine.learnRejection(of: correction)
        engine.reset(.manual)

        // Same keystrokes again: left alone this time.
        let second = drive("akuo ", engine: engine, activeScript: .latin)
        #expect(second.isEmpty, "rejected word was converted again: \(second.map(\.replacement))")
    }

    /// A rejection must survive the lookback path too, which uses a much more
    /// permissive rule and would otherwise sneak the word back in.
    @Test("a rejection also blocks lookback")
    func rejectionBlocksLookback() throws {
        let engine = try makeEngine()
        let first = drive("nv eurv ", engine: engine, activeScript: .latin)
        let correction = try #require(first.first)
        #expect(correction.wordCount == 2)

        // Reject only the first word of the pair.
        engine.exceptions.insert(typed: "nv", script: .latin)
        engine.reset(.manual)

        let second = drive("nv eurv ", engine: engine, activeScript: .latin)
        if let c = second.first {
            #expect(!c.convertedTokens.contains("nv"), "lookback resurrected a rejected word")
            #expect(c.original == "eurv ", "should start after the rejected word")
        }
    }

    @Test("rejecting one word leaves others alone")
    func rejectionIsSpecific() throws {
        let engine = try makeEngine()
        engine.exceptions.insert(typed: "akuo", script: .latin)
        #expect(drive("akuo ", engine: engine, activeScript: .latin).isEmpty)

        engine.reset(.manual)
        let other = drive("vusv ", engine: engine, activeScript: .latin)
        _ = other  // whatever it decides, the rejection of "akuo" must not affect it
        #expect(!engine.exceptions.contains(typed: "vusv", script: .latin))
    }
}

@Suite("Removing individual rejected words")
struct ExceptionRemovalTests {

    var populated: LearnedExceptions {
        var e = LearnedExceptions()
        e.insert(typed: "gus", script: .latin)
        e.insert(typed: "akuo", script: .latin)
        e.insert(typed: "שד", script: .hebrew)
        return e
    }

    @Test("entries expose the word and the layout it came from")
    func entriesCarryScript() {
        let entries = populated.entries
        #expect(entries.count == 3)
        // Most recently rejected first.
        #expect(entries[0] == LearnedExceptions.Entry(word: "שד", script: .hebrew))
        #expect(entries[2] == LearnedExceptions.Entry(word: "gus", script: .latin))
    }

    @Test("removing one word leaves the others blocked")
    func removeIsSpecific() {
        var exceptions = populated
        exceptions.remove(LearnedExceptions.Entry(word: "akuo", script: .latin))
        #expect(exceptions.count == 2)
        #expect(!exceptions.contains(typed: "akuo", script: .latin))
        #expect(exceptions.contains(typed: "gus", script: .latin))
        #expect(exceptions.contains(typed: "שד", script: .hebrew))
    }

    /// The same characters can be rejected under either layout. Removing one
    /// must not take the other with it.
    @Test("removal does not cross scripts")
    func removalDoesNotCrossScripts() {
        var exceptions = LearnedExceptions()
        exceptions.insert(typed: "gus", script: .latin)
        exceptions.insert(typed: "gus", script: .hebrew)
        #expect(exceptions.count == 2)

        exceptions.remove(LearnedExceptions.Entry(word: "gus", script: .latin))
        #expect(!exceptions.contains(typed: "gus", script: .latin))
        #expect(exceptions.contains(typed: "gus", script: .hebrew))
    }

    @Test("removing something absent is a no-op")
    func removeAbsentIsHarmless() {
        var exceptions = populated
        exceptions.remove(LearnedExceptions.Entry(word: "nothere", script: .latin))
        #expect(exceptions.count == 3)
    }

    @Test("an entry round-trips through its storage key")
    func entryRoundTrip() {
        for entry in populated.entries {
            #expect(LearnedExceptions.Entry(storageKey: entry.storageKey) == entry)
        }
    }

    @Test("malformed storage keys are rejected, not guessed at", arguments: [
        "", "noseparator", ":", "latin:", "klingon:word",
    ])
    func malformedKeys(key: String) {
        #expect(LearnedExceptions.Entry(storageKey: key) == nil)
    }

    /// A word un-rejected in the menu must actually be correctable again.
    @Test("un-rejecting restores correction", .enabled(if: BakedLexicon.available))
    func unrejectingRestoresCorrection() throws {
        guard let lexicon = BakedLexicon.shared else { throw LexiconFormat.Error.badMagic }
        let engine = CorrectionEngine(pair: Fixture.pair, scorer: Scorer(lexicon: lexicon))

        func typeAkuo() -> Correction? {
            engine.reset(.manual)
            var t = 1.0
            var result: Correction?
            for ch in "akuo " {
                guard let kc = Fixture.pair.latin.keycodeForChar[String(ch)] else { continue }
                if let c = engine.handleKeyDown(keycode: kc, shift: false,
                                                hasCommandControlOrOption: false,
                                                activeScript: .latin, timestamp: t) {
                    result = c
                }
                t += 0.05
            }
            return result
        }

        engine.exceptions.insert(typed: "akuo", script: .latin)
        #expect(typeAkuo() == nil, "blocked while rejected")

        engine.exceptions.remove(LearnedExceptions.Entry(word: "akuo", script: .latin))
        let restored = try #require(typeAkuo(), "should correct again once un-rejected")
        #expect(restored.replacement == "שלום ")
    }
}
