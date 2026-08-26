import Foundation

/// 持仓服务:加载行情与交易流水后,计算每只持仓的盈亏并汇总到本位币。
actor PortfolioService {
    private let holdingsRepo: HoldingsRepository
    private let transactionsRepo: PortfolioTransactionsRepository
    private let watchlistRepo: WatchlistRepository
    private let settingsRepo: SettingsRepository
    private let provider: QuoteProvider
    private let fx: FXService

    init(
        holdingsRepo: HoldingsRepository,
        transactionsRepo: PortfolioTransactionsRepository,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        provider: QuoteProvider,
        fx: FXService
    ) {
        self.holdingsRepo = holdingsRepo
        self.transactionsRepo = transactionsRepo
        self.watchlistRepo = watchlistRepo
        self.settingsRepo = settingsRepo
        self.provider = provider
        self.fx = fx
    }

    /// Keeps lightweight callers that predate transaction history source-
    /// compatible while routing them through the same database table.
    init(
        holdingsRepo: HoldingsRepository,
        watchlistRepo: WatchlistRepository,
        settingsRepo: SettingsRepository,
        provider: QuoteProvider,
        fx: FXService
    ) {
        self.init(
            holdingsRepo: holdingsRepo,
            transactionsRepo: PortfolioTransactionsRepository(dbPool: holdingsRepo.dbPool),
            watchlistRepo: watchlistRepo,
            settingsRepo: settingsRepo,
            provider: provider,
            fx: fx
        )
    }

    /// 拉取所有活跃持仓 + 自选 + 今日发生交易的标的 → 一次性请求行情 → 构建快照。
    func computeSnapshot() async throws -> PortfolioSnapshot {
        let holdings = (try? holdingsRepo.all()) ?? []
        let transactions = (try? transactionsRepo.all()) ?? []
        let watchlist = (try? watchlistRepo.all()) ?? []

        var allSymbols = Set<SymbolID>()
        for h in holdings { allSymbols.insert(h.symbol) }
        for w in watchlist { allSymbols.insert(w.symbol) }
        let now = Date()
        for transaction in transactions where Self.isSameMarketDay(
            transaction.occurredAt,
            asOf: now,
            market: transaction.symbol.market
        ) {
            allSymbols.insert(transaction.symbol)
        }

        let quotes: [SymbolID: Quote]
        if allSymbols.isEmpty {
            quotes = [:]
        } else {
            let fetched = try await provider.fetch(Array(allSymbols))
            guard !fetched.isEmpty else { throw ProviderError.empty }
            quotes = fetched
        }

        let converter = await fx.currentConverter()
        let baseCurrency = settingsRepo.baseCurrency
        return Self.computeSnapshotSync(
            holdings: holdings,
            transactions: transactions,
            quotes: quotes,
            converter: converter,
            baseCurrency: baseCurrency
        )
    }

    /// 不走网络,只用调用方提供的行情。用于「秒出 + 后台刷新」。
    func computeSnapshot(usingCachedQuotes cached: [SymbolID: Quote]) async -> PortfolioSnapshot {
        let holdings = (try? holdingsRepo.all()) ?? []
        let transactions = (try? transactionsRepo.all()) ?? []
        let converter = await fx.currentConverter()
        let baseCurrency = settingsRepo.baseCurrency
        return Self.computeSnapshotSync(
            holdings: holdings,
            transactions: transactions,
            quotes: cached,
            converter: converter,
            baseCurrency: baseCurrency
        )
    }

    /// Compatibility overload for callers/tests that only have materialized
    /// holdings. Each holding is treated as an opening balance.
    static func computeSnapshotSync(
        holdings: [Holding],
        quotes: [SymbolID: Quote],
        converter: CurrencyConverter,
        baseCurrency: Currency,
        asOf: Date = Date()
    ) -> PortfolioSnapshot {
        let transactions = holdings.map { h in
            PortfolioTransaction(
                holdingID: h.id,
                symbol: h.symbol,
                name: h.name,
                type: .openingBalance,
                quantity: h.quantity,
                price: h.costPrice,
                currency: h.currency,
                occurredAt: h.createdAt,
                recordedAt: h.createdAt
            )
        }
        return computeSnapshotSync(
            holdings: holdings,
            transactions: transactions,
            quotes: quotes,
            converter: converter,
            baseCurrency: baseCurrency,
            asOf: asOf
        )
    }

    /// Pure calculation entry point. Transaction history is replayed per
    /// holding; closed holdings still contribute realized and same-day P&L,
    /// while only active holdings appear in `positions` and total assets.
    static func computeSnapshotSync(
        holdings: [Holding],
        transactions: [PortfolioTransaction],
        quotes: [SymbolID: Quote],
        converter: CurrencyConverter,
        baseCurrency: Currency,
        asOf: Date = Date()
    ) -> PortfolioSnapshot {
        let holdingByID = Dictionary(uniqueKeysWithValues: holdings.map { ($0.id, $0) })
        let grouped = Dictionary(grouping: transactions, by: \.holdingID)
        var summaries: [UUID: PortfolioLedgerSummary] = [:]

        for (holdingID, group) in grouped {
            let relevant = group.filter { $0.occurredAt <= asOf }
            if let summary = try? PortfolioLedger.replay(relevant) {
                summaries[holdingID] = summary
            }
        }

        // A just-created/imported materialized holding can briefly exist before
        // its opening transaction is available. Keep the snapshot resilient.
        for holding in holdings where summaries[holding.id] == nil {
            let opening = PortfolioTransaction(
                holdingID: holding.id,
                symbol: holding.symbol,
                name: holding.name,
                type: .openingBalance,
                quantity: holding.quantity,
                price: holding.costPrice,
                currency: holding.currency,
                occurredAt: holding.createdAt,
                recordedAt: holding.createdAt
            )
            summaries[holding.id] = try? PortfolioLedger.replay([opening])
        }

        var positions: [HoldingPosition] = []
        var totalAssets: Decimal = 0
        var totalCost: Decimal = 0
        var historicalCostBase: Decimal = 0
        var adjustedCostBase: Decimal = 0
        var todayPnL: Decimal = 0
        var todayBasis: Decimal = 0
        var allTimePnL: Decimal = 0

        // Closed holdings are intentionally not in holdingByID, but their
        // realized P&L and today's completed trades are still included below.
        for (holdingID, summary) in summaries {
            let group = grouped[holdingID] ?? []
            let holding = holdingByID[holdingID]
            guard let symbol = group.first?.symbol ?? holding?.symbol else { continue }
            let quote = holding.flatMap { quotes[$0.symbol] } ?? quotes[symbol]
            // The replayed ledger is the source of truth; the Holding row is
            // only the materialized cache used to locate active positions.
            let currentQuantity = summary.quantity
            let currency = holding?.currency ?? group.first?.currency ?? symbol.market.defaultCurrency
            let currentPrice = quote?.price ?? holding?.costPrice ?? summary.averageCost
            let marketValue = currentPrice * currentQuantity
            let costValue = summary.quantity > 0 ? summary.costAmount : 0
            let unrealizedPnL = holding == nil ? 0 : marketValue - costValue
            let cumulativePnL = summary.realizedPnL + unrealizedPnL
            let historicalBase = summary.historicalCostBase
            let adjustedCostValue = summary.quantity > 0 ? summary.adjustedCostAmount : 0
            let pnlPct: Double = adjustedCostValue > 0
                ? (cumulativePnL / adjustedCostValue as NSDecimalNumber).doubleValue
                : 0

            let day = Self.todayMetrics(
                transactions: group,
                quote: quote,
                currentQuantity: currentQuantity,
                asOf: asOf,
                market: symbol.market
            )

            if let baseHistorical = converter.convert(historicalBase, from: currency, to: baseCurrency) {
                historicalCostBase += baseHistorical
            }
            if let baseDay = converter.convert(day.pnl, from: currency, to: baseCurrency) {
                todayPnL += baseDay
            }
            if let baseBasis = converter.convert(day.basis, from: currency, to: baseCurrency) {
                todayBasis += baseBasis
            }

            guard let holding else {
                allTimePnL += converter.convert(summary.realizedPnL, from: currency, to: baseCurrency) ?? 0
                continue
            }

            let baseMarketValue = converter.convert(marketValue, from: currency, to: baseCurrency)
            let baseTodayPnL = converter.convert(day.pnl, from: currency, to: baseCurrency)
            let basePnL = converter.convert(cumulativePnL, from: currency, to: baseCurrency)
            let baseUnrealizedPnL = converter.convert(unrealizedPnL, from: currency, to: baseCurrency)
            let baseCost = converter.convert(costValue, from: currency, to: baseCurrency)
            let baseAdjustedCost = converter.convert(adjustedCostValue, from: currency, to: baseCurrency)

            positions.append(HoldingPosition(
                holding: holding,
                quote: quote,
                marketValue: marketValue,
                unrealizedPnL: unrealizedPnL,
                realizedPnL: summary.realizedPnL,
                pnl: cumulativePnL,
                pnlPct: pnlPct,
                adjustedCostPrice: summary.adjustedCostPrice,
                todayPnL: day.pnl,
                baseMarketValue: baseMarketValue,
                baseTodayPnL: baseTodayPnL,
                basePnL: basePnL,
                baseUnrealizedPnL: baseUnrealizedPnL
            ))

            if let bv = baseMarketValue { totalAssets += bv }
            if let bc = baseCost { totalCost += bc }
            if let bac = baseAdjustedCost { adjustedCostBase += bac }
            if let bp = basePnL { allTimePnL += bp }
        }

        let todayPnLPct: Double = todayBasis > 0
            ? (todayPnL / todayBasis as NSDecimalNumber).doubleValue
            : 0
        // Match broker-style return percentages while preserving a meaningful
        // denominator after every active position has been closed.
        let allTimePctBase = adjustedCostBase > 0 ? adjustedCostBase : historicalCostBase
        let allTimePnLPct: Double = allTimePctBase > 0
            ? (allTimePnL / allTimePctBase as NSDecimalNumber).doubleValue
            : 0

        return PortfolioSnapshot(
            baseCurrency: baseCurrency,
            totalAssets: totalAssets,
            totalCost: totalCost,
            historicalCostBase: historicalCostBase,
            adjustedCostBase: adjustedCostBase,
            todayPnL: todayPnL,
            todayPnLPct: todayPnLPct,
            allTimePnL: allTimePnL,
            allTimePnLPct: allTimePnLPct,
            positions: positions.sorted { $0.holding.sortOrder < $1.holding.sortOrder },
            allQuotes: quotes,
            asOf: asOf
        )
    }

    /// Calculate today's cash-flow-adjusted P&L in native currency.
    /// Transaction fees remain part of cumulative P&L, but are not included
    /// in the broker-style intraday reference P&L.
    private static func todayMetrics(
        transactions: [PortfolioTransaction],
        quote: Quote?,
        currentQuantity: Decimal,
        asOf: Date,
        market: Market
    ) -> (pnl: Decimal, basis: Decimal) {
        guard let quote else { return (0, 0) }

        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        let start = calendar.startOfDay(for: asOf)
        let relevant = transactions.filter { $0.occurredAt <= asOf }
        let beforeDay = relevant.filter { $0.occurredAt < start }
        let today = relevant
            .filter { $0.occurredAt >= start }
            .sorted {
                if $0.occurredAt != $1.occurredAt { return $0.occurredAt < $1.occurredAt }
                if $0.recordedAt != $1.recordedAt { return $0.recordedAt < $1.recordedAt }
                return $0.id.uuidString < $1.id.uuidString
            }

        let openingQuantity: Decimal = {
            guard let state = try? PortfolioLedger.replay(beforeDay) else { return 0 }
            return state.quantity
        }()
        let referencePrice = quote.prevClose > 0 ? quote.prevClose : quote.price
        var baselineValue = openingQuantity * referencePrice
        var buyGross: Decimal = 0
        var sellNet: Decimal = 0

        for transaction in today {
            switch transaction.type {
            case .openingBalance, .adjustment:
                // A same-day opening/correction establishes the day's new
                // baseline instead of being treated as a cash purchase.
                baselineValue = transaction.quantity * transaction.price
            case .buy:
                buyGross += transaction.quantity * transaction.price
            case .sell, .clear:
                sellNet += transaction.quantity * transaction.price
            }
        }

        let endMarketValue = quote.price * currentQuantity
        let pnl = endMarketValue + sellNet - buyGross - baselineValue
        let basis = baselineValue + buyGross
        return (pnl, basis)
    }

    private static func isSameMarketDay(_ date: Date, asOf: Date, market: Market) -> Bool {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = market.timeZone
        return calendar.isDate(date, inSameDayAs: asOf)
    }

    /// 仅返回行情字典(供 ticker 使用)。
    func fetchQuotes(for symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        try await provider.fetch(symbols)
    }
}
