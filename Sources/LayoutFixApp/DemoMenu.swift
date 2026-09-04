import AppKit
import LayoutFixCore

/// `LayoutFixApp --demo-menu` prints the menu-bar menu as a tree and exits.
///
/// The menu is otherwise only inspectable by opening it by hand, and its
/// rejected-words submenu is built from stored state -- so this is the only way
/// to check that the right items, and the right hidden identifiers behind them,
/// come out.
///
/// Runs against a scratch preferences domain, never the user's own: printing a
/// diagnostic must not disturb the list it is describing.
enum DemoMenu {

    private static let scratchSuite = "com.raznissim.hebrish.demo"

    static func run() -> Never {
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        guard let defaults = UserDefaults(suiteName: scratchSuite) else {
            print("could not open scratch defaults"); exit(1)
        }
        defaults.removePersistentDomain(forName: scratchSuite)

        let settings = Settings(defaults: defaults)

        // Seed a mix that exercises the interesting cases: both scripts, and
        // the same characters rejected under each.
        var learned = LearnedExceptions()
        for (word, script) in [("gus", Script.latin), ("akuo", .latin),
                               ("שד", .hebrew), ("gus", .hebrew)] {
            learned.insert(typed: word, script: script)
        }
        settings.learnedExceptions = learned

        guard let layouts = try? SystemLayouts.discover(),
              let url = LexiconFormat.defaultURL(
                bundleResource: Bundle.main.url(forResource: "lexicon", withExtension: "bin")),
              let lexicon = try? LexiconFormat.load(from: url) else {
            print("layouts or lexicon unavailable"); exit(1)
        }

        let engine = CorrectionEngine(pair: layouts.pair, scorer: Scorer(lexicon: lexicon))
        let coordinator = Coordinator(engine: engine, layouts: layouts, settings: settings)
        // Deliberately not started: no event tap, no permissions needed.
        let controller = MenuBarController(coordinator: coordinator, settings: settings)

        print("seeded \(learned.count) rejected words: \(learned.entries.map(\.storageKey))")
        print()
        dump(controller.debugMenu())

        defaults.removePersistentDomain(forName: scratchSuite)
        exit(0)
    }

    private static func dump(_ menu: NSMenu, indent: String = "") {
        for item in menu.items {
            if item.isSeparatorItem {
                print("\(indent)---")
                continue
            }
            let state = item.state == .on ? " [on]" : ""
            let enabled = item.isEnabled ? "" : "  (disabled)"
            let payload = (item.representedObject as? String).map { "  -> \($0)" } ?? ""
            let action = item.action.map { "  action=\($0)" } ?? ""
            print("\(indent)\(item.title)\(state)\(enabled)\(payload)\(action)")
            if let submenu = item.submenu {
                dump(submenu, indent: indent + "    ")
            }
        }
    }
}
