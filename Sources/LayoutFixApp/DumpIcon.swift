import AppKit

/// `LayoutFixApp --dump-icon <path>` writes the real menu-bar template image to
/// a PNG, at actual size and enlarged, on light and dark grounds.
///
/// Dumping the actual image rather than re-drawing it in a separate tool is the
/// point: a preview that diverges from what ships tells you nothing.
enum DumpIcon {
    /// Candidate styles, rendered through the same code that ships.
    static let candidates: [(String, MenuBarIcon.Style)] = {
        var a = MenuBarIcon.Style()                                        // proposed
        var b = MenuBarIcon.Style(); b.overlap = 0.4                       // touching, no overlap
        var c = MenuBarIcon.Style(); c.letterSize = 12; c.overlap = -1.4   // slightly larger
        var d = MenuBarIcon.Style(); d.weight = .regular; d.letterSize = 12; d.overlap = -1.0
        var e = MenuBarIcon.Style(); e.weight = .semibold; e.letterSize = 13; e.overlap = -2.3
        e.height = 16; e.padding = 0                                       // what shipped
        return [("A  11pt medium, overlap 1.0  (proposed)", a),
                ("B  11pt medium, touching", b),
                ("C  12pt medium, overlap 1.4", c),
                ("D  12pt regular, overlap 1.0", d),
                ("E  13pt semibold, overlap 2.3  (what shipped)", e)]
    }()

    static func run(path: String) -> Never {
        let s: CGFloat = 10
        let rowH: CGFloat = 18 * s + 30
        let sheet = NSImage(size: NSSize(width: 900, height: rowH * CGFloat(candidates.count) + 40))
        sheet.lockFocus()
        NSColor.white.setFill(); NSRect(origin: .zero, size: sheet.size).fill()
        let t: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
            .foregroundColor: NSColor.black]
        NSAttributedString(string: "Hebrish menu-bar mark — rendered by the shipping code. Far left = actual size.",
                           attributes: t).draw(at: NSPoint(x: 14, y: sheet.size.height - 24))

        func tinted(_ icon: NSImage, _ color: NSColor) -> NSImage {
            let out = NSImage(size: icon.size)
            out.lockFocus()
            color.set(); NSRect(origin: .zero, size: icon.size).fill()
            icon.draw(in: NSRect(origin: .zero, size: icon.size),
                      from: .zero, operation: .destinationIn, fraction: 1)
            out.unlockFocus()
            return out
        }

        for (i, (label, style)) in candidates.enumerated() {
            let icon = MenuBarIcon.make(style)
            let y = sheet.size.height - 40 - CGFloat(i + 1) * rowH + 22
            NSAttributedString(string: "\(label)   \(Int(icon.size.width))x\(Int(icon.size.height))pt",
                               attributes: t).draw(at: NSPoint(x: 14, y: y + 18 * s + 2))

            // Actual size, both grounds.
            var a = NSRect(x: 16, y: y + 18 * s / 2 - 9, width: icon.size.width, height: icon.size.height)
            NSColor(white: 0.97, alpha: 1).setFill(); a.insetBy(dx: -6, dy: -3).fill()
            tinted(icon, .black).draw(in: a)
            a = a.offsetBy(dx: icon.size.width + 20, dy: 0)
            NSColor(white: 0.14, alpha: 1).setFill(); a.insetBy(dx: -6, dy: -3).fill()
            tinted(icon, .white).draw(in: a)

            let w = icon.size.width * s, h = icon.size.height * s
            var r = NSRect(x: 200, y: y, width: w, height: h)
            NSColor(white: 0.97, alpha: 1).setFill(); r.insetBy(dx: -12, dy: -6).fill()
            tinted(icon, .black).draw(in: r)
            r = r.offsetBy(dx: w + 60, dy: 0)
            NSColor(white: 0.14, alpha: 1).setFill(); r.insetBy(dx: -12, dy: -6).fill()
            tinted(icon, .white).draw(in: r)
        }
        sheet.unlockFocus()
        let rep = NSBitmapImageRep(data: sheet.tiffRepresentation!)!
        try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
        print("wrote \(path)")
        exit(0)
    }
}
