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
    /// 内容变化通知(动画帧 / 数据更新),controller 更新 status item 的尺寸。
    var onContentChanged: (() -> Void)? { get set }
    /// 暂停动画(全市场休市 / 用户开关)
    func setPaused(_ paused: Bool)
    /// view 被替换前停止内部动画源,避免旧 display link 的异步回调撞到新模式。
    func invalidateAnimation()
}

/// status item 的宿主视图。
///
/// `NSStatusItem.view` 已被 AppKit 标记为 deprecated，但它仍是 macOS 提供的
/// 唯一能让同一个自绘内容按每个菜单栏副本分别绘制的 API。这里用一个宿主转发
/// 点击事件，并让 ticker 作为普通子视图参与 status bar 的多屏绘制。
final class StatusItemTickerHostView: NSView {
    private(set) var tickerView: MenuBarTickerView
    var onClick: ((NSEvent) -> Void)?

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
    func invalidateAnimation() {}
}

extension MinimalTickerView: MenuBarTickerView {
    func setPaused(_ paused: Bool) {}   // 无动画
    func invalidateAnimation() {}
}
