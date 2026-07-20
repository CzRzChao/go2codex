import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("Usage: icon-generator <iconset-directory>\n".utf8))
    exit(1)
}

let outputURL = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)

let variants: [(pixels: Int, name: String)] = [
    (16, "icon_16x16.png"),
    (32, "icon_16x16@2x.png"),
    (32, "icon_32x32.png"),
    (64, "icon_32x32@2x.png"),
    (128, "icon_128x128.png"),
    (256, "icon_128x128@2x.png"),
    (256, "icon_256x256.png"),
    (512, "icon_256x256@2x.png"),
    (512, "icon_512x512.png"),
    (1024, "icon_512x512@2x.png")
]

for variant in variants {
    let pixels = variant.pixels
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: pixels,
        pixelsHigh: pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ), let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        exit(1)
    }

    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: pixels, height: pixels).fill()

    let inset = CGFloat(pixels) * 0.08
    let tile = NSRect(
        x: inset,
        y: inset,
        width: CGFloat(pixels) - inset * 2,
        height: CGFloat(pixels) - inset * 2
    )
    let path = NSBezierPath(
        roundedRect: tile,
        xRadius: CGFloat(pixels) * 0.20,
        yRadius: CGFloat(pixels) * 0.20
    )
    NSColor(calibratedWhite: 0.12, alpha: 1).setFill()
    path.fill()

    let text = ">_" as NSString
    let font = NSFont.monospacedSystemFont(ofSize: CGFloat(pixels) * 0.36, weight: .semibold)
    let attributes: [NSAttributedString.Key: Any] = [
        .font: font,
        .foregroundColor: NSColor(calibratedWhite: 0.96, alpha: 1)
    ]
    let size = text.size(withAttributes: attributes)
    text.draw(
        at: NSPoint(
            x: (CGFloat(pixels) - size.width) / 2,
            y: (CGFloat(pixels) - size.height) / 2
        ),
        withAttributes: attributes
    )
    NSGraphicsContext.restoreGraphicsState()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        exit(1)
    }
    try data.write(to: outputURL.appendingPathComponent(variant.name), options: .atomic)
}
