// Renders App/AppIcon.icns: a white microphone symbol on a rounded indigo square.
// Run from the repository root: `swift Scripts/make-icon.swift`. The result is committed, so
// this only needs rerunning when the icon itself changes.
import AppKit

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let iconset = FileManager.default.temporaryDirectory.appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func render(pixels: Int) -> Data {
    let rep = NSBitmapImageRep(
        bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
        colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
    )!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let size = CGFloat(pixels)

    // Apple's grid: the tile is 824/1024 of the canvas, corner radius ~22.5% of the tile.
    let inset = size * 100 / 1024
    let tile = NSRect(x: inset, y: inset, width: size - 2 * inset, height: size - 2 * inset)
    let path = NSBezierPath(roundedRect: tile, xRadius: tile.width * 0.225, yRadius: tile.width * 0.225)
    NSGradient(
        starting: NSColor(calibratedRed: 0.40, green: 0.36, blue: 0.95, alpha: 1),
        ending: NSColor(calibratedRed: 0.22, green: 0.18, blue: 0.62, alpha: 1)
    )!.draw(in: path, angle: -90)

    let config = NSImage.SymbolConfiguration(pointSize: tile.width * 0.5, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    let symbol = NSImage(systemSymbolName: "mic.fill", accessibilityDescription: nil)!
        .withSymbolConfiguration(config)!
    let origin = NSPoint(x: tile.midX - symbol.size.width / 2, y: tile.midY - symbol.size.height / 2)
    symbol.draw(at: origin, from: .zero, operation: .sourceOver, fraction: 1)

    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

for points in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let name = scale == 1 ? "icon_\(points)x\(points).png" : "icon_\(points)x\(points)@2x.png"
        try render(pixels: points * scale).write(to: iconset.appendingPathComponent(name))
    }
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", root.appendingPathComponent("App/AppIcon.icns").path]
try iconutil.run()
iconutil.waitUntilExit()
guard iconutil.terminationStatus == 0 else { fatalError("iconutil failed") }
print("готово: App/AppIcon.icns")
