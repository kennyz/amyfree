import AppKit

// 原生绘制应用图标，所有坐标基于 1024 × 1024，构建时生成完整 macOS iconset。
guard CommandLine.arguments.count == 2 else {
    fputs("用法: swift scripts/generate-icon.swift <输出.iconset>\n", stderr)
    exit(1)
}
let output = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

func color(_ red: CGFloat, _ green: CGFloat, _ blue: CGFloat, _ alpha: CGFloat = 1) -> NSColor {
    NSColor(srgbRed: red, green: green, blue: blue, alpha: alpha)
}

func drawIcon() {
    let tile = NSBezierPath(roundedRect: NSRect(x: 100, y: 100, width: 824, height: 824),
                            xRadius: 186, yRadius: 186)
    NSGraphicsContext.saveGraphicsState()
    let shadow = NSShadow()
    shadow.shadowColor = color(0.01, 0.08, 0.16, 0.26)
    shadow.shadowBlurRadius = 32
    shadow.shadowOffset = NSSize(width: 0, height: -12)
    shadow.set()
    color(0.04, 0.15, 0.25).setFill()
    tile.fill()
    NSGraphicsContext.restoreGraphicsState()

    NSGradient(colors: [color(0.08, 0.29, 0.43), color(0.02, 0.12, 0.23)])!
        .draw(in: tile, angle: -70)
    color(0.55, 0.87, 0.98, 0.15).setStroke()
    tile.lineWidth = 3
    tile.stroke()

    // 盾牌轮廓：柔和肩部与圆润下缘，留出清晰的负空间。
    let shield = NSBezierPath()
    shield.move(to: NSPoint(x: 512, y: 814))
    shield.curve(to: NSPoint(x: 758, y: 715),
                 controlPoint1: NSPoint(x: 601, y: 768), controlPoint2: NSPoint(x: 685, y: 743))
    shield.line(to: NSPoint(x: 748, y: 498))
    shield.curve(to: NSPoint(x: 512, y: 230),
                 controlPoint1: NSPoint(x: 742, y: 360), controlPoint2: NSPoint(x: 624, y: 278))
    shield.curve(to: NSPoint(x: 276, y: 498),
                 controlPoint1: NSPoint(x: 400, y: 278), controlPoint2: NSPoint(x: 282, y: 360))
    shield.line(to: NSPoint(x: 266, y: 715))
    shield.curve(to: NSPoint(x: 512, y: 814),
                 controlPoint1: NSPoint(x: 339, y: 743), controlPoint2: NSPoint(x: 423, y: 768))
    shield.close()
    NSGradient(colors: [color(0.30, 0.95, 0.81), color(0.12, 0.66, 0.94)])!
        .draw(in: shield, angle: -65)

    // M 形网络连线，端点代表节点。
    let route = NSBezierPath()
    route.move(to: NSPoint(x: 381, y: 448))
    route.line(to: NSPoint(x: 381, y: 630))
    route.line(to: NSPoint(x: 512, y: 504))
    route.line(to: NSPoint(x: 643, y: 630))
    route.line(to: NSPoint(x: 643, y: 448))
    route.lineWidth = 44
    route.lineCapStyle = .round
    route.lineJoinStyle = .round
    color(0.98, 1, 1).setStroke()
    route.stroke()
    color(0.98, 1, 1).setFill()
    for x: CGFloat in [381, 643] {
        NSBezierPath(ovalIn: NSRect(x: x - 33, y: 415, width: 66, height: 66)).fill()
    }
}

let representations: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024)
]
for (name, pixels) in representations {
    guard let bitmap = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: pixels, pixelsHigh: pixels,
                                        bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                                        isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0),
          let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        fatalError("无法创建图标画布")
    }
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let scale = CGFloat(pixels) / 1024
    let transform = NSAffineTransform()
    transform.scale(by: scale)
    transform.concat()
    drawIcon()
    NSGraphicsContext.restoreGraphicsState()
    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        fatalError("无法编码图标")
    }
    try data.write(to: output.appendingPathComponent(name))
}
print("✓ 已生成 10 个应用图标尺寸")
