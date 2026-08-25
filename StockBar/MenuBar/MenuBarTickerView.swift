import AppKit

/// 所有菜单栏 ticker 视图的公共接口。
///
/// ticker 作为 status item 的自定义 view 绘制，而不是先捕获成一张位图。
/// macOS 会为每个屏幕各自绘制 status item 的副本；保留这条绘制路径，才能让
/// `labelColor` 和涨跌色在外接屏的非活跃菜单栏中分别解析，而不是把主屏捕获到的
/// 白色位图复制到所有菜单栏。
protocol MenuBarTickerView: NSView {
    var totalWidth: CGFloat { get }
    var privacyHidden: Bool { get set }
    var preferredTotalWidth: CGFloat? { get set }
    var showsIcon: Bool { get set }
    /// 鼠标 hover 状态;由 controller 监听鼠标位置同步过来
    var hovered: Bool { get set }
    /// 内容或宽度变化通知，controller 据此更新 status item 的尺寸。
    /// 动画帧只需由 view 自身请求重绘，不应走这条布局路径。
    var onContentChanged: (() -> Void)? { get set }
    /// 暂停动画(全市场休市 / 用户开关)
    func setPaused(_ paused: Bool)
    func setLowPowerMode(_ enabled: Bool)
    /// view 被替换前停止内部动画源,避免旧 display link 的异步回调撞到新模式。
    func invalidateAnimation()
}

/// status item 的宿主视图。
///
/// `NSStatusItem.view` 已被 AppKit 标记为 deprecated。这里有意把兼容性用法隔离
/// 在一个宿主中：标准 button + 位图路径会把单屏解析后的颜色复制到其他菜单栏，
/// 而自定义 view 可让 ticker 按各菜单栏副本的外观实时绘制。宿主同时负责转发点击。
final class StatusItemTickerHostView: NSView {
    private(set) var tickerView: MenuBarTickerView
    var onClick: ((NSEvent) -> Void)?
    var onHoverChanged: ((Bool) -> Void)?
    private var hoverTrackingArea: NSTrackingArea?

    init(tickerView: MenuBarTickerView) {
        self.tickerView = tickerView
        super.init(frame: NSRect(x: 0, y: 0, width: tickerView.totalWidth, height: 22))
        commonInit()
    }

    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override var allowsVibrancy: Bool { false }

    private func commonInit() {
        wantsLayer = true
        layer?.backgroundColor = .clear
        addSubview(tickerView)
        tickerView.frame = bounds
        tickerView.autoresizingMask = [.width, .height]
    }

    func replaceTickerView(_ tickerView: MenuBarTickerView) {
        self.tickerView.removeFromSuperview()
        self.tickerView = tickerView
        addSubview(tickerView)
        tickerView.frame = bounds
        tickerView.autoresizingMask = [.width, .height]
    }

    override func layout() {
        super.layout()
        tickerView.frame = bounds
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverTrackingArea { removeTrackingArea(hoverTrackingArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self,
            userInfo: nil
        )
        addTrackingArea(area)
        hoverTrackingArea = area
    }

    override func mouseEntered(with event: NSEvent) { onHoverChanged?(true) }
    override func mouseExited(with event: NSEvent) { onHoverChanged?(false) }

    /// 子视图只负责绘制，点击统一由宿主交给 controller 处理。
    override func hitTest(_ point: NSPoint) -> NSView? {
        bounds.contains(point) ? self : nil
    }

    override func mouseUp(with event: NSEvent) {
        onClick?(event)
    }

    override func rightMouseUp(with event: NSEvent) {
        onClick?(event)
    }
}

extension TickerView: MenuBarTickerView {}
extension CarouselTickerView: MenuBarTickerView {}

extension CompactTickerView: MenuBarTickerView {
    func setPaused(_ paused: Bool) {}   // 无动画
    func setLowPowerMode(_ enabled: Bool) {}
    func invalidateAnimation() {}
}

extension MinimalTickerView: MenuBarTickerView {
    func setPaused(_ paused: Bool) {}   // 无动画
    func setLowPowerMode(_ enabled: Bool) {}
    func invalidateAnimation() {}
}
