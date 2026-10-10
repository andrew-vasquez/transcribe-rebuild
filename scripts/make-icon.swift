// Renders the Lento app icon into an .iconset: deep-charcoal squircle with a
// top-light gradient, an amber waveform with rounded caps, a white play line
// with a soft glow, and a subtle top sheen.
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

    // Rounded-square backdrop: deep charcoal with a vertical top-light gradient
    let clip = CGPath(roundedRect: CGRect(x: 0, y: 0, width: s, height: s),
                      cornerWidth: s * 0.225, cornerHeight: s * 0.225, transform: nil)
    ctx.saveGState()
    ctx.addPath(clip)
    ctx.clip()
    let bgColors = [NSColor(calibratedRed: 0.22, green: 0.215, blue: 0.24, alpha: 1).cgColor,
                    NSColor(calibratedRed: 0.10, green: 0.10, blue: 0.12, alpha: 1).cgColor] as CFArray
    let bgGrad = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: bgColors, locations: [0, 1])!
    ctx.drawLinearGradient(bgGrad, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: 0), options: [])

    // Waveform bars (amber, rounded caps), echoing the app's adaptive palette
    ctx.setFillColor(NSColor(calibratedRed: 1.0, green: 0.62, blue: 0.04, alpha: 1).cgColor)
    let barW = s * 0.042
    let gap = s * 0.03
    let heights: [CGFloat] = [0.30, 0.46, 0.66, 0.86, 0.55, 0.40, 0.68, 0.34, 0.52, 0.26, 0.42, 0.18, 0.30]
    var x = s * 0.15
    for h in heights {
        let barH = h * s * 0.6
        let r = barW * 0.45
        let rect = CGRect(x: x, y: (s - barH) / 2, width: barW, height: barH)
        let barPath = CGPath(roundedRect: rect, cornerWidth: r, cornerHeight: r, transform: nil)
        ctx.addPath(barPath)
        ctx.fillPath()
        x += barW + gap
    }

    // Play-position line with a soft white glow
    let px = s * 0.60
    ctx.setShadow(offset: .zero, blur: s * 0.03,
                  color: NSColor(calibratedWhite: 1, alpha: 0.8).cgColor)
    ctx.setFillColor(NSColor(calibratedWhite: 1, alpha: 0.96).cgColor)
    ctx.fill(CGRect(x: px, y: s * 0.13, width: s * 0.011, height: s * 0.74))
    ctx.setShadow(offset: .zero, blur: 0, color: nil)

    // Subtle top sheen (glass-like highlight band)
    let sheenColors = [NSColor(calibratedWhite: 1, alpha: 0.14).cgColor,
                       NSColor(calibratedWhite: 1, alpha: 0.0).cgColor] as CFArray
    let sheen = CGGradient(colorsSpace: CGColorSpaceCreateDeviceRGB(), colors: sheenColors, locations: [0, 1])!
    ctx.saveGState()
    ctx.clip(to: CGRect(x: s * 0.04, y: s * 0.78, width: s * 0.92, height: s * 0.18))
    ctx.drawLinearGradient(sheen, start: CGPoint(x: 0, y: s), end: CGPoint(x: 0, y: s * 0.75), options: [])
    ctx.restoreGState()

    // Inner hairline border for definition on both appearances
    ctx.setStrokeColor(NSColor(calibratedWhite: 1, alpha: 0.12).cgColor)
    ctx.setLineWidth(s * 0.006)
    ctx.addPath(CGPath(roundedRect: CGRect(x: s * 0.004, y: s * 0.004, width: s * 0.992, height: s * 0.992),
                       cornerWidth: s * 0.222, cornerHeight: s * 0.222, transform: nil))
    ctx.strokePath()
    ctx.restoreGState()

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
}
print("icon rendered to \(outDir)")
