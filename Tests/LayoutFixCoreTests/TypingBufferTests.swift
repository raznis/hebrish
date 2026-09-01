import Foundation
import Testing
@testable import LayoutFixCore

@Suite("Typing buffer")
struct TypingBufferTests {

    /// Feed a literal as if typed on the Latin layout.
    /// Returns the outcome of the final keystroke.
    @discardableResult
    func type(_ text: String, into buffer: inout TypingBuffer,
              activeScript: Script = .latin, startTime: TimeInterval = 1.0)
        -> [TypingBuffer.Outcome] {
        var outcomes: [TypingBuffer.Outcome] = []
        var t = startTime
        for ch in text {
            let s = String(ch)
            let lower = s.lowercased()
            let keycode = Fixture.pair.latin.keycodeForChar[lower]
                ?? Fixture.pair.latin.keycodeForChar[s]
            guard let keycode else { continue }
            let produced = Fixture.pair.table(for: activeScript)
                .char(for: KeyStroke(keycode: keycode, shift: s != lower))
            outcomes.append(buffer.handleKeyDown(
                keycode: keycode, shift: s != lower,
                hasCommandControlOrOption: false,
                producedCharacter: produced,
                activeScript: activeScript, timestamp: t))
            t += 0.05
        }
        return outcomes
    }

    @Test("a word is completed by a space")
    func spaceCompletesToken() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        let outcomes = type("akuo ", into: &buffer)
        #expect(outcomes.last == .tokenCompleted)
        #expect(buffer.lastCompleted?.strokes.count == 4)
        #expect(Fixture.pair.reading(buffer.lastCompleted!.strokes, as: .hebrew) == "שלום")
    }

    @Test("produced length counts what landed on screen, not keystrokes")
    func producedLength() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo ", into: &buffer)
        #expect(buffer.lastCompleted?.producedLength == 4)
    }

    @Test("a run of words accumulates for lookback")
    func runAccumulates() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo kfo hksho ", into: &buffer)
        #expect(buffer.run.count == 3)
        #expect(buffer.lookbackCandidates.count == 2)
        #expect(Fixture.pair.reading(buffer.lookbackCandidates[0].strokes, as: .hebrew) == "שלום")
    }

    /// The comma key is punctuation under Latin but tav under Hebrew, so it
    /// must stay inside the token -- otherwise the last letter of a Hebrew
    /// word typed on an English layout is silently lost.
    @Test("keys that are letters in either script stay word-internal")
    func ambiguousPunctuationStaysInToken() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        let outcomes = type("uhksu, ", into: &buffer, activeScript: .latin)
        #expect(outcomes.last == .tokenCompleted)
        // The whole word, including the final tav, must survive.
        #expect(Fixture.pair.reading(buffer.lastCompleted!.strokes, as: .hebrew) == "וילדות")
    }

    @Test("keys that are letters in neither script end the token")
    func unambiguousPunctuationBreaksToken() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        // "/" is a slash under Latin and a full stop under Hebrew: a separator
        // either way.
        let outcomes = type("akuo/", into: &buffer, activeScript: .latin)
        #expect(outcomes.last == .tokenCompleted)
        #expect(buffer.lastCompleted?.strokes.count == 4)
    }

    @Test("apostrophes stay inside Latin contractions")
    func contractionsAreOneToken() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        let outcomes = type("don't ", into: &buffer, activeScript: .latin)
        #expect(outcomes.last == .tokenCompleted)
        #expect(buffer.lastCompleted?.strokes.count == 5)
    }

    // MARK: reset rules

    @Test("navigation keys discard the buffer", arguments: [
        VK.leftArrow, VK.rightArrow, VK.upArrow, VK.downArrow,
        VK.home, VK.end, VK.escape, VK.pageUp,
    ])
    func navigationResets(keycode: UInt16) {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo", into: &buffer)
        let outcome = buffer.handleKeyDown(keycode: keycode, shift: false,
                                           hasCommandControlOrOption: false,
                                           producedCharacter: nil,
                                           activeScript: .latin, timestamp: 2.0)
        #expect(outcome == .reset(.navigation))
        #expect(buffer.isEmpty)
    }

    @Test("backspace discards the buffer")
    func deletionResets() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo", into: &buffer)
        let outcome = buffer.handleKeyDown(keycode: VK.delete, shift: false,
                                           hasCommandControlOrOption: false,
                                           producedCharacter: nil,
                                           activeScript: .latin, timestamp: 2.0)
        #expect(outcome == .reset(.deletion))
    }

    /// Cmd/Ctrl/Opt combinations are commands whose effect on the text is
    /// unknowable. Shift alone is ordinary typing and must not reset.
    @Test("command chords reset but Shift alone does not")
    func modifierChords() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo", into: &buffer)
        let outcome = buffer.handleKeyDown(keycode: 9, shift: false,
                                           hasCommandControlOrOption: true,
                                           producedCharacter: "v",
                                           activeScript: .latin, timestamp: 2.0)
        #expect(outcome == .reset(.modifierChord))

        var shifted = TypingBuffer(rules: Fixture.rules)
        let outcomes = type("Akuo", into: &shifted)
        #expect(!outcomes.contains { if case .reset = $0 { return true } else { return false } })
        #expect(shifted.current.count == 4)
        #expect(shifted.current[0].shift)
    }

    @Test("a long pause discards the buffer")
    func idleTimeoutResets() {
        var buffer = TypingBuffer(rules: Fixture.rules, idleTimeout: 4.0)
        type("akuo", into: &buffer, startTime: 1.0)
        // 10 s later: the caret may have moved by means we cannot see.
        let outcome = buffer.handleKeyDown(keycode: 0, shift: false,
                                           hasCommandControlOrOption: false,
                                           producedCharacter: "a",
                                           activeScript: .latin, timestamp: 20.0)
        #expect(outcome == .accumulating)
        #expect(buffer.current.count == 1, "the new keystroke starts a fresh run")
        #expect(buffer.lastResetReason == .idleTimeout)
    }

    @Test("Return starts a new line of text")
    func returnResets() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo ", into: &buffer)
        let outcome = buffer.handleKeyDown(keycode: VK.ret, shift: false,
                                           hasCommandControlOrOption: false,
                                           producedCharacter: "\r",
                                           activeScript: .latin, timestamp: 3.0)
        #expect(outcome == .reset(.navigation))
        #expect(buffer.isEmpty)
    }

    @Test("the buffer is bounded")
    func capacityBound() {
        var buffer = TypingBuffer(rules: Fixture.rules, capacity: 8)
        let outcomes = type("abcdefghijkl", into: &buffer)
        #expect(outcomes.contains(.reset(.capacity)))
    }

    @Test("a run is trimmed so we never retain more than the recent past")
    func runIsTrimmed() {
        var buffer = TypingBuffer(rules: Fixture.rules, capacity: 64)
        for _ in 0..<30 { type("akuo ", into: &buffer) }
        #expect(buffer.run.count <= 12)
    }

    @Test("applying a correction clears the buffer")
    func correctionClears() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo ", into: &buffer)
        buffer.noteCorrectionApplied()
        #expect(buffer.isEmpty)
        #expect(buffer.lastResetReason == .correctionApplied)
    }

    @Test("reset overwrites retained keystrokes")
    func resetOverwrites() {
        var buffer = TypingBuffer(rules: Fixture.rules)
        type("akuo", into: &buffer)
        #expect(!buffer.current.isEmpty)
        buffer.reset(.manual)
        #expect(buffer.current.isEmpty)
        #expect(buffer.run.isEmpty)
    }
}
