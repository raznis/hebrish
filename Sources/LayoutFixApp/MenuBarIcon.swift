import AppKit

/// The menu-bar mark: a lowercase `a` and an `א` overlapping by about a
/// quarter, drawn as one shape.
///
/// Both are x-height letters with no ascender or descender, so they balance
/// without the top-heaviness an uppercase `A` would bring. They are left to
/// merge rather than separated by a knockout gap: their outlines are different
/// enough to stay readable at 16pt, and the gap only added visual noise.
///
/// Built as a *template* image, so macOS tints it — black in a light menu bar,
/// white in a dark one, and correctly inverted while the menu is open. Drawing
/// text into `button.title` gets none of that.
enum MenuBarIcon {

    private static let height: CGFloat = 16
    private static let letterSize: CGFloat = 13
    /// Negative tracking between the two glyphs: roughly a quarter of the
    /// alef's width.
    private static let overlap: CGFloat = -2.3

    static let template: NSImage = {
        let font = NSFont.systemFont(ofSize: letterSize, weight: .semibold)
        let a = NSAttributedString(string: "a", attributes: [.font: font,
                                                             .foregroundColor: NSColor.black])
        let alef = NSAttributedString(string: "א", attributes: [.font: font,
                                                                .foregroundColor: NSColor.black])
        let aSize = a.size(), alefSize = alef.size()
        let width = (aSize.width + overlap + alefSize.width).rounded(.up)

        let image = NSImage(size: NSSize(width: width, height: height))
        image.lockFocus()
        let baseline = (height - aSize.height) / 2
        a.draw(at: NSPoint(x: 0, y: baseline))
        alef.draw(at: NSPoint(x: aSize.width + overlap, y: baseline))
        image.unlockFocus()

        // The whole point: let the system colour it for the current menu bar.
        image.isTemplate = true
        return image
    }()
}
