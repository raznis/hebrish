import AppKit
import Carbon.HIToolbox

/// A system-wide keyboard shortcut, via the Carbon hot-key API.
///
/// This has to be a real registered hot key rather than something spotted in
/// our event tap: the tap is listen-only, so it cannot *consume* a keypress.
/// Detecting the shortcut there would fire the action *and* let the keystroke
/// through, so undoing a correction would also type a stray character.
/// `RegisterEventHotKey` swallows the combination properly.
final class HotKey {
    typealias Action = () -> Void

    /// Live registrations, keyed by the id handed to Carbon. The C callback
    /// gets no context pointer worth trusting, so the lookup goes through here.
    private static var actions: [UInt32: Action] = [:]
    private static var nextID: UInt32 = 1
    private static var sharedHandler: EventHandlerRef?

    let keyCode: UInt32
    let carbonModifiers: UInt32

    private let id: UInt32
    private var reference: EventHotKeyRef?

    /// - Returns: nil if the combination is already taken by another app, in
    ///   which case the caller should say so rather than pretend it registered.
    init?(keyCode: UInt32, carbonModifiers: UInt32, action: @escaping Action) {
        self.keyCode = keyCode
        self.carbonModifiers = carbonModifiers
        HotKey.installSharedHandler()

        id = HotKey.nextID
        HotKey.nextID += 1
        HotKey.actions[id] = action

        let hotKeyID = EventHotKeyID(signature: OSType(0x4C46_5831), id: id)  // 'LFX1'
        let status = RegisterEventHotKey(keyCode, carbonModifiers, hotKeyID,
                                         GetApplicationEventTarget(), 0, &reference)
        guard status == noErr, reference != nil else {
            HotKey.actions[id] = nil
            return nil
        }
    }

    deinit {
        if let reference { UnregisterEventHotKey(reference) }
        HotKey.actions[id] = nil
    }

    /// True when a tap-observed key event is this shortcut.
    ///
    /// Needed because the tap still sees the keystroke even though Carbon
    /// consumes it, and the undo shortcut must not be mistaken for typing that
    /// invalidates the very correction it is meant to undo.
    func matches(keycode: UInt16, flags: CGEventFlags) -> Bool {
        guard UInt32(keycode) == keyCode else { return false }
        var wanted: CGEventFlags = []
        if carbonModifiers & UInt32(cmdKey) != 0 { wanted.insert(.maskCommand) }
        if carbonModifiers & UInt32(optionKey) != 0 { wanted.insert(.maskAlternate) }
        if carbonModifiers & UInt32(controlKey) != 0 { wanted.insert(.maskControl) }
        if carbonModifiers & UInt32(shiftKey) != 0 { wanted.insert(.maskShift) }
        let relevant: CGEventFlags = [.maskCommand, .maskAlternate, .maskControl, .maskShift]
        return flags.intersection(relevant) == wanted
    }

    private static func installSharedHandler() {
        guard sharedHandler == nil else { return }
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                 eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            guard let event else { return noErr }
            var hotKeyID = EventHotKeyID()
            let status = GetEventParameter(event, EventParamName(kEventParamDirectObject),
                                           EventParamType(typeEventHotKeyID), nil,
                                           MemoryLayout<EventHotKeyID>.size, nil, &hotKeyID)
            guard status == noErr else { return noErr }
            HotKey.actions[hotKeyID.id]?()
            return noErr
        }, 1, &spec, nil, &sharedHandler)
    }
}

extension HotKey {
    /// The undo shortcut: Command-Option-Z.
    ///
    /// Deliberately not plain Command-Z. Taking that would shadow every app's
    /// own undo, which is far more valuable than this one.
    static let undoKeyCode = UInt32(kVK_ANSI_Z)
    static let undoModifiers = UInt32(cmdKey | optionKey)
    static let undoDisplayName = "⌘⌥Z"
}
