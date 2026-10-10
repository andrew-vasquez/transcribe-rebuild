// Renders the app icon (amber waveform on a dark rounded square) into an .iconset.
// Usage: swift scripts/make-icon.swift <output.iconset>
import AppKit
import CoreGraphics

let outDir = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon.iconset"
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)

func render(size: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: size, height: size))
    img.lockFocus()
    let ctx = NSGraphicsContext.current!.cgContext
    let s = CGFloat(size)

    // Dark rounded-square background with a subtle gradient
    let colors = [NSColor(calibratedRed: 0.16, green: 0.16, blue: 0.18, alpha: 1).cgColor,
                  NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).cgColor] as CFArray
    let grad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: colors, locations: [0, 1])!
    let clip = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.addPath(clip)
    ctx.clip()
    ctx.drawLinearGradient(grad, start: .zero, end: CGPoint(x: 0, y: s), options: [])

    // Waveform bars (amber), echoing the app's waveform palette
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).cgColor)
    let barW = s * 0.045
    let gap = s * 0.028
    let heights: [CGFloat] = [0.28, 0.42, 0.62, 0.85, 0.55, 0.38, 0.66, 0.32, 0.5, 0.24, 0.4, 0.18, 0.3]
    var x = s * 0.14
    for h in heights {
        let barH = h * s * 0.6
        ctx.fill(CGRect(x: x, y: (s - barH) / 2, width: barW, height: barH))
        x += barW + gap
    }
    // Play-position line
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.9).cgColor)
    ctx.fill(CGRect(x: s * 0.62, y: s * 0.12, width: s * 0.012, height: s * 0.76))
    img.unlockFocus()
    return img
}

for (px, name) in [(16, "icon_16x16"), (32, "icon_16x16@2x"), (32, "icon_32x32"),
                   (64, "icon_32x32@2x"), (128, "icon_128x128"), (256, "icon_128x128@2x"),
                   (256, "icon_256x256"), (512, "icon_256x256@2x"), (512, "icon_512x512"),
                   (1024, "icon_512x512@2x")] {
    let img = render(size: px)
    let rep = NSBitmapImageRep(data: img.tiffRepresentation!)!
    let png = rep.representation(using: .png, properties: [:])!
    try? png.write(to: URL(fileURLWithPath: "\(outDir)/\(name).png"))
    _ = name
}
print("icon rendered to \(outDir)")
