import AppKit

if CommandLine.arguments.contains("--diagnose") {
    Diagnose.run()
}

if CommandLine.arguments.contains("--demo-toast") {
    DemoToast.run()
}

if CommandLine.arguments.contains("--demo-menu") {
    DemoMenu.run()
}

if let i = CommandLine.arguments.firstIndex(of: "--dump-icon"),
   i + 1 < CommandLine.arguments.count {
    DumpIcon.run(path: CommandLine.arguments[i + 1])
}

// A menu-bar agent: no Dock icon, no main window. LSUIElement in Info.plist
// covers the bundled case; setting the policy here covers running the binary
// directly during development.
let application = NSApplication.shared
application.setActivationPolicy(.accessory)

let delegate = AppDelegate()
application.delegate = delegate
application.run()
