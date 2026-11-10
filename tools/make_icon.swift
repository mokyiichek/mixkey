// Draws the menu-bar icon (template image) and app icon. Usage: swift tools/make_icon.swift <outdir>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "."

func draw(size: CGFloat, template: Bool) -> NSBitmapImageRep {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size), pixelsHigh: Int(size),
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let rect = NSRect(x: 0, y: 0, width: size, height: size)
    let inset = template ? size * 0.06 : size * 0.08
    let box = NSBezierPath(roundedRect: rect.insetBy(dx: inset, dy: inset), xRadius: size * 0.2, yRadius: size * 0.2)
    if template {
        NSColor.black.setStroke(); box.lineWidth = max(1, size * 0.07); box.stroke()
    } else {
        NSColor(calibratedRed: 0.95, green: 0.33, blue: 0.24, alpha: 1).setFill(); box.fill()
    }
    let font = NSFont.systemFont(ofSize: size * (template ? 0.62 : 0.56), weight: .bold)
    let s = NSAttributedString(string: "混", attributes: [.font: font, .foregroundColor: template ? NSColor.black : NSColor.white])
    let sz = s.size()
    s.draw(at: NSPoint(x: (size - sz.width) / 2, y: (size - sz.height) / 2 + size * 0.02))
    NSGraphicsContext.restoreGraphicsState()
    return rep
}

// Menu-bar icon: 16pt @1x and @2x in one TIFF
let tiff = NSImage(size: NSSize(width: 16, height: 16))
tiff.addRepresentation(draw(size: 16, template: true))
let r2 = draw(size: 32, template: true); r2.size = NSSize(width: 16, height: 16)
tiff.addRepresentation(r2)
try! tiff.tiffRepresentation!.write(to: URL(fileURLWithPath: "\(out)/MixKey.tiff"))

// App icon (.iconset -> .icns via iconutil)
let iconset = "\(out)/MixKey.iconset"
try? FileManager.default.createDirectory(atPath: iconset, withIntermediateDirectories: true)
for (name, px) in [("16x16", 16), ("16x16@2x", 32), ("32x32", 32), ("32x32@2x", 64), ("128x128", 128),
                   ("128x128@2x", 256), ("256x256", 256), ("256x256@2x", 512), ("512x512", 512)] {
    let png = draw(size: CGFloat(px), template: false).representation(using: .png, properties: [:])!
    try! png.write(to: URL(fileURLWithPath: "\(iconset)/icon_\(name).png"))
}
print("icons written to \(out)")
