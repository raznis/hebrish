import Foundation

/// A text replacement to apply at the caret.
public struct Correction: Equatable, Sendable {
    /// How many characters to delete backwards from the caret.
    public let deleteCount: Int
    /// What to type in their place.
    public let replacement: String
    /// Which input source to select afterwards.
    public let switchTo: Script
    /// What was on screen, for logging and the HUD.
    public let original: String
    /// How many words this covers (1 = just the word just finished).
    public let wordCount: Int

    public init(deleteCount: Int, replacement: String, switchTo: Script,
                original: String, wordCount: Int) {
        self.deleteCount = deleteCount
        self.replacement = replacement
        self.switchTo = switchTo
        self.original = original
        self.wordCount = wordCount
    }
}

/// Ties the typing buffer to the scorer and produces corrections.
///
/// Deliberately pure: it is *told* about key events and *returns* what should
/// happen, never touching the system itself. All the judgement lives here where
/// it can be tested; the app layer only does I/O.
public final class CorrectionEngine {
    public let pair: LayoutPair
    public var scorer: Scorer
    public private(set) var buffer: TypingBuffer

    /// Set false to evaluate and report without ever emitting a correction.
    public var enabled = true

    public init(pair: LayoutPair, scorer: Scorer,
                capacity: Int = 64, idleTimeout: TimeInterval = 4.0) {
        self.pair = pair
        self.scorer = scorer
        self.buffer = TypingBuffer(rules: TokenizerRules(pair: pair),
                                   capacity: capacity, idleTimeout: idleTimeout)
    }

    public func reset(_ reason: ResetReason) {
        buffer.reset(reason)
    }

    /// The last thing the engine decided, for the debug menu.
    public private(set) var lastDetail: ScoreDetail?

    /// Feed one key-down event; returns a correction when one is warranted.
    public func handleKeyDown(keycode: UInt16,
                              shift: Bool,
                              hasCommandControlOrOption: Bool,
                              activeScript: Script,
                              timestamp: TimeInterval) -> Correction? {
        let produced = pair.table(for: activeScript)
            .char(for: KeyStroke(keycode: keycode, shift: shift))

        let outcome = buffer.handleKeyDown(keycode: keycode,
                                          shift: shift,
                                          hasCommandControlOrOption: hasCommandControlOrOption,
                                          producedCharacter: produced,
                                          activeScript: activeScript,
                                          timestamp: timestamp)
        guard outcome == .tokenCompleted else { return nil }
        guard let token = buffer.lastCompleted, !token.strokes.isEmpty else { return nil }

        let detail = scorer.evaluate(strokes: token.strokes, pair: pair,
                                     activeScript: token.activeScript, sticky: nil)
        lastDetail = detail

        guard enabled, case .convert(let target, let text) = detail.verdict else { return nil }
        return buildCorrection(target: target, lastText: text)
    }

    // MARK: - Assembling the replacement

    /// Build the correction, extending backwards over words already typed.
    ///
    /// The word that just finished is proof the whole run was mis-keyed, so
    /// earlier words are re-examined under the relaxed lookback rule. Because
    /// deleting an earlier word means deleting everything after it, any word in
    /// between that does *not* convert is simply retyped unchanged.
    func buildCorrection(target: Script, lastText: String) -> Correction? {
        let run = buffer.run
        guard let lastToken = run.last else { return nil }
        let activeScript = lastToken.activeScript

        var relaxed = scorer
        relaxed.config = scorer.config.relaxedForLookback()

        // Decide each earlier word. Only words typed under the same layout are
        // eligible -- a manual input-source change resets the buffer, so in
        // practice they all are.
        var converted = [String?](repeating: nil, count: run.count)
        converted[run.count - 1] = lastText
        for index in 0..<(run.count - 1) {
            let token = run[index]
            guard token.activeScript == activeScript else { continue }
            let detail = relaxed.evaluate(strokes: token.strokes, pair: pair,
                                          activeScript: activeScript, sticky: target)
            if case .convert(let to, let text) = detail.verdict, to == target {
                converted[index] = text
            }
        }

        guard let start = converted.firstIndex(where: { $0 != nil }) else { return nil }

        var deleteCount = 0
        var replacement = ""
        var original = ""
        var wordCount = 0

        for index in start..<run.count {
            let token = run[index]
            let producedText = pair.produced(token.strokes, activeScript: token.activeScript)
            let boundaryText = token.boundary.flatMap {
                pair.table(for: token.activeScript).char(for: $0)
            } ?? ""

            deleteCount += producedText.count + boundaryText.count
            original += producedText + boundaryText
            replacement += (converted[index] ?? producedText) + boundaryText
            if converted[index] != nil { wordCount += 1 }
        }

        guard deleteCount > 0, replacement != original else { return nil }

        buffer.noteCorrectionApplied()
        return Correction(deleteCount: deleteCount,
                          replacement: replacement,
                          switchTo: target,
                          original: original,
                          wordCount: wordCount)
    }
}
