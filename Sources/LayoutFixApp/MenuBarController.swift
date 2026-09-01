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

    private func refreshIcon() {
        guard let button = statusItem.button else { return }
        let on = settings.isEnabled && coordinator.isRunning
        // Aleph when active, struck through when not: readable at menu-bar size
        // and needs no asset.
        button.title = on ? "א" : "a\u{0338}"
        button.toolTip = on
            ? "LayoutFix: watching for wrong-layout typing"
            : "LayoutFix: paused"
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let stats = coordinator.snapshot

        if !coordinator.isRunning {
            add(menu, "Accessibility access needed", action: nil)
            add(menu, "Open Privacy & Security settings...",
                action: #selector(openSettings), target: self)
            menu.addItem(.separator())
        }

        let toggle = add(menu, settings.isEnabled ? "Pause LayoutFix" : "Resume LayoutFix",
                         action: #selector(toggleEnabled), target: self)
        toggle.isEnabled = coordinator.isRunning

        menu.addItem(.separator())

        add(menu, "Corrections this session: \(stats.corrections)", action: nil)
        if let last = stats.lastCorrection {
            let from = last.original.trimmingCharacters(in: .whitespacesAndNewlines)
            let to = last.replacement.trimmingCharacters(in: .whitespacesAndNewlines)
            add(menu, "   \(from)  ->  \(to)", action: nil)
        }

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

    @objc private func toggleLoginItem() {
        LoginItem.setRegistered(!LoginItem.isRegistered)
    }

    /// Runs the same checks as `--diagnose` and shows them in an alert, since a
    /// menu-bar app has no console the user can read.
    @objc private func showDiagnostics() {
        let alert = NSAlert()
        alert.messageText = "LayoutFix diagnostics"
        alert.informativeText = Diagnose.summary()
        alert.addButton(withTitle: "OK")
        if !Permissions.isTrusted {
            alert.addButton(withTitle: "Open Settings")
        }
        if alert.runModal() == .alertSecondButtonReturn {
            Permissions.openAccessibilitySettings()
        }
    }

    @objc private func openSettings() {
        Permissions.openAccessibilitySettings()
    }

    @objc private func quit() {
        NSApp.terminate(nil)
    }
}
