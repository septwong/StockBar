import Foundation

struct HoldingPosition: Identifiable, Equatable, Sendable {
    var id: UUID { holding.id }
    let holding: Holding
    let quote: Quote?
    /// Current market value in the holding's native currency.
    let marketValue: Decimal
    /// Unrealized P&L for the remaining shares in native currency.
    let unrealizedPnL: Decimal
    /// Realized P&L from completed sells/clears in native currency.
    let realizedPnL: Decimal
    /// Cumulative P&L = realized + unrealized in native currency.
    let pnl: Decimal
    /// Cumulative P&L percent against the broker-style adjusted cost base.
    let pnlPct: Double
    /// Dynamic cost price used by broker-style portfolio displays.
    /// `holding.costPrice` remains the true weighted-average acquisition cost.
    let adjustedCostPrice: Decimal
    /// Today's P&L including same-day buys and sells, excluding transaction fees.
    let todayPnL: Decimal
    /// Market value converted to base currency (nil if FX unavailable).
    let baseMarketValue: Decimal?
    let baseTodayPnL: Decimal?
    let basePnL: Decimal?
    let baseUnrealizedPnL: Decimal?
}

struct PortfolioSnapshot: Equatable, Sendable {
    let baseCurrency: Currency
    let totalAssets: Decimal      // sum of baseMarketValue
    let totalCost: Decimal        // remaining cost in base currency
    let historicalCostBase: Decimal
    /// Sum of adjusted costs for active positions. Used for the cumulative
    /// return percentage; historicalCostBase remains the fallback after all
    /// positions have been closed.
    let adjustedCostBase: Decimal
    let todayPnL: Decimal
    let todayPnLPct: Double
    let allTimePnL: Decimal
    let allTimePnLPct: Double
    let positions: [HoldingPosition]
    /// 全部本轮拉到的行情(持仓 + 自选合并),供菜单栏 ticker 和 Watchlist 行使用。
    let allQuotes: [SymbolID: Quote]
    let asOf: Date

    static let empty = PortfolioSnapshot(
        baseCurrency: .cny,
        totalAssets: 0,
        totalCost: 0,
        historicalCostBase: 0,
        adjustedCostBase: 0,
        todayPnL: 0,
        todayPnLPct: 0,
        allTimePnL: 0,
        allTimePnLPct: 0,
        positions: [],
        allQuotes: [:],
        asOf: Date()
    )
}
