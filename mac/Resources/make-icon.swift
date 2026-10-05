// Renders AppIcon.icns: blue rounded square with a white display symbol.
import AppKit
let set = "Resources/AppIcon.iconset"
try? FileManager.default.createDirectory(atPath: set, withIntermediateDirectories: true)
for (size, name) in [(16,"16x16"),(32,"16x16@2x"),(32,"32x32"),(64,"32x32@2x"),(128,"128x128"),(256,"128x128@2x"),(256,"256x256"),(512,"256x256@2x"),(512,"512x512"),(1024,"512x512@2x")] {
    let s = CGFloat(size)
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: size, pixelsHigh: size, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let inset = s * 0.1, rect = NSRect(x: inset, y: inset, width: s - 2*inset, height: s - 2*inset)
    NSGradient(starting: NSColor(red: 0.18, green: 0.45, blue: 0.95, alpha: 1), ending: NSColor(red: 0.05, green: 0.12, blue: 0.3, alpha: 1))!
        .draw(in: NSBezierPath(roundedRect: rect, xRadius: rect.width * 0.22, yRadius: rect.width * 0.22), angle: -90)
    let cfg = NSImage.SymbolConfiguration(pointSize: s * 0.42, weight: .medium).applying(.init(paletteColors: [.white]))
    if let sym = NSImage(systemSymbolName: "display", accessibilityDescription: nil)?.withSymbolConfiguration(cfg) {
        sym.draw(in: NSRect(x: (s - sym.size.width)/2, y: (s - sym.size.height)/2, width: sym.size.width, height: sym.size.height))
    }
    NSGraphicsContext.current = nil
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(set)/icon_\(name).png"))
}
