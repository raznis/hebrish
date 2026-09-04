import AppKit

/// `LayoutFixApp --demo-toast` shows a sample correction panel and exits.
///
/// Exists so the panel can be checked -- appearance, bidirectional text, and
/// above all that it does not steal keyboard focus -- without needing the two
/// TCC grants that everything else about the app depends on.
enum DemoToast {

    static func run() -> Never {
        // Unbuffered, so the diagnostics land even while the app keeps running.
        setbuf(stdout, nil)
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let toast = ToastWindow()
        let delegate = DemoDelegate(toast: toast)
        application.delegate = delegate
        application.run()
        exit(0)
    }

    private final class DemoDelegate: NSObject, NSApplicationDelegate {
        let toast: ToastWindow
        init(toast: ToastWindow) { self.toast = toast }

        func applicationDidFinishLaunching(_ notification: Notification) {
            // A mixed-direction sample, which is the layout case most likely to
            // render wrongly.
            toast.show(message: "akuo  →  שלום",
                       hint: "or press \(HotKey.undoDisplayName)",
                       onUndo: {
                           print("UNDO CLICKED")
                           exit(0)
                       },
                       duration: 20)

            for (i, screen) in NSScreen.screens.enumerated() {
                print("screen[\(i)] frame=\(screen.frame) visible=\(screen.visibleFrame)")
            }
            print("NSScreen.main frame: \(NSScreen.main?.frame.debugDescription ?? "nil")")
            if let panel = NSApp.windows.first {
                print("panel cocoa frame: \(panel.frame)")
            }
            let frame = toast.quartzFrame.map {
                "x=\(Int($0.minX)) y=\(Int($0.minY)) w=\(Int($0.width)) h=\(Int($0.height))"
            } ?? "nil"
            print("panel shown, quartz frame: \(frame)")
            print("app is active (must be false): \(NSApp.isActive)")
            print("frontmost app: \(NSWorkspace.shared.frontmostApplication?.localizedName ?? "?")")
            print("windows: \(NSApp.windows.count), visible: \(NSApp.windows.filter(\.isVisible).count)")
            if let panel = NSApp.windows.first {
                print("panel level: \(panel.level.rawValue) (statusBar is \(NSWindow.Level.statusBar.rawValue))")
                print("panel isKeyWindow (must be false): \(panel.isKeyWindow)")
                print("panel canBecomeKey (must be false): \(panel.canBecomeKey)")
                print("panel size: \(Int(panel.frame.width))x\(Int(panel.frame.height))")
                print("panel accepts clicks: \(!panel.ignoresMouseEvents)")
                let buttons = panel.contentView?.subviews
                    .flatMap { $0.subviews }
                    .flatMap { [$0] + $0.subviews }
                    .compactMap { $0 as? NSButton }
                    .map(\.title) ?? []
                print("buttons found: \(buttons)")
                let allButtons = panel.contentView.map { root -> [NSButton] in
                    var found: [NSButton] = []
                    func walk(_ v: NSView) {
                        if let b = v as? NSButton { found.append(b) }
                        v.subviews.forEach(walk)
                    }
                    walk(root)
                    return found
                } ?? []
                for b in allButtons {
                    let inWindow = b.convert(b.bounds, to: nil)
                    let onScreen = panel.convertToScreen(inWindow)
                    let primaryHeight = NSScreen.screens.first?.frame.height ?? 0
                    let quartz = CGRect(x: onScreen.minX,
                                        y: primaryHeight - onScreen.maxY,
                                        width: onScreen.width, height: onScreen.height)
                    print("BUTTON '\(b.title)' cocoa=\(onScreen) quartz-center=\(Int(quartz.midX)),\(Int(quartz.midY))")
                }
            }
            print("waiting 20s -- click Undo to test the button")
        }
    }
}
