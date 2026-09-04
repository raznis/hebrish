import Foundation
import Carbon.HIToolbox

/// The two writing systems Hebrish arbitrates between.
public enum Script: String, Sendable, CaseIterable {
    case latin
    case hebrew

    public var other: Script { self == .latin ? .hebrew : .latin }
}

/// One physical keypress: the hardware keycode plus whether Shift was held.
///
/// We deliberately store keycodes rather than characters. The character a key
/// produces depends on the live input source, but the keycode does not — so from
/// a keycode we can always reconstruct *both* the Latin and the Hebrew reading,
/// no matter which layout was active when the user typed.
public struct KeyStroke: Equatable, Hashable, Sendable {
    public let keycode: UInt16
    public let shift: Bool

    public init(keycode: UInt16, shift: Bool = false) {
        self.keycode = keycode
        self.shift = shift
    }
}

/// keycode -> character tables for a single keyboard layout.
///
/// Pure data, so tests can build one from literals without touching the system.
public struct LayoutTable: Sendable {
    public let sourceID: String
    public let unshifted: [UInt16: String]
    public let shifted: [UInt16: String]
    /// Reverse lookup over `unshifted`, lowest keycode wins on collision.
    public let keycodeForChar: [String: UInt16]

    public init(sourceID: String, unshifted: [UInt16: String], shifted: [UInt16: String]) {
        self.sourceID = sourceID
        self.unshifted = unshifted
        self.shifted = shifted
        var reverse: [String: UInt16] = [:]
        for kc in unshifted.keys.sorted() {
            let ch = unshifted[kc]!
            if reverse[ch] == nil { reverse[ch] = kc }
        }
        self.keycodeForChar = reverse
    }

    public func char(for stroke: KeyStroke) -> String? {
        if stroke.shift, let s = shifted[stroke.keycode] { return s }
        return unshifted[stroke.keycode]
    }
}

/// A Latin table paired with a Hebrew table — the heart of the transliterator.
public struct LayoutPair: Sendable {
    public let latin: LayoutTable
    public let hebrew: LayoutTable

    public init(latin: LayoutTable, hebrew: LayoutTable) {
        self.latin = latin
        self.hebrew = hebrew
    }

    public func table(for script: Script) -> LayoutTable {
        script == .latin ? latin : hebrew
    }

    /// What the user *meant* to type, read as `script`.
    ///
    /// Hebrew is caseless, so Shift is ignored on that side. On the Latin side
    /// Shift is honoured, which lets an HE->EN correction restore capitalisation.
    public func reading(_ strokes: [KeyStroke], as script: Script) -> String {
        var out = ""
        out.reserveCapacity(strokes.count)
        for s in strokes {
            guard let base = table(for: script).unshifted[s.keycode] else { continue }
            if script == .latin && s.shift {
                out += base.uppercased()
            } else {
                out += base
            }
        }
        return out
    }

    /// What actually landed on screen, given the layout that was live.
    /// Used to work out how many characters a correction has to delete.
    public func produced(_ strokes: [KeyStroke], activeScript: Script) -> String {
        var out = ""
        out.reserveCapacity(strokes.count)
        for s in strokes {
            if let ch = table(for: activeScript).char(for: s) { out += ch }
        }
        return out
    }

    /// Re-key a literal string as if the same physical keys had been pressed
    /// under the other layout. Characters with no key on the source layout pass
    /// through unchanged. Mainly a convenience for tests and the eval harness.
    public func transliterate(_ text: String, from: Script, to: Script) -> String {
        let src = table(for: from)
        let dst = table(for: to)
        var out = ""
        out.reserveCapacity(text.count)
        for ch in text {
            let s = String(ch)
            let lowered = s.lowercased()
            if let kc = src.keycodeForChar[lowered] ?? src.keycodeForChar[s],
               let mapped = dst.unshifted[kc] {
                out += (to == .latin && s != lowered) ? mapped.uppercased() : mapped
            } else {
                out += s
            }
        }
        return out
    }
}

// MARK: - Discovery of the live system layouts

public enum LayoutDiscoveryError: Error, CustomStringConvertible {
    case noLatinLayout
    case noHebrewLayout
    case noKeyLayoutData(String)

    public var description: String {
        switch self {
        case .noLatinLayout:
            return "No enabled Latin keyboard layout found."
        case .noHebrewLayout:
            return "No enabled Hebrew keyboard layout found. Add one in System Settings > Keyboard > Input Sources."
        case .noKeyLayoutData(let id):
            return "Input source \(id) exposes no Unicode key-layout data."
        }
    }
}

/// Reads the enabled keyboard input sources out of Text Input Services and
/// derives their keycode tables via `UCKeyTranslate`.
///
/// Deriving the tables at runtime (rather than hardcoding QWERTY<->Hebrew) means
/// Hebrew-Standard, Hebrew-PC, Hebrew-QWERTY and any non-US Latin layout all work
/// with no extra code.
public struct SystemLayouts {
    public let pair: LayoutPair
    public let latinSource: TISInputSource
    public let hebrewSource: TISInputSource

    public init(pair: LayoutPair, latinSource: TISInputSource, hebrewSource: TISInputSource) {
        self.pair = pair
        self.latinSource = latinSource
        self.hebrewSource = hebrewSource
    }

    public func source(for script: Script) -> TISInputSource {
        script == .latin ? latinSource : hebrewSource
    }

    /// Discover among the *enabled* input sources (not all ~250 installed ones).
    public static func discover() throws -> SystemLayouts {
        let sources = enabledKeyboardLayouts()

        var latinCandidate: (TISInputSource, String)?
        var hebrewCandidate: (TISInputSource, String)?

        for (src, id) in sources {
            let langs = languages(of: src)
            if langs.contains("he") || id.localizedCaseInsensitiveContains("hebrew") {
                if hebrewCandidate == nil { hebrewCandidate = (src, id) }
            } else if langs.contains("en") || id.hasSuffix(".ABC") || id.hasSuffix(".US") {
                if latinCandidate == nil { latinCandidate = (src, id) }
            }
        }

        guard let (latinSrc, latinID) = latinCandidate else { throw LayoutDiscoveryError.noLatinLayout }
        guard let (hebSrc, hebID) = hebrewCandidate else { throw LayoutDiscoveryError.noHebrewLayout }

        guard let latinTable = table(for: latinSrc, id: latinID) else {
            throw LayoutDiscoveryError.noKeyLayoutData(latinID)
        }
        guard let hebTable = table(for: hebSrc, id: hebID) else {
            throw LayoutDiscoveryError.noKeyLayoutData(hebID)
        }

        return SystemLayouts(pair: LayoutPair(latin: latinTable, hebrew: hebTable),
                             latinSource: latinSrc, hebrewSource: hebSrc)
    }

    /// Which script the live input source writes in, if we can tell.
    public static func currentScript() -> Script? {
        guard let cur = TISCopyCurrentKeyboardInputSource()?.takeRetainedValue() else { return nil }
        let langs = languages(of: cur)
        if langs.contains("he") { return .hebrew }
        if langs.contains("en") { return .latin }
        if let id = stringProperty(cur, kTISPropertyInputSourceID) {
            if id.localizedCaseInsensitiveContains("hebrew") { return .hebrew }
        }
        return nil
    }

    // MARK: internals

    static func enabledKeyboardLayouts() -> [(TISInputSource, String)] {
        let filter = [
            kTISPropertyInputSourceCategory as String: kTISCategoryKeyboardInputSource as String,
            kTISPropertyInputSourceIsEnableCapable as String: true,
        ] as CFDictionary
        guard let list = TISCreateInputSourceList(filter, false)?.takeRetainedValue()
                as? [TISInputSource] else { return [] }
        return list.compactMap { src in
            guard let id = stringProperty(src, kTISPropertyInputSourceID) else { return nil }
            return (src, id)
        }
    }

    static func stringProperty(_ src: TISInputSource, _ key: CFString!) -> String? {
        guard let p = TISGetInputSourceProperty(src, key) else { return nil }
        return Unmanaged<CFString>.fromOpaque(p).takeUnretainedValue() as String
    }

    static func languages(of src: TISInputSource) -> [String] {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyInputSourceLanguages) else { return [] }
        return (Unmanaged<CFArray>.fromOpaque(p).takeUnretainedValue() as? [String]) ?? []
    }

    /// Ask UCKeyTranslate for every keycode, unshifted and shifted.
    static func table(for src: TISInputSource, id: String) -> LayoutTable? {
        guard let p = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) else { return nil }
        let data = Unmanaged<CFData>.fromOpaque(p).takeUnretainedValue() as Data

        var unshifted: [UInt16: String] = [:]
        var shifted: [UInt16: String] = [:]

        data.withUnsafeBytes { raw in
            guard let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress else { return }
            let kbdType = UInt32(LMGetKbdType())
            // shiftKey (0x0200) as UCKeyTranslate wants it: the high byte of the
            // classic event-record modifiers field.
            for (modState, sink) in [(UInt32(0), 0), (UInt32(shiftKey >> 8), 1)] {
                for keycode in UInt16(0)...127 {
                    var deadKeyState: UInt32 = 0
                    var chars = [UniChar](repeating: 0, count: 8)
                    var length = 0
                    let status = UCKeyTranslate(layout, keycode, UInt16(kUCKeyActionDown),
                                               modState, kbdType,
                                               OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                               &deadKeyState, 8, &length, &chars)
                    guard status == noErr, length > 0 else { continue }
                    let s = String(utf16CodeUnits: chars, count: length)
                    guard let first = s.unicodeScalars.first, first.value >= 0x20 else { continue }
                    if sink == 0 { unshifted[keycode] = s } else { shifted[keycode] = s }
                }
            }
        }

        guard !unshifted.isEmpty else { return nil }
        return LayoutTable(sourceID: id, unshifted: unshifted, shifted: shifted)
    }
}
