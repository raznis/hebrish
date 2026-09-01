import AppKit
import LayoutFixCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: Coordinator?
    private var menuBar: MenuBarController?
    private let settings = Settings()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let layouts: SystemLayouts
        do {
            layouts = try SystemLayouts.discover()
        } catch {
            fatal("Keyboard layouts", "\(error)")
            return
        }

        guard let lexiconURL = LexiconFormat.defaultURL(
            bundleResource: Bundle.main.url(forResource: "lexicon", withExtension: "bin")) else {
            fatal("Language data missing",
                  """
                  lexicon.bin was not found in the app bundle.

                  Build it with:
                      make lexicon && make bundle
                  """)
            return
        }

        let lexicon: Lexicon
        do {
            lexicon = try LexiconFormat.load(from: lexiconURL)
        } catch {
            fatal("Language data unreadable", "\(lexiconURL.path)\n\n\(error)")
            return
        }

        var config = ScorerConfig()
        config.threshold = settings.threshold
        let engine = CorrectionEngine(pair: layouts.pair,
                                      scorer: Scorer(lexicon: lexicon, config: config))

        Log.app.info("starting: latin=\(layouts.pair.latin.sourceID, privacy: .public) hebrew=\(layouts.pair.hebrew.sourceID, privacy: .public) vocab=\(lexicon.latin.unigrams.count)/\(lexicon.hebrew.unigrams.count) threshold=\(config.threshold)")

        let coordinator = Coordinator(engine: engine, layouts: layouts, settings: settings)
        self.coordinator = coordinator
        self.menuBar = MenuBarController(coordinator: coordinator, settings: settings)

        if coordinator.start() {
            Log.app.info("event tap running")
        } else {
            // The tap could not be created, which in practice always means
            // Accessibility has not been granted. Prompt, then leave the menu
            // bar item in place explaining what is needed.
            Log.app.error("event tap could not be created; Accessibility access is missing")
            Permissions.requestTrust()
            explainMissingPermission()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    // MARK: - Alerts

    private func explainMissingPermission() {
        let alert = NSAlert()
        alert.messageText = "LayoutFix needs Accessibility access"
        alert.informativeText = """
            LayoutFix watches for words typed in the wrong keyboard layout, so \
            macOS requires Accessibility permission before it can see the keyboard.

            Open Privacy & Security > Accessibility, enable LayoutFix, then \
            launch it again.
            """
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    private func fatal(_ title: String, _ detail: String) {
        let alert = NSAlert()
        alert.alertStyle = .critical
        alert.messageText = title
        alert.informativeText = detail
        alert.addButton(withTitle: "Quit")
        alert.runModal()
        NSApp.terminate(nil)
    }
}
