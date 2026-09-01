import AppKit
import Carbon.HIToolbox
import LayoutFixCore

/// Wires the event tap to the correction engine and applies what it decides.
///
/// Threading: the engine and the injector are touched only on the tap's serial
/// queue. Anything the menu reads lives behind `stateLock` instead, so opening
/// the menu never blocks on the tap queue -- which matters because applying a
/// correction occupies that queue for tens of milliseconds.
///
/// Text Input Services calls are kept on the main thread and their result
/// cached. That is partly caution about Carbon's thread affinity, and partly
/// latency: asking TIS for the live layout on every keystroke would put a
/// Carbon round-trip inside the path that has to stay under the tap deadline.
final class Coordinator {

    struct Stats {
        var corrections = 0
        var lastCorrection: Correction?
    }

    private let engine: CorrectionEngine
    private let tap = KeyTap()
    private let injector = Injector()
    private let switcher: InputSourceSwitcher
    private let settings: Settings

    private let stateLock = NSLock()
    private var _stats = Stats()
    private var _activeScript: Script = .latin
    private var _activeScriptIsKnown = false
    private var _frontmostBundleID: String?

    private var observers: [Any] = []

    /// Called on the main queue after anything the menu displays changes.
    var onStateChange: (() -> Void)?

    init(engine: CorrectionEngine, layouts: SystemLayouts, settings: Settings) {
        self.engine = engine
        self.switcher = InputSourceSwitcher(layouts: layouts)
        self.settings = settings
        self.injector.timing.interKeyDelay = settings.interKeyDelay
        self.engine.scorer.config.threshold = settings.threshold
    }

    var isRunning: Bool { tap.isRunning }

    var snapshot: Stats {
        stateLock.lock(); defer { stateLock.unlock() }
        return _stats
    }

    var isEnabled: Bool {
        get { settings.isEnabled }
        set {
            settings.isEnabled = newValue
            tap.queue.async { self.engine.reset(.manual) }
            onStateChange?()
        }
    }

    @discardableResult
    func start() -> Bool {
        tap.onEvent = { [weak self] event in self?.handle(event) }
        guard tap.start() else { return false }
        refreshActiveScript()
        setFrontmost(NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        installObservers()
        return true
    }

    func stop() {
        tap.stop()
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - Cached system state

    /// Main thread only.
    private func refreshActiveScript() {
        let script = SystemLayouts.currentScript()
        stateLock.lock()
        _activeScript = script ?? .latin
        _activeScriptIsKnown = script != nil
        stateLock.unlock()
    }

    private func setFrontmost(_ bundleID: String?) {
        stateLock.lock()
        _frontmostBundleID = bundleID
        stateLock.unlock()
    }

    private var activeScript: (script: Script, isKnown: Bool) {
        stateLock.lock(); defer { stateLock.unlock() }
        return (_activeScript, _activeScriptIsKnown)
    }

    private var frontmostBundleID: String? {
        stateLock.lock(); defer { stateLock.unlock() }
        return _frontmostBundleID
    }

    // MARK: - Observers

    private func installObservers() {
        let workspace = NSWorkspace.shared.notificationCenter

        // A different app means a different text field: forget the buffer.
        observers.append(workspace.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                self.setFrontmost(app?.bundleIdentifier)
                self.tap.queue.async { self.engine.reset(.focusChange) }
            })

        // A manual layout switch is a deliberate language change. Resetting
        // here is also what stops lookback from ever reaching back across a
        // language the user selected on purpose.
        observers.append(DistributedNotificationCenter.default().addObserver(
            forName: NSNotification.Name(kTISNotifySelectedKeyboardInputSourceChanged as String),
            object: nil, queue: .main) { [weak self] _ in
                guard let self else { return }
                self.refreshActiveScript()
                self.tap.queue.async { self.engine.reset(.inputSourceChange) }
            })
    }

    // MARK: - The decision path (tap queue)

    private func handle(_ event: KeyTap.Event) {
        switch event {
        case .interrupt(let reason):
            Log.tap.debug("reset: \(reason.rawValue, privacy: .public)")
            engine.reset(reason)

        case .keyDown(let keycode, let shift, let chord):
            // A password field has taken the keyboard. Do not look at, buffer,
            // or act on anything while that is true.
            if Permissions.isSecureInputEnabled {
                engine.reset(.secureInput)
                return
            }
            guard settings.isEnabled else { return }
            if let bundleID = frontmostBundleID, settings.deniedBundleIDs.contains(bundleID) {
                engine.reset(.manual)
                return
            }
            // A third language or an IME is live: neither of our readings applies.
            let (script, isKnown) = activeScript
            guard isKnown else {
                engine.reset(.inputSourceChange)
                return
            }

            guard let correction = engine.handleKeyDown(
                keycode: keycode, shift: shift,
                hasCommandControlOrOption: chord,
                activeScript: script,
                timestamp: ProcessInfo.processInfo.systemUptime) else { return }

            apply(correction)
        }
    }

    /// Tap queue. Blocks for the duration of the injection, which is deliberate:
    /// subsequent keystrokes queue behind it rather than interleaving.
    private func apply(_ correction: Correction) {
        // Typed text only ever at debug level, and marked private so it is
        // redacted in system logs by default.
        Log.engine.debug("correcting \(correction.wordCount) word(s) -> \(correction.switchTo.rawValue, privacy: .public): '\(correction.original, privacy: .private)' -> '\(correction.replacement, privacy: .private)'")
        injector.apply(correction)

        stateLock.lock()
        _stats.corrections += 1
        _stats.lastCorrection = correction
        _activeScript = correction.switchTo
        _activeScriptIsKnown = true
        stateLock.unlock()

        DispatchQueue.main.async {
            // TIS on the main thread. Deliberately async rather than sync --
            // main may be inside a menu update, and a sync hop would deadlock.
            // The text is already delivered; the input source only affects keys
            // typed from here on.
            self.switcher.select(correction.switchTo)
            self.onStateChange?()
        }
    }
}
