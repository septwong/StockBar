import Foundation
import Combine
import AppKit

/// 全局行情刷新泵。根据当前可见性 / 系统休眠 / 市场状态切换不同刷新频率。
@MainActor
final class QuoteRefresher: ObservableObject {
    enum Pace {
        case popoverOpen   // 3s,用户正盯着,固定快
        case tickerOnly    // 用户配置的间隔(默认 5s)
        case sleeping      // 暂停(全市场休市 / 系统休眠 / 离线 都走这条)
    }

    /// 用户在设置里改了「行情刷新间隔」时,更新这个值;runLoop 下次循环生效。
    @Published var tickerInterval: TimeInterval = 5 {
        didSet { if oldValue != tickerInterval { rescheduleQuote() } }
    }
    /// 是否在全市场休市时完全暂停自动刷新。用户开关,默认 true。
    @Published var pauseWhenClosed: Bool = true {
        didSet { if oldValue != pauseWhenClosed { schedulingConditionsDidChange() } }
    }

    nonisolated static func effectiveQuoteInterval(
        userInterval: TimeInterval,
        popoverOpen: Bool,
        lowPowerMode: Bool
    ) -> TimeInterval {
        if popoverOpen { return min(userInterval, 3) }
        return lowPowerMode ? max(userInterval, 15) : userInterval
    }

    nonisolated static func effectiveIndexInterval(popoverOpen: Bool, lowPowerMode: Bool) -> TimeInterval {
        (!popoverOpen && lowPowerMode) ? 30 : 15
    }

    nonisolated static func shouldPersistCache(lastPersistedAt: Date?, now: Date) -> Bool {
        lastPersistedAt.map { now.timeIntervalSince($0) >= 60 } ?? true
    }

    @Published private(set) var snapshot: PortfolioSnapshot = .empty
    @Published private(set) var quotes: [SymbolID: Quote] = [:]
    @Published private(set) var indexQuotes: [IndexQuote] = []
    @Published private(set) var lastError: String?
    @Published private(set) var lastUpdated: Date?
    /// true 表示一次网络刷新正在进行中,UI 可以显示 spinner。
    @Published private(set) var isRefreshing: Bool = false
    /// 首次行情请求是否已经结束(成功或失败)。只在真正的首次加载阶段显示 spinner,
    /// 避免缓存存在或网络失败时,每次后台重试都让底部状态栏闪一下。
    @Published private(set) var hasCompletedInitialRefresh: Bool = false
    /// snapshot/quotes 当前值的来源是否是磁盘缓存(尚未拿到任何成功的网络响应)。
    /// UI 据此显示「显示的是上次的数据,正在更新...」提示。
    @Published private(set) var snapshotIsFromCache: Bool = false

    private let service: PortfolioService
    private let indexService: IndexService
    private let clock: MarketClock
    private let quoteCacheRepo: QuoteCacheRepository?
    private let fxCacheRepo: FXCacheRepository?
    private let holdingsRepo: HoldingsRepository?
    private let indexRepo: IndexRepository?
    private let settingsRepo: SettingsRepository?
    private let alertEngine: AlertEngine?
    private var quoteScheduleTask: Task<Void, Never>?
    private var indexScheduleTask: Task<Void, Never>?
    private var quoteScheduleGeneration = 0
    private var indexScheduleGeneration = 0
    private var started = false
    private var pace: Pace = .tickerOnly
    private var popoverOpen = false
    private var sleeping = false
    private var offline = false
    private var lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
    private var tickerNeedsIndices = false
    private var isRefreshingIndices = false
    private var indexRefreshQueued = false
    private var observers: [NSObjectProtocol] = []
    private var lastCachePersistedAt: Date?

    init(
        service: PortfolioService,
        indexService: IndexService,
        clock: MarketClock,
        quoteCacheRepo: QuoteCacheRepository? = nil,
        fxCacheRepo: FXCacheRepository? = nil,
        holdingsRepo: HoldingsRepository? = nil,
        indexRepo: IndexRepository? = nil,
        settingsRepo: SettingsRepository? = nil,
        alertEngine: AlertEngine? = nil
    ) {
        self.service = service
        self.indexService = indexService
        self.clock = clock
        self.quoteCacheRepo = quoteCacheRepo
        self.fxCacheRepo = fxCacheRepo
        self.holdingsRepo = holdingsRepo
        self.indexRepo = indexRepo
        self.settingsRepo = settingsRepo
        self.alertEngine = alertEngine

        // 同步从磁盘 seed quotes,这样 popover 一打开就有数据。
        let cachedQuotes = quoteCacheRepo?.loadAll() ?? [:]
        if !cachedQuotes.isEmpty {
            self.quotes = cachedQuotes
            Log.quote.info("seeded \(cachedQuotes.count, privacy: .public) quotes from disk")
        } else {
            Log.quote.info("quote disk cache is empty")
        }

        // 同步从磁盘读 FX + 持仓,合成首屏 snapshot。
        // 这样 popover 一打开 totalAssets / 累计盈亏立即正确,不用等 warmup 完成。
        if let holdingsRepo = holdingsRepo, let settingsRepo = settingsRepo {
            let holdings = (try? holdingsRepo.all()) ?? []
            let fxCache = fxCacheRepo?.loadAll() ?? [:]
            let converter = CurrencyConverter(fromCache: fxCache)
            let baseCurrency = settingsRepo.baseCurrency
            self.snapshot = PortfolioService.computeSnapshotSync(
                holdings: holdings,
                quotes: cachedQuotes,
                converter: converter,
                baseCurrency: baseCurrency
            )
            if !cachedQuotes.isEmpty || !fxCache.isEmpty {
                self.snapshotIsFromCache = true
            }
        }

        observeSystem()
    }

    /// 一旦网络拉到新 FX 值,可以再用最新 FX 重算一次 snapshot(init 阶段用的是磁盘 FX)。
    /// 不阻塞 caller,在 lastUpdated 还没被 tick 占用时才覆盖。
    func reseedSnapshotWithFreshFX() async {
        let snap = await service.computeSnapshot(usingCachedQuotes: quotes)
        guard lastUpdated == nil else { return }
        snapshot = snap
    }

    func setOffline(_ value: Bool) {
        guard offline != value else { return }
        offline = value
        schedulingConditionsDidChange()
    }

    var isOffline: Bool { offline }

    deinit {
        for o in observers { NotificationCenter.default.removeObserver(o) }
        quoteScheduleTask?.cancel()
        indexScheduleTask?.cancel()
    }

    func start() {
        guard !started else { return }
        started = true
        rescheduleQuote(immediate: true)
        rescheduleIndices(immediate: indexDemand)
    }

    func stop() {
        started = false
        quoteScheduleTask?.cancel()
        quoteScheduleTask = nil
        indexScheduleTask?.cancel()
        indexScheduleTask = nil
    }

    /// 触发立即刷新一次(不影响调度)。
    func refreshNow() {
        Task { await tick() }
    }

    /// 指数配置发生变化后立即按最新列表刷新一次。
    func refreshIndicesNow() {
        indexRefreshQueued = true
        if let indexRepo, let current = try? indexRepo.all() {
            let quotesByID = Dictionary(uniqueKeysWithValues: indexQuotes.map { ($0.id, $0) })
            // 配置删除或排序后先同步现有行情，避免旧指数继续显示到网络请求结束。
            indexQuotes = current.compactMap { quotesByID[$0.id] }
        }
        Task { await tickIndices() }
    }

    func setPopoverOpen(_ open: Bool) {
        guard popoverOpen != open else { return }
        popoverOpen = open
        schedulingConditionsDidChange()
        if open { rescheduleIndices(immediate: true) }
    }

    /// 菜单栏滚动/轮播实际勾选指数时保持指数行情；其它模式不产生后台需求。
    func setTickerIndexDemand(_ needed: Bool) {
        guard tickerNeedsIndices != needed else { return }
        tickerNeedsIndices = needed
        rescheduleIndices(immediate: needed)
    }

    func schedulingConditionsDidChange() {
        recomputePace()
        rescheduleQuote()
        rescheduleIndices()
    }

    private func observeSystem() {
        let nc = NSWorkspace.shared.notificationCenter
        observers.append(nc.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = true
                self?.schedulingConditionsDidChange()
            }
        })
        observers.append(nc.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.sleeping = false
                self?.schedulingConditionsDidChange()
            }
        })
        observers.append(NotificationCenter.default.addObserver(
            forName: Notification.Name("NSProcessInfoPowerStateDidChangeNotification"),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.lowPowerMode = ProcessInfo.processInfo.isLowPowerModeEnabled
                self.schedulingConditionsDidChange()
            }
        })
    }

    private func recomputePace() {
        let next: Pace
        if sleeping || offline {
            next = .sleeping
        } else if !clock.anyOpen() && pauseWhenClosed {
            // 全市场休市 + 开关开着:完全暂停自动刷新,用户可点底部刷新按钮手动拉
            next = .sleeping
        } else if popoverOpen {
            next = .popoverOpen
        } else {
            next = .tickerOnly
        }
        pace = next
    }

    private var indexDemand: Bool { popoverOpen || tickerNeedsIndices }

    private func automaticDelay(baseInterval: TimeInterval) -> TimeInterval? {
        guard !sleeping, !offline else { return nil }
        if pauseWhenClosed, !clock.anyOpen() {
            return clock.nextOpening(after: Date()).map { max(0.1, $0.timeIntervalSinceNow) }
        }
        return baseInterval
    }

    private func rescheduleQuote(immediate: Bool = false) {
        guard started else { return }
        quoteScheduleGeneration += 1
        let generation = quoteScheduleGeneration
        quoteScheduleTask?.cancel()
        recomputePace()
        let base: TimeInterval
        switch pace {
        case .popoverOpen:
            base = Self.effectiveQuoteInterval(
                userInterval: tickerInterval,
                popoverOpen: true,
                lowPowerMode: lowPowerMode
            )
        case .tickerOnly:
            base = Self.effectiveQuoteInterval(
                userInterval: tickerInterval,
                popoverOpen: false,
                lowPowerMode: lowPowerMode
            )
        case .sleeping:
            guard !sleeping, !offline,
                  let opening = clock.nextOpening(after: Date()) else {
                quoteScheduleTask = nil
                return
            }
            base = max(0.1, opening.timeIntervalSinceNow)
        }
        let delay = immediate ? 0 : base
        quoteScheduleTask = schedule(after: delay) { [weak self] in
            guard let self, generation == self.quoteScheduleGeneration else { return }
            self.quoteScheduleTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.tick()
                if generation == self.quoteScheduleGeneration { self.rescheduleQuote() }
            }
        }
    }

    private func rescheduleIndices(immediate: Bool = false) {
        guard started else { return }
        indexScheduleGeneration += 1
        let generation = indexScheduleGeneration
        indexScheduleTask?.cancel()
        guard indexDemand else {
            indexScheduleTask = nil
            return
        }
        let interval = Self.effectiveIndexInterval(popoverOpen: popoverOpen, lowPowerMode: lowPowerMode)
        guard let automatic = automaticDelay(baseInterval: interval) else {
            indexScheduleTask = nil
            return
        }
        let delay = immediate ? 0 : automatic
        indexScheduleTask = schedule(after: delay) { [weak self] in
            guard let self, generation == self.indexScheduleGeneration else { return }
            self.indexScheduleTask = nil
            Task { @MainActor [weak self] in
                guard let self else { return }
                await self.tickIndices()
                if generation == self.indexScheduleGeneration { self.rescheduleIndices() }
            }
        }
    }

    private func schedule(after delay: TimeInterval, action: @escaping @MainActor () -> Void) -> Task<Void, Never> {
        Task { @MainActor in
            if delay > 0 {
                try? await Task.sleep(nanoseconds: UInt64(min(delay, TimeInterval(UInt64.max) / 1_000_000_000) * 1_000_000_000))
            }
            guard !Task.isCancelled else { return }
            action()
        }
    }

    private func tickIndices() async {
        guard !isRefreshingIndices else { return }
        isRefreshingIndices = true
        indexRefreshQueued = false
        defer {
            isRefreshingIndices = false
            if indexRefreshQueued {
                Task { [weak self] in await self?.tickIndices() }
            }
        }

        do {
            let indices: [IndexDescriptor]
            if let indexRepo {
                indices = try indexRepo.all()
            } else {
                indices = IndexCatalog.defaults
            }

            guard !indices.isEmpty else {
                indexQuotes = []
                return
            }

            let result = try await indexService.fetchAll(indices)
            // 配置在请求期间发生变化时，丢弃旧请求结果，由 defer 触发下一次刷新。
            guard !indexRefreshQueued else { return }
            await MainActor.run {
                self.indexQuotes = result
            }
        } catch {
            Log.quote.warning("index fetch failed: \(String(describing: error), privacy: .public)")
        }
    }

    private func tick() async {
        guard !isRefreshing else { return }
        isRefreshing = true
        defer {
            isRefreshing = false
            hasCompletedInitialRefresh = true
        }

        do {
            let snap = try await service.computeSnapshot()
            let hasFreshData = !snap.allQuotes.isEmpty
            let isEmptyPortfolio = snap.positions.isEmpty && snap.allQuotes.isEmpty
            if hasFreshData || isEmptyPortfolio {
                snapshot = snap
                snapshotIsFromCache = false
                if isEmptyPortfolio {
                    quotes = [:]
                } else {
                    quotes.merge(snap.allQuotes) { _, new in new }
                }
                lastUpdated = Date()
                lastError = nil
                alertEngine?.evaluate(quotes: quotes)
            }
            // 首次成功立即写盘，之后最多每分钟一次，避免高频 SQLite/WAL 唤醒。
            let now = Date()
            if hasFreshData, Self.shouldPersistCache(lastPersistedAt: lastCachePersistedAt, now: now) {
                quoteCacheRepo?.upsertMany(snap.allQuotes)
                lastCachePersistedAt = now
            }
        } catch {
            lastError = String(describing: error)
            Log.quote.error("refresh failed: \(String(describing: error), privacy: .public)")
        }
    }
}
