import AppKit
import Carbon.HIToolbox
import LayoutFixCore

/// `LayoutFixApp --diagnose` prints what the app can see and exits.
///
/// Exists because almost every failure of an app like this is environmental --
/// permission not granted, Hebrew layout not installed, language data not
/// built -- and none of that is visible from a menu-bar icon.
enum Diagnose {

    static func run() -> Never {
        let (report, problems) = collect()
        print("LayoutFix diagnostics")
        print(String(repeating: "-", count: 60))
        print(report)
        print(String(repeating: "-", count: 60))
        if problems.isEmpty {
            print("Ready.")
            exit(0)
        }
        print("\(problems.count) problem(s):\n")
        for (index, problem) in problems.enumerated() { print("\(index + 1). \(problem)\n") }
        exit(1)
    }

    /// Human-readable status for the menu's Diagnostics item.
    static func summary() -> String {
        let (report, problems) = collect()
        guard !problems.isEmpty else { return report + "\n\nReady." }
        return report + "\n\n" + problems.enumerated()
            .map { "\($0.offset + 1). \($0.element)" }
            .joined(separator: "\n\n")
    }

    /// - Returns: the status report, and anything blocking normal operation.
    static func collect() -> (report: String, problems: [String]) {
        var problems: [String] = []
        var lines: [String] = []
        func print(_ line: String) { lines.append(line) }

        // Permissions. Two separate grants, in two different lists.
        let permissions = Permissions.state
        print("Input Monitoring     : \(permissions.canListen ? "granted" : "NOT GRANTED")  (needed to notice)")
        print("Accessibility        : \(permissions.canPost ? "granted" : "NOT GRANTED")  (needed to correct)")
        if !permissions.isComplete {
            problems.append("""
                Enable LayoutFix under System Settings > Privacy & Security >
                  \(permissions.missing.joined(separator: "\n  "))
                then quit and relaunch it.

                If LayoutFix is not listed there at all, add it by hand: click +
                and choose /Applications/LayoutFix.app. An app only appears in
                these lists once macOS has recorded a request for it, and that
                record is sometimes never written -- the + button works anyway.

                Note: CGEvent.tapCreate succeeds without Input Monitoring and then
                delivers nothing, so a running tap is no evidence that it works.
                The menu's "Keys seen" counter is the real check -- it stays at 0
                while Input Monitoring is missing.

                A rebuild changes the app's ad-hoc signature, so macOS may require
                you to re-grant these. Removing and re-adding the entry clears a
                stale grant.
                """)
        }
        print("Secure input active  : \(Permissions.isSecureInputEnabled ? "yes (keystrokes ignored)" : "no")")

        // Layouts
        do {
            let layouts = try SystemLayouts.discover()
            print("Latin layout         : \(layouts.pair.latin.sourceID) "
                  + "(\(layouts.pair.latin.unshifted.count) keys)")
            print("Hebrew layout        : \(layouts.pair.hebrew.sourceID) "
                  + "(\(layouts.pair.hebrew.unshifted.count) keys)")
            let live = SystemLayouts.currentScript()
            print("Live input source    : \(live?.rawValue ?? "neither (a third language or an IME)")")

            let rules = TokenizerRules(pair: layouts.pair)
            print("Word keys            : \(rules.wordKeycodes.count)")

            // Prove the mapping end to end.
            let strokes = "akuo".compactMap { ch -> KeyStroke? in
                layouts.pair.latin.keycodeForChar[String(ch)].map { KeyStroke(keycode: $0) }
            }
            let reading = layouts.pair.reading(strokes, as: .hebrew)
            let ok = reading == "שלום"
            print("Mapping check        : akuo -> \(reading) \(ok ? "OK" : "MISMATCH")")
            if !ok { problems.append("Keycode mapping is not what LayoutFix expects.") }
        } catch {
            print("Layouts              : FAILED - \(error)")
            problems.append("\(error)")
        }

        // Language data
        let bundled = Bundle.main.url(forResource: "lexicon", withExtension: "bin")
        if let url = LexiconFormat.defaultURL(bundleResource: bundled) {
            let size = (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? nil
            print("Lexicon              : \(url.path) (\(size.map { "\($0) bytes" } ?? "unknown size"))")
            do {
                let lexicon = try LexiconFormat.load(from: url)
                print("  latin vocabulary   : \(lexicon.latin.unigrams.count)")
                print("  hebrew vocabulary  : \(lexicon.hebrew.unigrams.count)")
                let config = ScorerConfig()
                print("  threshold          : \(config.threshold) nats "
                      + "(length 2 needs \(config.requiredMargin(strokeCount: 2)))")
            } catch {
                print("  FAILED to load     : \(error)")
                problems.append("Language data is unreadable: \(error)")
            }
        } else {
            print("Lexicon              : NOT FOUND")
            problems.append("Build the language data:  make lexicon && make bundle")
        }

        return (lines.joined(separator: "\n"), problems)
    }
}
