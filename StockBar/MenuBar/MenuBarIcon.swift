import AppKit

/// StockBar 方案 B 菜单栏标识：由单色圆角柱组成抽象字母 S。
///
/// Dock 与应用内保留品牌蓝；菜单栏遵循 macOS 惯例，使用动态 labelColor，
/// 随浅色/深色菜单栏自动呈现为黑色或白色。
enum MenuBarIcon {
    private struct Bar {
        let x: CGFloat
        let y: CGFloat
        let height: CGFloat
    }

    /// 坐标均以设计画布左上角为原点并归一化，便于在 16–20 pt 下保持比例。
    private static let bars: [Bar] = [
        .init(x: 0.16, y: 0.17, height: 0.20),
        .init(x: 0.29, y: 0.10, height: 0.32),
        .init(x: 0.42, y: 0.07, height: 0.20),
        .init(x: 0.55, y: 0.09, height: 0.18),
        .init(x: 0.68, y: 0.15, height: 0.20),
        .init(x: 0.42, y: 0.32, height: 0.22),
        .init(x: 0.55, y: 0.42, height: 0.25),
        .init(x: 0.16, y: 0.63, height: 0.20),
        .init(x: 0.29, y: 0.70, height: 0.19),
        .init(x: 0.42, y: 0.72, height: 0.21),
        .init(x: 0.55, y: 0.58, height: 0.32),
        .init(x: 0.68, y: 0.54, height: 0.25),
    ]

    static func draw(in rect: NSRect) {
        let side = min(rect.width, rect.height)
        let markRect = NSRect(
            x: rect.midX - side / 2,
            y: rect.midY - side / 2,
            width: side,
            height: side
        )
        let barWidth = max(1.5, side * 0.105)
        NSColor.labelColor.setFill()

        for bar in bars {
            let height = side * bar.height
            let x = markRect.minX + side * bar.x
            let top = markRect.maxY - side * bar.y
            let barRect = NSRect(x: x, y: top - height, width: barWidth, height: height)
            NSBezierPath(
                roundedRect: barRect,
                xRadius: barWidth / 2,
                yRadius: barWidth / 2
            ).fill()
        }
    }
}
