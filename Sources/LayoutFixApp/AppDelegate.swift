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

        // Check permission before starting, not after. CGEvent.tapCreate
        // succeeds without Input Monitoring and then delivers nothing, so
        // "the tap was created" is not evidence that anything works.
        let permissions = Permissions.state
        Log.app.info("permissions: listen=\(permissions.canListen, privacy: .public) post=\(permissions.canPost, privacy: .public)")

        if coordinator.start() {
            Log.app.info("event tap running")
        } else {
            Log.app.error("event tap could not be created")
        }

        if !permissions.isComplete {
            Permissions.request(permissions)
            explainMissingPermissions(permissions)
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        coordinator?.stop()
    }

    // MARK: - Alerts

    private func explainMissingPermissions(_ state: Permissions.State) {
        let alert = NSAlert()
        alert.messageText = "LayoutFix needs permission: \(state.missing.joined(separator: " and "))"
        alert.informativeText = """
            LayoutFix needs two separate permissions, in two different lists in \
            System Settings > Privacy & Security:

              Input Monitoring  - to notice a word typed in the wrong layout
              Accessibility     - to replace it

            Enable LayoutFix under \(state.missing.joined(separator: " and ")), \
            then quit and launch it again.
            """
        if !state.canListen { alert.addButton(withTitle: "Open Input Monitoring") }
        if !state.canPost { alert.addButton(withTitle: "Open Accessibility") }
        alert.addButton(withTitle: "Later")

        switch alert.runModal() {
        case .alertFirstButtonReturn:
            if state.canListen { Permissions.openAccessibilitySettings() }
            else { Permissions.openInputMonitoringSettings() }
        case .alertSecondButtonReturn where !state.canListen && !state.canPost:
            Permissions.openAccessibilitySettings()
        default:
            break
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
