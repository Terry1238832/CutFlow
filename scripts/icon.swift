import AppKit

let destination = CommandLine.arguments[1]
try FileManager.default.createDirectory(atPath: destination, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                  bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                  isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
        let p = CGFloat(pixels)
        let rect = NSRect(x: p * 0.075, y: p * 0.075, width: p * 0.85, height: p * 0.85)
        let path = NSBezierPath(roundedRect: rect, xRadius: p * 0.20, yRadius: p * 0.20)
        NSGradient(starting: NSColor(red: 0.52, green: 0.41, blue: 1, alpha: 1),
                   ending: NSColor(red: 0.28, green: 0.23, blue: 0.75, alpha: 1))!.draw(in: path, angle: -70)
        let config = NSImage.SymbolConfiguration(pointSize: p * 0.43, weight: .medium)
            .applying(NSImage.SymbolConfiguration(paletteColors: [.white]))
        if let symbol = NSImage(systemSymbolName: "scissors", accessibilityDescription: nil)?.withSymbolConfiguration(config) {
            symbol.draw(in: NSRect(x: p * 0.25, y: p * 0.25, width: p * 0.50, height: p * 0.50))
        }
        NSGraphicsContext.restoreGraphicsState()
        let suffix = scale == 2 ? "@2x" : ""
        try rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: "\(destination)/icon_\(size)x\(size)\(suffix).png"))
    }
}

// ICNS permits PNG payloads for modern icon representations. Write the container
// directly so building also works where iconutil's image service is unavailable.
func word(_ value: UInt32) -> Data {
    var big = value.bigEndian
    return withUnsafeBytes(of: &big) { Data($0) }
}
let representations = [
    ("icp4", "icon_16x16.png"), ("icp5", "icon_32x32.png"),
    ("icp6", "icon_32x32@2x.png"), ("ic07", "icon_128x128.png"),
    ("ic08", "icon_256x256.png"), ("ic09", "icon_512x512.png"),
    ("ic10", "icon_512x512@2x.png"), ("ic11", "icon_16x16@2x.png"),
    ("ic12", "icon_32x32@2x.png"), ("ic13", "icon_128x128@2x.png"),
    ("ic14", "icon_256x256@2x.png")
]
var body = Data()
for (type, name) in representations {
    let png = try Data(contentsOf: URL(fileURLWithPath: "\(destination)/\(name)"))
    body.append(Data(type.utf8)); body.append(word(UInt32(png.count + 8))); body.append(png)
}
var container = Data("icns".utf8)
container.append(word(UInt32(body.count + 8))); container.append(body)
try container.write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
