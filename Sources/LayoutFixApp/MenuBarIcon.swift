import AppKit

/// The menu-bar mark: a lowercase `a` beside an `א`, slightly overlapping.
///
/// Both are x-height letters with no ascender or descender, so they balance
/// without the top-heaviness an uppercase `A` would bring.
///
/// The overlap is small on purpose. A quarter-width overlap looked right when
/// drawn large, but at menu-bar size the alef's diagonal closed up the bowl of
/// the `a` and the whole thing read as a dark blob -- the legibility of small
/// type lives in its counters, the enclosed white shapes. A slight overlap
/// keeps the two letters reading as one mark while leaving those counters open.
///
/// Built as a *template* image, so macOS tints it: black in a light menu bar,
/// white in a dark one, correctly inverted while the menu is open. Drawing text
/// into `button.title` gets none of that.
enum MenuBarIcon {

    struct Style {
        /// Canvas height. 18pt is the conventional menu-bar artwork box; the
        /// glyphs sit well inside it rather than filling it.
        var height: CGFloat = 18
        var letterSize: CGFloat = 12
        var weight: NSFont.Weight = .medium
        /// Negative tracking between the glyphs.
        var overlap: CGFloat = -1.4
        /// Breathing room either side, so the mark is not flush to the edge.
        var padding: CGFloat = 1
    }

    static let standard = Style()

    static func make(_ style: Style = standard) -> NSImage {
        let font = NSFont.systemFont(ofSize: style.letterSize, weight: style.weight)
        let attrs: [NSAttributedString.Key: Any] = [.font: font,
                                                    .foregroundColor: NSColor.black]
        let a = NSAttributedString(string: "a", attributes: attrs)
        let alef = NSAttributedString(string: "א", attributes: attrs)
        let aSize = a.size(), alefSize = alef.size()

        let width = (style.padding * 2 + aSize.width + style.overlap + alefSize.width)
            .rounded(.up)
        let image = NSImage(size: NSSize(width: width, height: style.height))
        image.lockFocus()
        let baseline = (style.height - aSize.height) / 2
        a.draw(at: NSPoint(x: style.padding, y: baseline))
        alef.draw(at: NSPoint(x: style.padding + aSize.width + style.overlap, y: baseline))
        image.unlockFocus()

        image.isTemplate = true
        return image
    }

    static let template: NSImage = make()
}
