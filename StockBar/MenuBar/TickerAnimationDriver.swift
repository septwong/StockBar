import AppKit
import QuartzCore

/// 小范围菜单栏动画时钟。停止时彻底释放动画源，避免隐藏状态持续唤醒。
@MainActor
final class TickerAnimationDriver: NSObject {
    private weak var view: NSView?
    private let onFrame: (CFTimeInterval) -> Void
    private var modernSource: AnyObject?
    private var timer: Timer?
    private(set) var isRunning = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled

    init(view: NSView, onFrame: @escaping (CFTimeInterval) -> Void) {
        self.view = view
        self.onFrame = onFrame
    }

    func setLowPowerMode(_ enabled: Bool) {
        guard lowPowerMode != enabled else { return }
        lowPowerMode = enabled
        if isRunning { stop(); start() }
    }

    func start() {
        guard !isRunning, let view, view.window != nil else { return }
        isRunning = true
        let fps = lowPowerMode ? 15.0 : 30.0
        if #available(macOS 14.0, *) {
            let source = ModernDisplayLinkSource(view: view, fps: fps, onFrame: onFrame)
            source.start()
            modernSource = source
        } else {
            let timer = Timer(timeInterval: 1.0 / fps, target: self, selector: #selector(timerFired), userInfo: nil, repeats: true)
            timer.tolerance = min(0.004, 0.2 / fps)
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        }
    }

    func stop() {
        if #available(macOS 14.0, *), let source = modernSource as? ModernDisplayLinkSource {
            source.stop()
        }
        modernSource = nil
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    @objc private func timerFired() { onFrame(CACurrentMediaTime()) }

    deinit {
        timer?.invalidate()
    }
}

@available(macOS 14.0, *)
@MainActor
private final class ModernDisplayLinkSource: NSObject {
    private weak var view: NSView?
    private let fps: Double
    private let onFrame: (CFTimeInterval) -> Void
    private var link: CADisplayLink?

    init(view: NSView, fps: Double, onFrame: @escaping (CFTimeInterval) -> Void) {
        self.view = view
        self.fps = fps
        self.onFrame = onFrame
    }

    func start() {
        guard let view else { return }
        let link = view.displayLink(target: self, selector: #selector(fired(_:)))
        link.preferredFrameRateRange = CAFrameRateRange(minimum: Float(fps), maximum: Float(fps), preferred: Float(fps))
        link.add(to: .main, forMode: .common)
        self.link = link
    }

    func stop() {
        link?.invalidate()
        link = nil
    }

    @objc private func fired(_ link: CADisplayLink) { onFrame(link.timestamp) }
}
