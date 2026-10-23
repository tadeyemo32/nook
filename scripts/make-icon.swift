import AppKit

let srgb = CGColorSpace(name: CGColorSpace.sRGB)!

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    let r = CGFloat((hex >> 16) & 0xFF), g = CGFloat((hex >> 8) & 0xFF), b = CGFloat(hex & 0xFF)
    return CGColor(srgbRed: r / 255, green: g / 255, blue: b / 255, alpha: alpha)
}

func gradient(_ colors: [CGColor], _ locations: [CGFloat]? = nil) -> CGGradient {
    CGGradient(colorsSpace: srgb, colors: colors as CFArray, locations: locations)!
}

func draw(_ cg: CGContext) {
    let tile = CGPath(roundedRect: CGRect(x: 100, y: 100, width: 824, height: 824),
                      cornerWidth: 185, cornerHeight: 185, transform: nil)

    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -10), blur: 24, color: color(0x000000, 0.3))
    cg.addPath(tile)
    cg.setFillColor(color(0x000000))
    cg.fillPath()
    cg.restoreGState()

    cg.saveGState()
    cg.addPath(tile)
    cg.clip()

    cg.drawLinearGradient(gradient([color(0x1E1550), color(0x6B35D9), color(0xFF5C9D)], [0, 0.55, 1]),
                          start: CGPoint(x: 180, y: 940), end: CGPoint(x: 850, y: 90), options: [])
    let center = CGPoint(x: 512, y: 470)
    cg.drawRadialGradient(gradient([color(0xFF9AD5, 0.4), color(0xFF9AD5, 0)]),
                          startCenter: center, startRadius: 0, endCenter: center, endRadius: 430, options: [])

    let island = CGRect(x: 182, y: 420, width: 660, height: 204)
    let pill = CGPath(roundedRect: island, cornerWidth: 102, cornerHeight: 102, transform: nil)
    cg.saveGState()
    cg.setShadow(offset: CGSize(width: 0, height: -20), blur: 44, color: color(0x000000, 0.55))
    cg.addPath(pill)
    cg.setFillColor(color(0x050507))
    cg.fillPath()
    cg.restoreGState()
    cg.addPath(pill)
    cg.setStrokeColor(color(0xFFFFFF, 0.1))
    cg.setLineWidth(3)
    cg.strokePath()

    let art = CGRect(x: 236, y: 462, width: 120, height: 120)
    cg.saveGState()
    cg.addPath(CGPath(roundedRect: art, cornerWidth: 30, cornerHeight: 30, transform: nil))
    cg.clip()
    cg.drawLinearGradient(gradient([color(0xFFC54D), color(0xFF4F8B)]),
                          start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
    cg.restoreGState()
    if let note = NSImage(systemSymbolName: "music.note", accessibilityDescription: nil)?
        .withSymbolConfiguration(.init(pointSize: 72, weight: .bold).applying(.init(paletteColors: [.white]))) {
        let size = note.size
        note.draw(in: CGRect(x: art.midX - size.width / 2, y: art.midY - size.height / 2,
                             width: size.width, height: size.height))
    }

    let heights: [CGFloat] = [64, 118, 150, 96, 132]
    let barWidth: CGFloat = 22, gap: CGFloat = 16
    var x = island.maxX - 60 - CGFloat(heights.count) * (barWidth + gap) + gap
    for h in heights {
        cg.addPath(CGPath(roundedRect: CGRect(x: x, y: island.midY - h / 2, width: barWidth, height: h),
                          cornerWidth: barWidth / 2, cornerHeight: barWidth / 2, transform: nil))
        x += barWidth + gap
    }
    cg.setFillColor(color(0xFFFFFF))
    cg.fillPath()

    cg.drawLinearGradient(gradient([color(0xFFFFFF, 0.2), color(0xFFFFFF, 0)]),
                          start: CGPoint(x: 512, y: 924), end: CGPoint(x: 512, y: 600), options: [])
    cg.restoreGState()
}

func png(_ pixels: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                               bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                               colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
    let cg = NSGraphicsContext.current!.cgContext
    cg.scaleBy(x: CGFloat(pixels) / 1024, y: CGFloat(pixels) / 1024)
    draw(cg)
    NSGraphicsContext.restoreGraphicsState()
    return rep.representation(using: .png, properties: [:])!
}

let iconset = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("AppIcon.iconset")
try? FileManager.default.removeItem(at: iconset)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for points in [16, 32, 128, 256, 512] {
    try png(points).write(to: iconset.appendingPathComponent("icon_\(points)x\(points).png"))
    try png(points * 2).write(to: iconset.appendingPathComponent("icon_\(points)x\(points)@2x.png"))
}

let iconutil = Process()
iconutil.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
iconutil.arguments = ["-c", "icns", iconset.path, "-o", "Support/AppIcon.icns"]
try iconutil.run()
iconutil.waitUntilExit()
precondition(iconutil.terminationStatus == 0, "iconutil failed")
print("Wrote Support/AppIcon.icns")
