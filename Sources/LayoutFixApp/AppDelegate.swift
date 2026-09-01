import AppKit
import LayoutFixCore

final class AppDelegate: NSObject, NSApplicationDelegate {

    private var coordinator: Coordinator?
    private var menuBar: MenuBarController?
    private let settings = Settings()

    /// Polls for permission grants while any are missing.
    private var permissionTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Refuse to be the second copy. Two bundles with the same identifier
        // running from different paths make the Privacy & Security lists
        // ambiguous -- the user grants one entry and the other stays deaf.
        if let other = otherRunningInstance() {
            fatal("LayoutFix is already running",
                  """
                  Another copy is running from:
                    \(other)

                  Quit that one first. Running two copies with the same bundle \
                  identifier makes the Input Monitoring and Accessibility lists \
                  ambiguous, so a permission granted to one may not apply to the \
                  other.
                  """)
            return
        }

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
            watchForPermissionGrant()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        permissionTimer?.invalidate()
        coordinator?.stop()
    }

    // MARK: - Waiting for the user to grant

    /// Both grants only take effect for a tap created *after* they are given,
    /// so the app has to restart. Watch for the change and offer to do it,
    /// rather than leaving a permanently deaf menu-bar icon behind.
    private func watchForPermissionGrant() {
        permissionTimer?.invalidate()
        permissionTimer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { [weak self] timer in
            guard let self else { return }
            self.menuBar?.refresh()
            guard Permissions.state.isComplete else { return }
            timer.invalidate()
            self.permissionTimer = nil
            Log.app.info("permissions granted; relaunching to pick them up")
            self.offerRelaunch()
        }
    }

    private func offerRelaunch() {
        let alert = NSAlert()
        alert.messageText = "Permissions granted"
        alert.informativeText = """
            LayoutFix has to restart to start reading the keyboard, because a \
            tap only picks up the new permissions when it is created.
            """
        alert.addButton(withTitle: "Relaunch")
        alert.addButton(withTitle: "Later")
        activate()
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        relaunch()
    }

    private func relaunch() {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL,
                                           configuration: configuration) { _, _ in
            DispatchQueue.main.async { NSApp.terminate(nil) }
        }
    }

    // MARK: - Alerts

    /// An accessory app's alerts open behind whatever the user is looking at
    /// unless it activates first -- which would make the permission prompt
    /// invisible, the one thing that must not happen.
    private func activate() {
        NSApp.activate(ignoringOtherApps: true)
    }

    /// Another bundle with our identifier, running from a different path.
    private func otherRunningInstance() -> String? {
        guard let identifier = Bundle.main.bundleIdentifier else { return nil }
        let ours = Bundle.main.bundleURL.standardizedFileURL
        return NSWorkspace.shared.runningApplications
            .filter { $0.bundleIdentifier == identifier
                      && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
            .compactMap { $0.bundleURL?.standardizedFileURL }
            .first { $0 != ours }?
            .path
    }

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

        activate()
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
        activate()
        alert.runModal()
        NSApp.terminate(nil)
    }
}
