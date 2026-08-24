import Foundation

struct Holding: Equatable, Codable, Sendable, Identifiable {
    let id: UUID
    var symbol: SymbolID
    var name: String
    var quantity: Decimal
    var costPrice: Decimal
    var currency: Currency
    var note: String?
    var inTicker: Bool
    var sortOrder: Int
    var createdAt: Date

    init(
        id: UUID = UUID(),
        symbol: SymbolID,
        name: String,
        quantity: Decimal,
        costPrice: Decimal,
        currency: Currency? = nil,
        note: String? = nil,
        inTicker: Bool = true,
        sortOrder: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.symbol = symbol
        self.name = name
        self.quantity = quantity
        self.costPrice = costPrice
        self.currency = currency ?? symbol.market.defaultCurrency
        self.note = note
        self.inTicker = inTicker
        self.sortOrder = sortOrder
        self.createdAt = createdAt
    }
}

extension Holding {
    /// 今日盈亏的基准价。
    ///
    /// 当天新录入的持仓没有“昨日收盘时仍持有”的事实,因此用录入的成本价;
    /// 其余持仓使用行情提供的昨收价。部分行情源可能返回 0 作为缺失值,
    /// 这种情况退回当前价,避免把整笔市值误算成今日涨跌。
    func todayReferencePrice(for quote: Quote, asOf date: Date = Date()) -> Decimal {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = symbol.market.timeZone
        if calendar.isDate(createdAt, inSameDayAs: date) {
            return costPrice
        }
        return quote.prevClose > 0 ? quote.prevClose : quote.price
    }

    func todayPnL(for quote: Quote, asOf date: Date = Date()) -> Decimal {
        (quote.price - todayReferencePrice(for: quote, asOf: date)) * quantity
    }
}
