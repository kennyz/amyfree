import AppKit

// 原生绘制应用图标，所有坐标基于 1024 × 1024，构建时生成完整 macOS iconset。
guard CommandLine.arguments.count == 2 else {
    fputs("用法: 与 app/CatGlyph.swift 一起编译后运行 <输出.iconset>（见 scripts/build-app.sh）\n", stderr)
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

    // 猫咪：app/CatGlyph.swift 的自绘标志，按原盾牌配色做渐变填充。
    let box = NSRect(x: 222, y: 214, width: 580, height: 580)
    let symbol = catGlyphImage(size: box.width)
    let cat = NSImage(size: box.size, flipped: false) { rect in
        symbol.draw(in: rect)
        NSGraphicsContext.current?.compositingOperation = .sourceAtop
        NSGradient(colors: [color(0.30, 0.95, 0.81), color(0.12, 0.66, 0.94)])!.draw(in: rect, angle: -65)
        return true
    }
    cat.draw(in: box)
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
