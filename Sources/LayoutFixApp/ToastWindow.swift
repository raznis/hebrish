import AppKit

/// A brief notice of what just changed, with an Undo button.
///
/// A correction the user does not notice is one they cannot judge, so the toast
/// is both the receipt and the way to reject it. Putting Undo here rather than
/// only on a shortcut means the affordance needs no teaching -- it is visible
/// at the moment it is relevant.
///
/// `nonactivatingPanel` carries the whole design: the panel can be clicked
/// *without* the app becoming active, so keyboard focus stays in the text field
/// the user was typing into and the undo edit still lands in the right place.
/// Stealing focus mid-sentence would be worse than any mistake it reports.
///
/// Main thread only. Not marked `@MainActor` on purpose: the Coordinator that
/// drives this manages its own threading with a lock and an explicit serial
/// queue, and dropping one actor into the middle of that buys checking at the
/// cost of hops in a latency-sensitive path. Every call site here is already
/// inside `DispatchQueue.main` or an AppKit action.
final class ToastWindow {

    private var panel: NSPanel?
    private var dismissTask: DispatchWorkItem?

    /// Where the panel currently sits, in Quartz global coordinates (origin
    /// top-left), or nil while hidden. The Coordinator needs this to tell a
    /// click on the Undo button from a click that moved the caret.
    private(set) var quartzFrame: CGRect?

    /// Called when the panel's frame changes, so the Coordinator's cached copy
    /// stays in step.
    var onFrameChange: ((CGRect?) -> Void)?

    /// - Parameters:
    ///   - message: what changed, e.g. "akuo → שלום".
    ///   - hint: secondary line, e.g. the keyboard alternative.
    ///   - onUndo: when non-nil, an Undo button is shown and this runs on click.
    ///   - duration: how long it stays up. Longer when there is something to
    ///     click, since the user has to see it, decide, and reach the mouse.
    func show(message: String, hint: String?,
              onUndo: (() -> Void)? = nil,
              duration: TimeInterval? = nil) {
        dismissTask?.cancel()
        self.undoAction = onUndo

        let panel = existingOrNewPanel()
        configure(panel, message: message, hint: hint, showUndo: onUndo != nil)
        position(panel)
        publishFrame(panel)

        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }

        let task = DispatchWorkItem { [weak self] in self?.dismiss() }
        dismissTask = task
        let visibleFor = duration ?? (onUndo != nil ? 5.0 : 2.6)
        DispatchQueue.main.asyncAfter(deadline: .now() + visibleFor, execute: task)
    }

    func dismiss() {
        dismissTask?.cancel()
        dismissTask = nil
        undoAction = nil
        quartzFrame = nil
        onFrameChange?(nil)
        guard let panel else { return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            panel.animator().alphaValue = 0
        } completionHandler: {
            panel.orderOut(nil)
        }
    }

    // MARK: - Undo button

    private var undoAction: (() -> Void)?

    @objc private func undoClicked() {
        let action = undoAction
        dismiss()
        action?()
    }

    /// Cocoa screen coordinates have their origin bottom-left; Quartz event
    /// locations have theirs top-left on the primary display. Convert once,
    /// here, so the comparison against a click location is apples to apples.
    private func publishFrame(_ panel: NSPanel) {
        guard let primary = NSScreen.screens.first else { return }
        let frame = panel.frame
        let flipped = CGRect(x: frame.minX,
                             y: primary.frame.height - frame.maxY,
                             width: frame.width,
                             height: frame.height)
        // A little slack, so a click just off the edge still counts as "on the
        // toast" rather than as the user moving the caret.
        quartzFrame = flipped.insetBy(dx: -6, dy: -6)
        onFrameChange?(quartzFrame)
    }

    // MARK: - Panel

    private func existingOrNewPanel() -> NSPanel {
        if let panel { return panel }
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 320, height: 64),
                            // nonactivatingPanel is the whole point: shown
                            // without the app ever becoming active.
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: false)
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.level = .statusBar
        // Clickable, but never focus-stealing: see the note above.
        panel.ignoresMouseEvents = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .ignoresCycle,
                                    .fullScreenAuxiliary]
        self.panel = panel
        return panel
    }

    private func configure(_ panel: NSPanel, message: String, hint: String?,
                           showUndo: Bool) {
        let background = NSVisualEffectView()
        background.material = .hudWindow
        background.blendingMode = .behindWindow
        background.state = .active
        background.wantsLayer = true
        background.layer?.cornerRadius = 12
        background.layer?.cornerCurve = .continuous
        background.translatesAutoresizingMaskIntoConstraints = false

        let primary = NSTextField(labelWithString: message)
        primary.font = .systemFont(ofSize: 17, weight: .medium)
        primary.alignment = .center
        // Mixed Hebrew and Latin in one line: pin the base direction so the
        // "->" between them keeps pointing the way it is meant to.
        primary.baseWritingDirection = .leftToRight
        primary.lineBreakMode = .byTruncatingMiddle

        let textStack = NSStackView(views: [primary])
        textStack.orientation = .vertical
        textStack.spacing = 1
        textStack.alignment = .leading

        if let hint {
            let secondary = NSTextField(labelWithString: hint)
            secondary.font = .systemFont(ofSize: 11, weight: .regular)
            secondary.textColor = .secondaryLabelColor
            secondary.alignment = .left
            secondary.baseWritingDirection = .leftToRight
            textStack.addView(secondary, in: .center)
        }

        let stack = NSStackView(views: [textStack])
        stack.orientation = .horizontal
        stack.spacing = 14
        stack.alignment = .centerY
        stack.translatesAutoresizingMaskIntoConstraints = false

        if showUndo {
            let undo = FirstMouseButton(title: "Undo", target: self,
                                        action: #selector(undoClicked))
            undo.bezelStyle = .rounded
            undo.controlSize = .regular
            undo.setContentHuggingPriority(.required, for: .horizontal)
            stack.addView(undo, in: .trailing)
        }

        background.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.centerXAnchor.constraint(equalTo: background.centerXAnchor),
            stack.centerYAnchor.constraint(equalTo: background.centerYAnchor),
            stack.leadingAnchor.constraint(equalTo: background.leadingAnchor, constant: 16),
            stack.trailingAnchor.constraint(equalTo: background.trailingAnchor, constant: -16),
        ])

        panel.contentView = background
        let fitting = stack.fittingSize
        panel.setContentSize(NSSize(width: min(520, max(240, fitting.width + 32)),
                                    height: max(56, fitting.height + 24)))
    }

        /// Bottom-centre of the active screen.
    ///
    /// Not next to the caret: getting the caret rect needs the Accessibility
    /// API and is unreliable across apps, and a toast that sometimes lands in
    /// the wrong place is worse than one that is always somewhere predictable.
    private func position(_ panel: NSPanel) {
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let frame = screen?.visibleFrame else { return }
        let size = panel.frame.size
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2,
                                     y: frame.minY + 96))
    }
}

/// A button that responds to the very first click.
///
/// Clicking an inactive window normally spends that click activating it, and
/// `acceptsFirstMouse` is false by default. This panel deliberately never
/// activates, so without this override the single click a user makes on Undo
/// is swallowed and nothing happens.
private final class FirstMouseButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
