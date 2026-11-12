// Renders SF Symbols as white PNGs for the website's "Works with the rest of macOS" tiles.
//
//     swift Support/Demo/symbols.swift docs/images/symbols bell.badge.fill magnifyingglass …
import AppKit

let arguments = CommandLine.arguments
guard arguments.count > 2 else {
    FileHandle.standardError.write(Data("usage: symbols.swift <folder> <symbol name> …\n".utf8))
    exit(1)
}
let folder = arguments[1]
let side: CGFloat = 96
for name in arguments.dropFirst(2) {
    let config = NSImage.SymbolConfiguration(pointSize: 64, weight: .medium)
        .applying(.init(paletteColors: [.white]))
    guard let image = NSImage(systemSymbolName: name, accessibilityDescription: nil)?.withSymbolConfiguration(config),
          let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(side), pixelsHigh: Int(side),
                                     bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                     colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else {
        print("No symbol named \(name)")
        continue
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    // Fit and center it, with a little room around.
    let scale = min(side / image.size.width, side / image.size.height) * 0.9
    let width = image.size.width * scale, height = image.size.height * scale
    image.draw(in: NSRect(x: (side - width) / 2, y: (side - height) / 2, width: width, height: height))
    NSGraphicsContext.restoreGraphicsState()
    if let png = rep.representation(using: .png, properties: [:]) {
        try png.write(to: URL(fileURLWithPath: folder).appendingPathComponent("\(name).png"))
    }
}
