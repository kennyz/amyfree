import AppKit

/// Amyfree 的猫咪标志：正脸猫头、小鼻子，左耳尖斜切——「剪耳」是流浪猫已获自由照护的记号。
/// awake 为睁眼（代理开启），否则为闭眼睡觉（代理关闭），菜单栏一眼可辨。
/// 坐标基于 100 × 100（y 向上），菜单栏模板图标与应用图标共用这一份绘制。
func catGlyphImage(size: CGFloat, awake: Bool = true) -> NSImage {
    let image = NSImage(size: NSSize(width: size, height: size), flipped: false) { rect in
        guard let context = NSGraphicsContext.current else { return false }
        let transform = NSAffineTransform()
        transform.scale(by: rect.width / 100)
        transform.concat()
        NSColor.black.set()

        // 耳朵用圆角描边，让尖端柔和；头部为宽椭圆。
        let ears = NSBezierPath()
        ears.move(to: NSPoint(x: 13, y: 46)); ears.line(to: NSPoint(x: 20, y: 93)); ears.line(to: NSPoint(x: 46, y: 68)); ears.close()
        ears.move(to: NSPoint(x: 87, y: 46)); ears.line(to: NSPoint(x: 80, y: 93)); ears.line(to: NSPoint(x: 54, y: 68)); ears.close()
        ears.lineJoinStyle = .round; ears.lineWidth = 7
        ears.fill(); ears.stroke()
        NSBezierPath(ovalIn: NSRect(x: 7, y: 6, width: 86, height: 68)).fill()

        // 以下为镂空部分
        context.compositingOperation = .destinationOut
        let tip = NSBezierPath()                                    // 左耳剪耳：斜切耳尖
        tip.move(to: NSPoint(x: 0, y: 83)); tip.line(to: NSPoint(x: 40, y: 90))
        tip.line(to: NSPoint(x: 40, y: 100)); tip.line(to: NSPoint(x: 0, y: 100)); tip.close()
        tip.fill()
        for x: CGFloat in [32, 68] {
            if awake {                                              // 睁眼：竖椭圆
                NSBezierPath(ovalIn: NSRect(x: x - 10, y: 29, width: 20, height: 24)).fill()
            } else {                                                // 闭眼睡觉：下弯弧 ◡
                let eye = NSBezierPath()
                eye.appendArc(withCenter: NSPoint(x: x, y: 44), radius: 9, startAngle: 200, endAngle: 340)
                eye.lineWidth = 6.5; eye.lineCapStyle = .round
                eye.stroke()
            }
        }
        let nose = NSBezierPath()
        nose.move(to: NSPoint(x: 45, y: 27)); nose.line(to: NSPoint(x: 55, y: 27)); nose.line(to: NSPoint(x: 50, y: 21)); nose.close()
        nose.lineJoinStyle = .round; nose.lineWidth = 2.5
        nose.fill(); nose.stroke()
        return true
    }
    return image
}
