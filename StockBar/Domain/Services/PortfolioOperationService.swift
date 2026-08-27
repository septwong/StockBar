import Foundation
import GRDB

enum PortfolioOperationError: Error, Equatable, LocalizedError {
    case invalidQuantity
    case invalidPrice
    case invalidFee
    case noTransaction
    case noHolding
    case noActivePosition
    case oversell
    case invalidOperation

    var errorDescription: String? {
        switch self {
        case .invalidQuantity: return "Quantity must be greater than zero."
        case .invalidPrice: return "Price must be greater than zero."
        case .invalidFee: return "Fee must not be negative."
        case .noTransaction: return "The transaction could not be found."
        case .noHolding: return "The holding could not be found."
        case .noActivePosition: return "There is no active position."
        case .oversell: return "Sell quantity cannot exceed the available position."
        case .invalidOperation: return "The portfolio operation is invalid."
        }
    }
}

/// Applies portfolio operations atomically and materializes the current
/// Holding row from its transaction history.
struct PortfolioOperationService {
    let dbPool: DatabasePool

    init(dbPool: DatabasePool) {
        self.dbPool = dbPool
    }

    @discardableResult
    func buy(
        symbol: SymbolID,
        name: String,
        quantity: Decimal,
        price: Decimal,
        fee: Decimal = 0,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> Holding {
        try validate(quantity: quantity, price: price, fee: fee)
        return try dbPool.write { db in
            let existing = try HoldingsRepository.find(symbol: symbol, includingClosed: true, in: db)
            let holding: Holding
            if let existing, existing.quantity > 0 {
                holding = existing
            } else {
                if let existing {
                    try PortfolioTransactionsRepository.deleteAll(for: existing.id, in: db)
                    try HoldingsRepository.delete(id: existing.id, in: db)
                }
                holding = Holding(
                    symbol: symbol,
                    name: name.isEmpty ? symbol.code : name,
                    quantity: 0,
                    costPrice: price,
                    currency: symbol.market.defaultCurrency,
                    createdAt: occurredAt
                )
            }
            let transaction = PortfolioTransaction(
                holdingID: holding.id,
                symbol: symbol,
                name: name.isEmpty ? holding.name : name,
                type: .buy,
                quantity: quantity,
                price: price,
                fee: fee,
                feeStatus: .estimated,
                currency: holding.currency,
                occurredAt: occurredAt,
                note: note
            )
            try PortfolioTransactionsRepository.insert(transaction, in: db)
            return try materialize(holding, preferredName: name, in: db)
        }
    }

    @discardableResult
    func sell(
        holdingID: UUID,
        quantity: Decimal,
        price: Decimal,
        fee: Decimal = 0,
        occurredAt: Date = Date(),
        note: String? = nil
    ) throws -> Holding {
        try validate(quantity: quantity, price: price, fee: fee)
        return try dbPool.write { db in
            guard let holding = try HoldingsRepository.find(id: holdingID, includingClosed: true, in: db) else {
                throw PortfolioOperationError.noHolding
            }
            let recordedAt = Date()
            let transactionID = UUID()
            let existingTransactions = try PortfolioTransactionsRepository.all(for: holding.id, in: db)
            let stateBefore = try state(
                before: existingTransactions,
                occurredAt: occurredAt,
                recordedAt: recordedAt,
                transactionID: transactionID
            )
            guard stateBefore.quantity > 0 else { throw PortfolioOperationError.noActivePosition }
            guard quantity <= stateBefore.quantity else { throw PortfolioOperationError.oversell }
            let transaction = PortfolioTransaction(
                id: transactionID,
                holdingID: holding.id,
                symbol: holding.symbol,
                name: holding.name,
                type: .sell,
                quantity: quantity,
                price: price,
                fee: fee,
                feeStatus: .estimated,
                currency: holding.currency,
                occurredAt: occurredAt,
                recordedAt: recordedAt,
                note: note
            )
            try PortfolioTransactionsRepository.insert(transaction, in: db)
            return try materialize(holding, in: db)
        }
    }

    /// Ends the current position cycle by removing its snapshot and ledger.
    /// The next buy for the same symbol therefore starts a fresh position.
    func clear(holdingID: UUID) throws {
        try dbPool.write { db in
            guard let holding = try HoldingsRepository.find(id: holdingID, includingClosed: true, in: db) else {
                throw PortfolioOperationError.noHolding
            }
            guard holding.quantity > 0 else { throw PortfolioOperationError.noActivePosition }
            try PortfolioTransactionsRepository.deleteAll(for: holding.id, in: db)
            try HoldingsRepository.delete(id: holding.id, in: db)
        }
    }

    /// Imports one CSV snapshot without changing the import's original
    /// per-symbol merge semantics. An imported symbol starts a fresh ledger
    /// snapshot; symbols not present in the CSV remain untouched.
    @discardableResult
    func recordImportedHolding(_ imported: Holding) throws -> Holding {
        guard imported.quantity >= 0 else { throw PortfolioOperationError.invalidQuantity }
        guard imported.costPrice >= 0 else { throw PortfolioOperationError.invalidPrice }
        return try dbPool.write { db in
            let existing = try HoldingsRepository.find(symbol: imported.symbol, includingClosed: true, in: db)
            var holding = existing ?? imported
            if let existing {
                holding.name = imported.name.isEmpty ? existing.name : imported.name
                holding.note = imported.note
                holding.currency = imported.currency
                holding.inTicker = imported.inTicker
                holding.sortOrder = imported.sortOrder
                try PortfolioTransactionsRepository.deleteAll(for: existing.id, in: db)
            }
            let transaction = PortfolioTransaction(
                holdingID: holding.id,
                symbol: holding.symbol,
                name: holding.name,
                type: .openingBalance,
                quantity: imported.quantity,
                price: imported.costPrice,
                currency: imported.currency,
                occurredAt: imported.createdAt,
                note: imported.note
            )
            try PortfolioTransactionsRepository.insert(transaction, in: db)
            return try materialize(holding, in: db)
        }
    }

    func history(for holdingID: UUID) throws -> [PortfolioTransactionEntry] {
        let transactions = try PortfolioTransactionsRepository(dbPool: dbPool).all(for: holdingID)
        return try PortfolioLedger.replay(transactions).entries.reversed()
    }

    /// Replaces the fee on an existing buy/sell transaction after the
    /// broker settles it. The original transaction ID and trade details stay
    /// unchanged; the ledger and materialized holding are replayed atomically.
    @discardableResult
    func updateFee(transactionID: UUID, fee: Decimal) throws -> Holding {
        guard fee >= 0 else { throw PortfolioOperationError.invalidFee }
        return try dbPool.write { db in
            let transactions = try PortfolioTransactionsRepository.all(in: db)
            guard let existing = transactions.first(where: { $0.id == transactionID }) else {
                throw PortfolioOperationError.noTransaction
            }
            guard existing.type == .buy || existing.type == .sell else {
                throw PortfolioOperationError.invalidOperation
            }
            guard let holding = try HoldingsRepository.find(
                id: existing.holdingID,
                includingClosed: true,
                in: db
            ) else {
                throw PortfolioOperationError.noHolding
            }
            guard try PortfolioTransactionsRepository.updateFee(
                transactionID: transactionID,
                fee: fee,
                status: .confirmed,
                updatedAt: Date(),
                in: db
            ) != nil else {
                throw PortfolioOperationError.noTransaction
            }
            return try materialize(holding, in: db)
        }
    }

    /// Deletes one transaction and rebuilds the materialized holding from the
    /// remaining history. The write transaction rolls back if the remaining
    /// history is no longer valid (for example, a later sell would oversell).
    @discardableResult
    func deleteTransaction(transactionID: UUID) throws -> Holding {
        try dbPool.write { db in
            let transactions = try PortfolioTransactionsRepository.all(in: db)
            guard let transaction = transactions.first(where: { $0.id == transactionID }) else {
                throw PortfolioOperationError.noTransaction
            }
            guard let holding = try HoldingsRepository.find(
                id: transaction.holdingID,
                includingClosed: true,
                in: db
            ) else {
                throw PortfolioOperationError.noHolding
            }
            guard try PortfolioTransactionsRepository.delete(id: transactionID, in: db) else {
                throw PortfolioOperationError.noTransaction
            }
            return try materialize(holding, in: db)
        }
    }

    func deleteHoldingAndHistory(id: UUID) throws {
        try dbPool.write { db in
            try PortfolioTransactionsRepository(dbPool: dbPool).deleteAll(for: id, in: db)
            try HoldingsRepository.delete(id: id, in: db)
        }
    }

    private func materialize(
        _ holding: Holding,
        preferredName: String? = nil,
        in db: GRDB.Database
    ) throws -> Holding {
        let transactions = try PortfolioTransactionsRepository.all(for: holding.id, in: db)
        let summary: PortfolioLedgerSummary
        do {
            summary = try PortfolioLedger.replay(transactions)
        } catch PortfolioLedgerError.oversell {
            throw PortfolioOperationError.oversell
        } catch {
            throw PortfolioOperationError.invalidOperation
        }

        var updated = holding
        updated.quantity = summary.quantity
        updated.costPrice = summary.averageCost
        if let preferredName, !preferredName.isEmpty {
            updated.name = preferredName
        }
        try HoldingsRepository.upsert(updated, in: db)
        return updated
    }

    private func state(
        before transactions: [PortfolioTransaction],
        occurredAt: Date,
        recordedAt: Date,
        transactionID: UUID
    ) throws -> PortfolioLedgerSummary {
        let prior = transactions.filter { transaction in
            if transaction.occurredAt != occurredAt {
                return transaction.occurredAt < occurredAt
            }
            if transaction.recordedAt != recordedAt {
                return transaction.recordedAt < recordedAt
            }
            return transaction.id.uuidString < transactionID.uuidString
        }
        return try PortfolioLedger.replay(prior)
    }

    private func validate(quantity: Decimal, price: Decimal, fee: Decimal) throws {
        guard quantity > 0 else { throw PortfolioOperationError.invalidQuantity }
        guard price > 0 else { throw PortfolioOperationError.invalidPrice }
        guard fee >= 0 else { throw PortfolioOperationError.invalidFee }
    }

}
