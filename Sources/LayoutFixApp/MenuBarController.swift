import AppKit
import LayoutFixCore

/// The status-bar item and its menu. The app has no windows.
final class MenuBarController: NSObject, NSMenuDelegate {

    private let statusItem: NSStatusItem
    private let coordinator: Coordinator
    private let settings: Settings

    init(coordinator: Coordinator, settings: Settings) {
        self.coordinator = coordinator
        self.settings = settings
        self.statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        refreshIcon()

        coordinator.onStateChange = { [weak self] in self?.refreshIcon() }
    }

    /// Re-read permission state and redraw. Called by the permission poll.
    func refresh() { refreshIcon() }

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let on = settings.isEnabled && coordinator.isRunning && Permissions.state.isComplete
        // Aleph when active, struck through when not: readable at menu-bar size
        // and needs no asset.
        button.title = on ? "א" : "a\u{0338}"
        button.toolTip = on
            ? "LayoutFix: watching for wrong-layout typing"
            : (Permissions.state.isComplete ? "LayoutFix: paused"
                                            : "LayoutFix: permission needed")
    }

    // MARK: - Menu

    /// Build the menu without opening it, for `--demo-menu`.
    func debugMenu() -> NSMenu {
        let menu = NSMenu()
        menuNeedsUpdate(menu)
        return menu
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stats = coordinator.snapshot

        let permissions = Permissions.state
        if !permissions.isComplete {
            add(menu, "Permission needed: \(permissions.missing.joined(separator: ", "))",
                action: nil)
            if !permissions.canListen {
                add(menu, "Open Input Monitoring settings...",
                    action: #selector(openInputMonitoring), target: self)
            }
            if !permissions.canPost {
                add(menu, "Open Accessibility settings...",
                    action: #selector(openSettings), target: self)
            }
            menu.addItem(.separator())
        }

        let toggle = add(menu, settings.isEnabled ? "Pause LayoutFix" : "Resume LayoutFix",
                         action: #selector(toggleEnabled), target: self)
        toggle.isEnabled = coordinator.isRunning

        menu.addItem(.separator())

        add(menu, "Keys seen: \(stats.keyEventsSeen)", action: nil)
        add(menu, "Corrections this session: \(stats.corrections)", action: nil)
        if let last = stats.lastCorrection {
            add(menu, "   \(last.summary)", action: nil)
        }

        // A second route to undo, for when the toast has already gone.
        let undo = add(menu, "Undo Last Correction",
                       action: #selector(undoLast), target: self)
        undo.isEnabled = coordinator.canUndo

        menu.addItem(.separator())

        let learned = settings.learnedExceptions
        if learned.isEmpty {
            add(menu, "No words rejected yet", action: nil)
        } else {
            let item = NSMenuItem(title: "Rejected Words (\(learned.count))",
                                  action: nil, keyEquivalent: "")
            item.submenu = rejectedWordsMenu(learned)
            menu.addItem(item)
        }

        let toastItem = add(menu, "Show Notification on Correction",
                            action: #selector(toggleToast), target: self)
        toastItem.state = settings.showToast ? .on : .off

        menu.addItem(.separator())

        if LoginItem.isAvailable {
            let login = add(menu, "Open at Login",
                            action: #selector(toggleLoginItem), target: self)
            login.state = LoginItem.isRegistered ? .on : .off
        }

        add(menu, "Diagnostics...", action: #selector(showDiagnostics), target: self)

        menu.addItem(.separator())
        add(menu, "Quit LayoutFix", action: #selector(quit), target: self, key: "q")
    }

    @discardableResult
    private func add(_ menu: NSMenu, _ title: String, action: Selector?,
                     target: AnyObject? = nil, key: String = "") -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: key)
        item.target = target
        if action == nil { item.isEnabled = false }
        menu.addItem(item)
        return item
    }

    @objc private func toggleEnabled() {
        coordinator.isEnabled.toggle()
        refreshIcon()
    }

    // MARK: - Rejected words

    /// How many words to list before falling back to "and N more".
    ///
    /// A menu is the right home for a handful of entries and the wrong one for
    /// hundreds; past this the list stops being scannable and Forget All is the
    /// more honest offer.
    private static let maxListedWords = 30

    private func rejectedWordsMenu(_ learned: LearnedExceptions) -> NSMenu {
        let submenu = NSMenu()

        let header = NSMenuItem(title: "Click a word to allow correcting it again",
                                action: nil, keyEquivalent: "")
        header.isEnabled = false
        submenu.addItem(header)
        submenu.addItem(.separator())

        let entries = learned.entries

        // The same characters can be rejected under either layout, which would
        // otherwise show as two identical rows the user cannot choose between.
        // Only label the layout when it is actually needed to tell them apart,
        // so the ordinary case stays uncluttered.
        let duplicated = Dictionary(grouping: entries, by: \.word)
            .filter { $0.value.count > 1 }
            .keys

        for entry in entries.prefix(MenuBarController.maxListedWords) {
            let title = duplicated.contains(entry.word)
                ? "\(entry.word)  (\(entry.script == .latin ? "English" : "Hebrew") layout)"
                : entry.word
            let item = NSMenuItem(title: title,
                                  action: #selector(unrejectWord(_:)), keyEquivalent: "")
            item.target = self
            // Carry the storage key, not just the word: it is what identifies
            // which of the two to remove.
            item.representedObject = entry.storageKey
            submenu.addItem(item)
        }

        if entries.count > MenuBarController.maxListedWords {
            let more = NSMenuItem(
                title: "and \(entries.count - MenuBarController.maxListedWords) more...",
                action: nil, keyEquivalent: "")
            more.isEnabled = false
            submenu.addItem(more)
        }

        submenu.addItem(.separator())
        let forget = NSMenuItem(title: "Forget All Rejected Words...",
                                action: #selector(forgetLearned), keyEquivalent: "")
        forget.target = self
        submenu.addItem(forget)
        return submenu
    }

    /// Un-reject a single word. Applied immediately and without confirmation:
    /// it undoes nothing destructive, and rejecting again is one click away.
    @objc private func unrejectWord(_ sender: NSMenuItem) {
        guard let key = sender.representedObject as? String else { return }
        var learned = settings.learnedExceptions
        learned.remove(storageKey: key)
        settings.learnedExceptions = learned
        coordinator.reloadExceptions()
    }

    @objc private func undoLast() {
        coordinator.undoLastCorrection()
    }

    @objc private func toggleToast() {
        settings.showToast.toggle()
    }

    /// Clearing is explicit and confirmed: the list is the only durable trace
    /// of anything typed, so the user should be able to see the size of what
    /// they are discarding before it goes.
    @objc private func forgetLearned() {
        let learned = settings.learnedExceptions
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Forget \(learned.count) rejected word(s)?"
        alert.informativeText = """
            LayoutFix will start correcting these words again if it thinks they \
            were typed in the wrong layout.

            \(learned.descriptions.prefix(12).joined(separator: ", "))\
            \(learned.count > 12 ? ", ..." : "")
            """
        alert.addButton(withTitle: "Forget")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        settings.learnedExceptions = LearnedExceptions()
        coordinator.reloadExceptions()
    }

    @objc private func toggleLoginItem() {
        LoginItem.setRegistered(!LoginItem.isRegistered)
    }

    /// Runs the same checks as `--diagnose` and shows them in an alert, since a
    /// menu-bar app has no console the user can read.
    @objc private func showDiagnostics() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "LayoutFix diagnostics"
        alert.informativeText = Diagnose.summary()
        alert.addButton(withTitle: "OK")
        if !Permissions.state.isComplete {
            alert.addButton(withTitle: "Open Settings")
        }
        if alert.runModal() == .alertSecondButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc private func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func openInputMonitoring() {
        Permissions.openInputMonitoringSettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
