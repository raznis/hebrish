import Foundation
import Carbon.HIToolbox
import LayoutFixCore

/// Selects a keyboard input source, and reports which one is live.
final class InputSourceSwitcher {
    private let layouts: SystemLayouts

    init(layouts: SystemLayouts) {
        self.layouts = layouts
    }

    /// Script of the live input source. Falls back to Latin when the live
    /// source is neither of ours (a third language, or an IME) -- callers
    /// should check `isKnownScript` before acting.
    var currentScript: Script {
        SystemLayouts.currentScript() ?? .latin
    }

    var isKnownScript: Bool {
        SystemLayouts.currentScript() != nil
    }

    @discardableResult
    func select(_ script: Script) -> Bool {
        let status = TISSelectInputSource(layouts.source(for: script))
        return status == noErr
    }
}
