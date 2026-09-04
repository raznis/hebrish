#!/usr/bin/env swift
import AppKit

// Generates App/Hebrish.icns.
//
// The app had no icon at all, which is why Spotlight and Finder showed the
// generic placeholder. Separate artwork from the menu-bar mark: that one is a
// flat template tinted by the system, while an app icon is full colour on a
// rounded-square ground.
//
// Each size is drawn natively rather than downsampled from one large canvas, so
// the 16pt version gets proportionally heavier strokes instead of turning to
// mush.

let sizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]

func drawIcon(px: Int) -> NSBitmapImageRep {
    let s = CGFloat(px)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: px, pixelsHigh: px,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB,
                               bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)

    // macOS icons leave a margin rather than filling the canvas.
    let inset = s * 0.09
    let box = NSRect(x: inset, y: inset, width: s - inset * 2, height: s - inset * 2)
    // Apple's rounded-square corner ratio, near enough at every size.
    let radius = box.width * 0.2237
    let squircle = NSBezierPath(roundedRect: box, xRadius: radius, yRadius: radius)

    NSGradient(colors: [NSColor(srgbRed: 0.36, green: 0.44, blue: 0.94, alpha: 1),
                        NSColor(srgbRed: 0.19, green: 0.22, blue: 0.62, alpha: 1)])?
        .draw(in: squircle, angle: -90)

    // The mark. Heavier at small sizes, where thin strokes disappear.
    let weight: NSFont.Weight = px <= 32 ? .bold : (px <= 128 ? .semibold : .medium)
    let font = NSFont.systemFont(ofSize: box.height * 0.46, weight: weight)
    let attrs: [NSAttributedString.Key: Any] = [.font: font, .foregroundColor: NSColor.white]
    let a = NSAttributedString(string: "a", attributes: attrs)
    let alef = NSAttributedString(string: "א", attributes: attrs)
    let aSize = a.size(), alefSize = alef.size()
    // Proportionally the same slight overlap as the menu-bar mark.
    let overlap = -box.width * 0.028
    let totalW = aSize.width + overlap + alefSize.width
    let x = box.midX - totalW / 2
    let y = box.midY - aSize.height / 2
    a.draw(at: NSPoint(x: x, y: y))
    alef.draw(at: NSPoint(x: x + aSize.width + overlap, y: y))

    NSGraphicsContext.restoreGraphicsState()
    return rep
}

let fm = FileManager.default
let iconset = "App/Hebrish.iconset"
try? fm.removeItem(atPath: iconset)
try fm.createDirectory(atPath: iconset, withIntermediateDirectories: true)

for (name, px) in sizes {
    let data = drawIcon(px: px).representation(using: .png, properties: [:])!
    try data.write(to: URL(fileURLWithPath: "\(iconset)/\(name).png"))
}

let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset, "-o", "App/Hebrish.icns"]
try task.run()
task.waitUntilExit()
guard task.terminationStatus == 0 else {
    print("iconutil failed"); exit(1)
}
try? fm.removeItem(atPath: iconset)
let bytes = (try? fm.attributesOfItem(atPath: "App/Hebrish.icns")[.size] as? Int) ?? 0
print("wrote App/Hebrish.icns (\(bytes) bytes)")
