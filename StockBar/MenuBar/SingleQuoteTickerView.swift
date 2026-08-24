import AppKit

/// 「固定(单股)」模式:一只股票的名称、当前价和涨跌幅,不滚动也不轮播。
final class SingleQuoteTickerView: NSView {
    struct Content: Equatable {
        let symbol: SymbolID
        let name: String
        let price: Decimal?
        let changePct: Double?
    }

    private var content: Content?
    var scheme: TickerColorScheme = .east
    var privacyHidden: Bool = false
    var preferredTotalWidth: CGFloat?
    var showsIcon: Bool = true
    var hovered: Bool = false
    var onContentChanged: (() -> Void)?

    private let iconWidth: CGFloat = 18
    private let itemSpacing: CGFloat = 6
    private let emptyHitTargetWidth: CGFloat = 24

    private var menuBarFont: NSFont { NSFont.menuBarFont(ofSize: 0) }
    private var valueFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: menuBarFont.pointSize, weight: .regular)
    }
    private var changeFont: NSFont {
        NSFont.monospacedDigitSystemFont(ofSize: menuBarFont.pointSize, weight: .semibold)
    }

    private var leadingTextX: CGFloat { showsIcon ? iconWidth + 6 : 4 }

    var totalWidth: CGFloat {
        guard content != nil else {
            // 即使没有选中股票,隐私模式仍要留出图标和 "•••" 的绘制空间。
            if let preferredTotalWidth {
                return max(40, preferredTotalWidth)
            }
            return privacyHidden ? leadingTextX + 24 : emptyHitTargetWidth
        }
        if let preferredTotalWidth {
            return max(40, preferredTotalWidth)
        }
        let width = renderPieces().reduce(CGFloat.zero) { partial, piece in
            partial + piece.size().width
        } + itemSpacing * 2
        return leadingTextX + width + 4
    }

    override var isFlipped: Bool { false }
    override var allowsVibrancy: Bool { false }

    override init(frame: NSRect) {
        super.init(frame: frame)
        commonInit()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        commonInit()
    }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        // 离屏渲染前由 StatusItemController 注入状态栏按钮的 effectiveAppearance。
        // 这里不要固定为 darkAqua，否则浅色菜单栏会把动态文字渲染成白色。
    }

    func update(content: Content?) {
        self.content = content
        needsDisplay = true
        onContentChanged?()
    }

    override func draw(_ dirtyRect: NSRect) {
        if showsIcon {
            MenuBarIcon.draw(in: NSRect(
                x: 2,
                y: (bounds.height - iconWidth) / 2,
                width: iconWidth,
                height: iconWidth
            ))
        }

        let textRect = NSRect(
            x: leadingTextX,
            y: 0,
            width: max(20, bounds.width - leadingTextX - 4),
            height: bounds.height
        )

        if privacyHidden {
            let dots = NSAttributedString(string: "•••", attributes: [
                .font: valueFont,
                .foregroundColor: NSColor.secondaryLabelColor
            ])
            dots.draw(at: NSPoint(x: textRect.minX, y: textRect.midY - dots.size().height / 2))
            return
        }

        guard content != nil else { return }

        var x = textRect.minX
        for (index, piece) in renderPieces().enumerated() {
            if index > 0 { x += itemSpacing }
            let size = piece.size()
            piece.draw(at: NSPoint(x: x, y: textRect.midY - size.height / 2))
            x += size.width
        }
    }

    /// 暴露给单元测试和渲染器的固定格式,也让正负/缺失行情保持一致。
    static func formattedPrice(_ price: Decimal?) -> String {
        price.map(TickerDisplayFormatting.price) ?? "--"
    }

    static func formattedChange(_ changePct: Double?) -> String {
        changePct.map(TickerDisplayFormatting.percent) ?? "--"
    }

    private func renderPieces() -> [NSAttributedString] {
        guard let content else { return [] }

        let name = TickerDisplayFormatting.shortenedName(content.name, market: content.symbol.market)
        let nameAttr: [NSAttributedString.Key: Any] = [
            .font: menuBarFont,
            .foregroundColor: NSColor.labelColor
        ]
        let valueAttr: [NSAttributedString.Key: Any] = [
            .font: valueFont,
            .foregroundColor: NSColor.labelColor
        ]
        let changeColor: NSColor
        if let changePct = content.changePct {
            if changePct > 0 {
                changeColor = SemanticColors.upNS(scheme: scheme)
            } else if changePct < 0 {
                changeColor = SemanticColors.downNS(scheme: scheme)
            } else {
                changeColor = NSColor.labelColor
            }
        } else {
            changeColor = NSColor.secondaryLabelColor
        }
        let changeAttr: [NSAttributedString.Key: Any] = [
            .font: changeFont,
            .foregroundColor: changeColor
        ]

        return [
            NSAttributedString(string: name, attributes: nameAttr),
            NSAttributedString(string: Self.formattedPrice(content.price), attributes: valueAttr),
            NSAttributedString(string: Self.formattedChange(content.changePct), attributes: changeAttr)
        ]
    }
}

extension SingleQuoteTickerView: MenuBarTickerView {
    func renderImage() -> NSImage { defaultRenderImage() }
    func setPaused(_ paused: Bool) {}
    func invalidateAnimation() {}
}
