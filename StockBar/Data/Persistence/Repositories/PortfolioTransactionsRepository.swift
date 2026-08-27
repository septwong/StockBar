import Foundation
import GRDB

private struct PortfolioTransactionRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "portfolioTransaction"

    var id: String
    var holdingID: String
    var code: String
    var market: String
    var name: String
    var type: String
    var quantity: String
    var price: String
    var fee: String
    var feeStatus: String
    var feeUpdatedAt: Date?
    var currency: String
    var occurredAt: Date
    var recordedAt: Date
    var note: String?

    func toDomain() -> PortfolioTransaction? {
        guard let id = UUID(uuidString: id),
              let holdingID = UUID(uuidString: holdingID),
              let market = Market(rawValue: market),
              let type = PortfolioTransactionType(rawValue: type),
              let feeStatus = PortfolioTransactionFeeStatus(rawValue: feeStatus),
              let currency = Currency(rawValue: currency),
              let quantity = Decimal(string: quantity),
              let price = Decimal(string: price) else { return nil }
        return PortfolioTransaction(
            id: id,
            holdingID: holdingID,
            symbol: SymbolID(code: code, market: market),
            name: name,
            type: type,
            quantity: quantity,
            price: price,
            fee: Decimal(string: fee) ?? 0,
            feeStatus: feeStatus,
            feeUpdatedAt: feeUpdatedAt,
            currency: currency,
            occurredAt: occurredAt,
            recordedAt: recordedAt,
            note: note
        )
    }

    static func from(_ transaction: PortfolioTransaction) -> PortfolioTransactionRecord {
        PortfolioTransactionRecord(
            id: transaction.id.uuidString,
            holdingID: transaction.holdingID.uuidString,
            code: transaction.symbol.code,
            market: transaction.symbol.market.rawValue,
            name: transaction.name,
            type: transaction.type.rawValue,
            quantity: "\(transaction.quantity)",
            price: "\(transaction.price)",
            fee: "\(transaction.fee)",
            feeStatus: transaction.feeStatus.rawValue,
            feeUpdatedAt: transaction.feeUpdatedAt,
            currency: transaction.currency.rawValue,
            occurredAt: transaction.occurredAt,
            recordedAt: transaction.recordedAt,
            note: transaction.note
        )
    }
}

struct PortfolioTransactionsRepository {
    let dbPool: DatabasePool

    func all() throws -> [PortfolioTransaction] {
        try dbPool.read { db in try Self.all(in: db) }
    }

    func all(for holdingID: UUID) throws -> [PortfolioTransaction] {
        try dbPool.read { db in try Self.all(for: holdingID, in: db) }
    }

    func insert(_ transaction: PortfolioTransaction) throws {
        try dbPool.write { db in try Self.insert(transaction, in: db) }
    }

    @discardableResult
    func updateFee(
        transactionID: UUID,
        fee: Decimal,
        status: PortfolioTransactionFeeStatus = .confirmed,
        updatedAt: Date = Date()
    ) throws -> PortfolioTransaction? {
        try dbPool.write { db in
            try Self.updateFee(
                transactionID: transactionID,
                fee: fee,
                status: status,
                updatedAt: updatedAt,
                in: db
            )
        }
    }

    func deleteAll() throws {
        try dbPool.write { db in try Self.deleteAll(in: db) }
    }

    func deleteAll(for holdingID: UUID) throws {
        try dbPool.write { db in
            try Self.deleteAll(for: holdingID, in: db)
        }
    }

    func deleteAll(for holdingID: UUID, in db: GRDB.Database) throws {
        try Self.deleteAll(for: holdingID, in: db)
    }

    func replaceAll(_ transactions: [PortfolioTransaction], in db: GRDB.Database) throws {
        try Self.deleteAll(in: db)
        for transaction in transactions {
            try Self.insert(transaction, in: db)
        }
    }

    static func all(in db: GRDB.Database) throws -> [PortfolioTransaction] {
        try PortfolioTransactionRecord
            .order(Column("occurredAt").asc, Column("recordedAt").asc)
            .fetchAll(db)
            .compactMap { $0.toDomain() }
    }

    static func all(for holdingID: UUID, in db: GRDB.Database) throws -> [PortfolioTransaction] {
        try PortfolioTransactionRecord
            .filter(Column("holdingID") == holdingID.uuidString)
            .order(Column("occurredAt").asc, Column("recordedAt").asc)
            .fetchAll(db)
            .compactMap { $0.toDomain() }
    }

    static func insert(_ transaction: PortfolioTransaction, in db: GRDB.Database) throws {
        try PortfolioTransactionRecord.from(transaction).insert(db)
    }

    static func updateFee(
        transactionID: UUID,
        fee: Decimal,
        status: PortfolioTransactionFeeStatus,
        updatedAt: Date,
        in db: GRDB.Database
    ) throws -> PortfolioTransaction? {
        guard var record = try PortfolioTransactionRecord.fetchOne(db, key: transactionID.uuidString) else {
            return nil
        }
        record.fee = "\(fee)"
        record.feeStatus = status.rawValue
        record.feeUpdatedAt = updatedAt
        try record.update(db)
        return record.toDomain()
    }

    static func delete(id: UUID, in db: GRDB.Database) throws -> Bool {
        try PortfolioTransactionRecord.deleteOne(db, key: id.uuidString)
    }

    static func deleteAll(in db: GRDB.Database) throws {
        try PortfolioTransactionRecord.deleteAll(db)
    }

    static func deleteAll(for holdingID: UUID, in db: GRDB.Database) throws {
        try PortfolioTransactionRecord
            .filter(Column("holdingID") == holdingID.uuidString)
            .deleteAll(db)
    }
}
