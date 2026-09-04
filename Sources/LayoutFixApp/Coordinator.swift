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
        /// Count only -- never which keys. Proves the tap is actually
        /// delivering events, which is otherwise invisible: a tap can be
        /// created successfully and still receive nothing if the Input
        /// Monitoring grant is missing.
        var keyEventsSeen = 0
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

    // MARK: Undo state
    //
    // A correction stays undoable while we can still be certain where its text
    // is on screen. That means: the user may keep typing (we track what they
    // add, so undo can reach back over it), but anything that could have moved
    // the caret by other means gives up rather than risk deleting the wrong
    // characters. A wrong undo would be worse than no undo.

    /// The correction that Undo would reverse, or nil if none is safe.
    private var _undoable: Correction?
    /// Keys typed since that correction, so undo can reach back past them.
    private var _typedSince: [KeyStroke] = []
    /// Beyond this much new typing, give up rather than reconstruct it.
    private let maxTypedSinceUndo = 48
    /// Where the toast is on screen, so a click on it is not mistaken for the
    /// user moving the caret.
    private var _toastFrame: CGRect?

    private let toast = ToastWindow()
    private var undoHotKey: HotKey?
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

        engine.exceptions = settings.learnedExceptions

        toast.onFrameChange = { [weak self] frame in
            guard let self else { return }
            self.stateLock.lock()
            self._toastFrame = frame
            self.stateLock.unlock()
        }

        // The button on the toast is the primary way to undo; this is the
        // keyboard alternative for anyone who would rather not reach for the
        // mouse. Registering can fail if another app already owns the
        // combination, which is not worth failing startup over.
        undoHotKey = HotKey(keyCode: HotKey.undoKeyCode,
                            carbonModifiers: HotKey.undoModifiers) { [weak self] in
            self?.undoLastCorrection()
        }
        if undoHotKey == nil {
            Log.app.info("undo shortcut unavailable (already registered by another app)")
        }
        return true
    }

    func stop() {
        tap.stop()
        undoHotKey = nil
        observers.forEach { NotificationCenter.default.removeObserver($0) }
        observers.removeAll()
    }

    // MARK: - Undo

    /// Whether there is a correction that can still be safely reversed.
    var canUndo: Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        return _undoable != nil
    }

    /// Reverse the last correction and remember never to make it again.
    ///
    /// Safe to call from anywhere; the work happens on the tap queue so it
    /// serialises with corrections rather than racing them.
    func undoLastCorrection() {
        tap.queue.async { [weak self] in self?.performUndo() }
    }

    private func performUndo() {
        stateLock.lock()
        let correction = _undoable
        let typedSince = _typedSince
        _undoable = nil
        _typedSince = []
        stateLock.unlock()

        guard let correction else { return }

        // Undo has to remove what we inserted *plus* anything typed since, then
        // put both back the way the user had them.
        let sinceText = engine.pair.produced(typedSince, activeScript: correction.switchTo)
        let reversal = Correction(
            deleteCount: correction.replacement.count + sinceText.count,
            replacement: correction.original + sinceText,
            switchTo: correction.switchFrom,
            switchFrom: correction.switchTo,
            original: correction.replacement + sinceText,
            wordCount: correction.wordCount,
            convertedTokens: correction.convertedTokens)

        Log.engine.info("undoing \(correction.wordCount, privacy: .public) word(s), \(typedSince.count, privacy: .public) key(s) typed since")

        injector.apply(reversal)

        // The user has told us this was wrong. Remember it, so the same word is
        // never converted again -- an undo that has to be repeated daily is not
        // really an undo.
        engine.learnRejection(of: correction)
        let learned = engine.exceptions
        engine.reset(.manual)

        stateLock.lock()
        _stats.corrections = max(0, _stats.corrections - 1)
        _stats.lastCorrection = nil
        _activeScript = correction.switchFrom
        _activeScriptIsKnown = true
        stateLock.unlock()

        let rejected = correction.convertedTokens.joined(separator: " ")
        DispatchQueue.main.async {
            self.settings.learnedExceptions = learned
            self.switcher.select(correction.switchFrom)
            if self.settings.showToast {
                self.toast.show(message: "Reverted to “\(correction.original.trimmed)”",
                                hint: rejected.isEmpty ? nil
                                    : "“\(rejected)” will not be corrected again")
            }
            self.onStateChange?()
        }
    }

    /// Re-read the rejected-word list from settings, after the user edits it.
    func reloadExceptions() {
        let stored = settings.learnedExceptions
        tap.queue.async { self.engine.exceptions = stored }
    }

    /// Give up on undoing: we can no longer be sure where the text is.
    private func invalidateUndo() {
        stateLock.lock()
        let had = _undoable != nil
        _undoable = nil
        _typedSince = []
        stateLock.unlock()
        if had {
            DispatchQueue.main.async {
                self.toast.dismiss()
                self.onStateChange?()
            }
        }
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
            invalidateUndo()

        case .mouseClick(let location):
            // A click on our own toast is the user reaching for Undo, not
            // moving the caret. Treating it as an interrupt would throw away
            // the correction they are trying to reject.
            if isOnToast(location) { return }
            engine.reset(.mouseClick)
            invalidateUndo()

        case .keyDown(let keycode, let shift, let chord):
            noteKeyEventSeen()
            // A password field has taken the keyboard. Do not look at, buffer,
            // or act on anything while that is true.
            if Permissions.isSecureInputEnabled {
                engine.reset(.secureInput)
                invalidateUndo()
                return
            }
            // The global flag above misses web password fields and most
            // Electron ones, so also ask what kind of field has focus.
            if let field = FocusedField.inspect() {
                noteFieldKind(field)
                if field.isSecure {
                    engine.reset(.secureField)
                    invalidateUndo()
                    return
                }
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
                invalidateUndo()
                return
            }

            trackForUndo(keycode: keycode, shift: shift, chord: chord, script: script)

            guard let correction = engine.handleKeyDown(
                keycode: keycode, shift: shift,
                hasCommandControlOrOption: chord,
                activeScript: script,
                timestamp: ProcessInfo.processInfo.systemUptime) else { return }

            apply(correction)
        }
    }

    private func isOnToast(_ location: CGPoint) -> Bool {
        stateLock.lock(); defer { stateLock.unlock() }
        guard let frame = _toastFrame else { return false }
        return frame.contains(location)
    }

    /// Keep undo viable while the user carries on typing.
    ///
    /// Ordinary typing is recorded so undo can reach back past it. Anything
    /// that could have moved the caret another way -- arrows, backspace, a
    /// command chord -- gives undo up instead, because reconstructing the text
    /// after that is guesswork. The undo shortcut itself is exempt: the tap
    /// still sees it even though Carbon consumes it, and it must not invalidate
    /// the correction it exists to reverse.
    private func trackForUndo(keycode: UInt16, shift: Bool, chord: Bool, script: Script) {
        stateLock.lock()
        guard _undoable != nil else { stateLock.unlock(); return }
        stateLock.unlock()

        if chord {
            if let hotKey = undoHotKey,
               hotKey.matches(keycode: keycode, flags: currentModifierFlags()) {
                return
            }
            invalidateUndo()
            return
        }
        if VK.navigation.contains(keycode) || keycode == VK.delete {
            invalidateUndo()
            return
        }
        guard engine.pair.table(for: script).char(for: KeyStroke(keycode: keycode, shift: shift)) != nil
        else { return }

        stateLock.lock()
        _typedSince.append(KeyStroke(keycode: keycode, shift: shift))
        let tooMuch = _typedSince.count > maxTypedSinceUndo
        stateLock.unlock()
        if tooMuch { invalidateUndo() }
    }

    /// The live modifier state, for matching the undo shortcut.
    private func currentModifierFlags() -> CGEventFlags {
        CGEventFlags(rawValue: UInt64(NSEvent.modifierFlags.rawValue))
    }

    /// Field kinds already reported. Tap queue only, so no lock needed.
    private var seenFieldKinds: Set<String> = []

    /// Record each distinct kind of field once, to find out what real apps
    /// actually expose -- Safari, Chrome and Electron apps all differ, and
    /// whether they report a secure subrole decides how much of the password
    /// gap this really closes.
    ///
    /// Structural identifiers and the app's bundle id only. Never field
    /// contents, and never the field's label, which can itself be revealing.
    private func noteFieldKind(_ field: FocusedField.Info) {
        let bundleID = frontmostBundleID ?? "?"
        let key = "\(bundleID) \(field.identity)"
        guard !seenFieldKinds.contains(key) else { return }
        seenFieldKinds.insert(key)
        Log.tap.info("field kind: \(key, privacy: .public)\(field.isSecure ? " [SECURE - standing down]" : "")")
    }

    /// Aggregate only, logged occasionally, so "is the tap alive?" is
    /// answerable without ever recording what was typed.
    private func noteKeyEventSeen() {
        stateLock.lock()
        _stats.keyEventsSeen += 1
        let total = _stats.keyEventsSeen
        stateLock.unlock()
        if total == 1 || total % 100 == 0 {
            Log.tap.info("tap alive: \(total, privacy: .public) key events delivered")
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
        _undoable = correction
        _typedSince = []
        stateLock.unlock()

        DispatchQueue.main.async {
            // TIS on the main thread. Deliberately async rather than sync --
            // main may be inside a menu update, and a sync hop would deadlock.
            // The text is already delivered; the input source only affects keys
            // typed from here on.
            self.switcher.select(correction.switchTo)
            if self.settings.showToast {
                self.toast.show(message: correction.summary,
                                hint: self.undoHotKey == nil ? nil
                                    : "or press \(HotKey.undoDisplayName)",
                                onUndo: { [weak self] in self?.undoLastCorrection() })
            }
            self.onStateChange?()
        }
    }
}

extension Correction {
    /// One-line "what changed", for the toast and the menu.
    var summary: String {
        "\(original.trimmed)  →  \(replacement.trimmed)"
    }
}

extension String {
    var trimmed: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
