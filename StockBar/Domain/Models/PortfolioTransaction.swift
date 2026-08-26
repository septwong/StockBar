import Foundation

enum PortfolioTransactionType: String, Codable, CaseIterable, Sendable {
    case openingBalance
    case buy
    case sell
    case clear
    case adjustment

    var isSellLike: Bool {
        self == .sell || self == .clear
    }
}

enum PortfolioTransactionFeeStatus: String, Codable, CaseIterable, Sendable {
    case estimated
    case confirmed
}

/// One portfolio operation. Trade details remain stable after entry, while
/// the settlement fee may be corrected later; occurredAt is an absolute
/// instant rendered in the security market's time zone by the UI.
struct PortfolioTransaction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let holdingID: UUID
    let symbol: SymbolID
    let name: String
    let type: PortfolioTransactionType
    /// For buy/sell/clear this is the executed quantity. For opening and
    /// adjustment it is the target quantity after the operation.
    let quantity: Decimal
    /// For trades this is the execution price. For opening and adjustment it
    /// is the target average cost price.
    let price: Decimal
    let fee: Decimal
    let feeStatus: PortfolioTransactionFeeStatus
    let feeUpdatedAt: Date?
    let currency: Currency
    let occurredAt: Date
    let recordedAt: Date
    let note: String?

    init(
        id: UUID = UUID(),
        holdingID: UUID,
        symbol: SymbolID,
        name: String,
        type: PortfolioTransactionType,
        quantity: Decimal,
        price: Decimal,
        fee: Decimal = 0,
        feeStatus: PortfolioTransactionFeeStatus = .confirmed,
        feeUpdatedAt: Date? = nil,
        currency: Currency? = nil,
        occurredAt: Date = Date(),
        recordedAt: Date = Date(),
        note: String? = nil
    ) {
        self.id = id
        self.holdingID = holdingID
        self.symbol = symbol
        self.name = name
        self.type = type
        self.quantity = quantity
        self.price = price
        self.fee = fee
        self.feeStatus = feeStatus
        self.feeUpdatedAt = feeUpdatedAt
        self.currency = currency ?? symbol.market.defaultCurrency
        self.occurredAt = occurredAt
        self.recordedAt = recordedAt
        self.note = note
    }

    private enum CodingKeys: String, CodingKey {
        case id, holdingID, symbol, name, type, quantity, price, fee, feeStatus,
             feeUpdatedAt, currency, occurredAt, recordedAt, note
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = try values.decode(UUID.self, forKey: .id)
        holdingID = try values.decode(UUID.self, forKey: .holdingID)
        symbol = try values.decode(SymbolID.self, forKey: .symbol)
        name = try values.decode(String.self, forKey: .name)
        type = try values.decode(PortfolioTransactionType.self, forKey: .type)
        quantity = try values.decode(Decimal.self, forKey: .quantity)
        price = try values.decode(Decimal.self, forKey: .price)
        fee = try values.decode(Decimal.self, forKey: .fee)
        feeStatus = try values.decodeIfPresent(PortfolioTransactionFeeStatus.self, forKey: .feeStatus) ?? .confirmed
        feeUpdatedAt = try values.decodeIfPresent(Date.self, forKey: .feeUpdatedAt)
        currency = try values.decode(Currency.self, forKey: .currency)
        occurredAt = try values.decode(Date.self, forKey: .occurredAt)
        recordedAt = try values.decode(Date.self, forKey: .recordedAt)
        note = try values.decodeIfPresent(String.self, forKey: .note)
    }
}

struct PortfolioTransactionEntry: Identifiable, Equatable, Sendable {
    let transaction: PortfolioTransaction
    let realizedPnL: Decimal
    let quantityAfter: Decimal
    let averageCostAfter: Decimal

    var id: UUID { transaction.id }
}

struct PortfolioLedgerSummary: Equatable, Sendable {
    let quantity: Decimal
    let costAmount: Decimal
    let realizedPnL: Decimal
    let historicalCostBase: Decimal
    let entries: [PortfolioTransactionEntry]

    var averageCost: Decimal {
        guard quantity > 0 else { return 0 }
        return costAmount / quantity
    }

    /// 券商常见的动态成本金额:把已实现盈亏摊回剩余持仓。
    ///
    /// `costAmount` 仍然是实际剩余持仓的加权买入成本,只用于账本和
    /// 后续交易计算。动态成本只用于展示和收益率分母,不会反向写入
    /// `Holding.costPrice`。
    var adjustedCostAmount: Decimal {
        costAmount - realizedPnL
    }

    /// 与同花顺“成本”列相同语义的动态成本价。
    var adjustedCostPrice: Decimal {
        guard quantity > 0 else { return 0 }
        return adjustedCostAmount / quantity
    }
}

enum PortfolioLedgerError: Error, Equatable {
    case invalidQuantity
    case invalidPrice
    case invalidFee
    case oversell
}

enum PortfolioLedger {
    static func replay(_ transactions: [PortfolioTransaction]) throws -> PortfolioLedgerSummary {
        let sorted = transactions.sorted { lhs, rhs in
            if lhs.occurredAt != rhs.occurredAt { return lhs.occurredAt < rhs.occurredAt }
            if lhs.recordedAt != rhs.recordedAt { return lhs.recordedAt < rhs.recordedAt }
            return lhs.id.uuidString < rhs.id.uuidString
        }

        var quantity: Decimal = 0
        var costAmount: Decimal = 0
        var realizedPnL: Decimal = 0
        var historicalCostBase: Decimal = 0
        var entries: [PortfolioTransactionEntry] = []

        for transaction in sorted {
            let allowsZeroQuantity = transaction.type == .openingBalance || transaction.type == .adjustment
            let quantityIsValid = allowsZeroQuantity ? transaction.quantity >= 0 : transaction.quantity > 0
            guard quantityIsValid else { throw PortfolioLedgerError.invalidQuantity }
            let allowsZeroPrice = allowsZeroQuantity && transaction.quantity == 0
            let priceIsValid = allowsZeroPrice ? transaction.price >= 0 : transaction.price > 0
            guard priceIsValid else { throw PortfolioLedgerError.invalidPrice }
            guard transaction.fee >= 0 else { throw PortfolioLedgerError.invalidFee }

            var entryRealized: Decimal = 0

            switch transaction.type {
            case .openingBalance, .adjustment:
                // These operations establish or correct a position baseline;
                // they do not represent a sale and therefore realize no P&L.
                quantity = transaction.quantity
                costAmount = transaction.quantity * transaction.price
                if transaction.type == .openingBalance {
                    historicalCostBase += costAmount
                }

            case .buy:
                let grossCost = transaction.quantity * transaction.price + transaction.fee
                quantity += transaction.quantity
                costAmount += grossCost
                historicalCostBase += grossCost

            case .sell, .clear:
                guard transaction.quantity <= quantity else { throw PortfolioLedgerError.oversell }
                let averageCost = quantity > 0 ? costAmount / quantity : 0
                entryRealized = transaction.quantity * transaction.price
                    - transaction.fee
                    - transaction.quantity * averageCost
                realizedPnL += entryRealized
                quantity -= transaction.quantity
                costAmount -= transaction.quantity * averageCost
                if quantity == 0 { costAmount = 0 }
            }

            entries.append(PortfolioTransactionEntry(
                transaction: transaction,
                realizedPnL: entryRealized,
                quantityAfter: quantity,
                averageCostAfter: quantity > 0 ? costAmount / quantity : 0
            ))
        }

        return PortfolioLedgerSummary(
            quantity: quantity,
            costAmount: costAmount,
            realizedPnL: realizedPnL,
            historicalCostBase: historicalCostBase,
            entries: entries
        )
    }
}
