import Testing
@testable import LayoutFixCore

/// A hand-built pair standing in for the real system layouts, so the
/// transliteration logic is testable without any input source installed.
/// Values are the macOS ABC / Hebrew tables as dumped by UCKeyTranslate.
enum Fixture {
    static let latinUnshifted: [UInt16: String] = [
        0: "a", 1: "s", 2: "d", 3: "f", 4: "h", 5: "g", 6: "z", 7: "x", 8: "c", 9: "v",
        11: "b", 12: "q", 13: "w", 14: "e", 15: "r", 16: "y", 17: "t",
        31: "o", 32: "u", 34: "i", 35: "p", 37: "l", 38: "j", 39: "'", 40: "k", 41: ";",
        43: ",", 44: "/", 45: "n", 46: "m", 47: ".", 49: " ",
    ]
    static let hebrewUnshifted: [UInt16: String] = [
        0: "ש", 1: "ד", 2: "ג", 3: "כ", 4: "י", 5: "ע", 6: "ז", 7: "ס", 8: "ב", 9: "ה",
        11: "נ", 12: "/", 13: "׳", 14: "ק", 15: "ר", 16: "ט", 17: "א",
        31: "ם", 32: "ו", 34: "ן", 35: "פ", 37: "ך", 38: "ח", 39: ",", 40: "ל", 41: "ף",
        43: "ת", 44: ".", 45: "מ", 46: "צ", 47: "ץ", 49: " ",
    ]

    static let pair = LayoutPair(
        latin: LayoutTable(sourceID: "test.ABC",
                           unshifted: latinUnshifted,
                           shifted: latinUnshifted.mapValues { $0.uppercased() }),
        // Empty on purpose: on the real Hebrew layout Shift emits nothing for
        // letter keys -- it is reserved for nikud -- so modelling it as
        // producing the same letter would hide exactly the bug this fixture
        // needs to expose.
        hebrew: LayoutTable(sourceID: "test.Hebrew",
                            unshifted: hebrewUnshifted,
                            shifted: [:])
    )

    /// Turn a literal typed on the Latin layout into the keystrokes that produced it.
    static func strokes(_ typed: String) -> [KeyStroke] {
        typed.compactMap { ch in
            let s = String(ch)
            let lower = s.lowercased()
            guard let kc = pair.latin.keycodeForChar[lower] else { return nil }
            return KeyStroke(keycode: kc, shift: s != lower)
        }
    }

    static let rules = TokenizerRules(pair: pair)

    /// Whether this machine has both layouts enabled, for gating the live tests.
    static let systemLayoutsAvailable: Bool = (try? SystemLayouts.discover()) != nil
}

@Suite("Layout mapping")
struct LayoutMapTests {

    /// The motivating example from the original request.
    @Test("user's example converts to Hebrew")
    func usersExample() {
        #expect(Fixture.pair.reading(Fixture.strokes("akuo kfo hksho uhksu,"), as: .hebrew)
                == "שלום לכם ילדים וילדות")
    }

    @Test("user's example, word by word", arguments: [
        ("akuo", "שלום"),
        ("kfo", "לכם"),
        ("hksho", "ילדים"),
        ("uhksu,", "וילדות"),
    ])
    func usersExampleWordByWord(typed: String, expected: String) {
        #expect(Fixture.pair.reading(Fixture.strokes(typed), as: .hebrew) == expected)
    }

    /// The other direction: English typed while Hebrew was live.
    @Test("English typed on the Hebrew layout is recoverable")
    func englishOnHebrewLayout() {
        let strokes = Fixture.strokes("hello")
        // What the user would actually have seen on screen.
        #expect(Fixture.pair.produced(strokes, activeScript: .hebrew) == "יקךךם")
        // What we should recover.
        #expect(Fixture.pair.reading(strokes, as: .latin) == "hello")
    }

    @Test("Shift is honoured on Latin and ignored on Hebrew")
    func shiftHandling() {
        let strokes = Fixture.strokes("Hello")
        #expect(Fixture.pair.reading(strokes, as: .latin) == "Hello")
        #expect(Fixture.pair.reading(strokes, as: .hebrew) == "יקךךם")
    }

    @Test("transliteration round-trips")
    func roundTrip() {
        let original = "the quick brown fox jumps over"
        let hebrewised = Fixture.pair.transliterate(original, from: .latin, to: .hebrew)
        #expect(hebrewised != original)
        #expect(Fixture.pair.transliterate(hebrewised, from: .hebrew, to: .latin) == original)
    }

    @Test("transliteration agrees with keystroke reading")
    func transliterateMatchesReading() {
        #expect(Fixture.pair.transliterate("akuo", from: .latin, to: .hebrew) == "שלום")
        #expect(Fixture.pair.transliterate("שלום", from: .hebrew, to: .latin) == "akuo")
    }

    @Test("produced length drives the deletion count")
    func producedLength() {
        let strokes = Fixture.strokes("akuo")
        #expect(Fixture.pair.produced(strokes, activeScript: .latin).count == 4)
        #expect(Fixture.pair.produced(strokes, activeScript: .hebrew).count == 4)
    }
}

/// Guards on the *real* machine layouts. Disabled when Hebrew is not installed,
/// so the suite still passes on a clean box.
@Suite("System layout discovery", .enabled(if: Fixture.systemLayoutsAvailable))
struct SystemLayoutsTests {

    @Test("derived Hebrew table agrees with the known-good fixture")
    func derivedTableMatchesFixture() throws {
        let system = try SystemLayouts.discover()
        // keycode 13 is the w/geresh slot, which differs between Hebrew variants.
        for (keycode, expected) in Fixture.hebrewUnshifted where keycode != 13 {
            #expect(system.pair.hebrew.unshifted[keycode] == expected,
                    "hebrew keycode \(keycode)")
        }
    }

    @Test("live layouts reproduce the user's example")
    func liveLayoutsReproduceExample() throws {
        let system = try SystemLayouts.discover()
        #expect(system.pair.reading(Fixture.strokes("akuo kfo hksho uhksu,"), as: .hebrew)
                == "שלום לכם ילדים וילדות")
    }

    @Test("both tables cover the letter rows")
    func tablesAreDense() throws {
        let system = try SystemLayouts.discover()
        #expect(system.pair.latin.unshifted.count > 40)
        #expect(system.pair.hebrew.unshifted.count > 40)
    }
}
