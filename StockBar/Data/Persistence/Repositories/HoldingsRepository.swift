import Foundation
import GRDB

/// 内部 GRDB record。
private struct HoldingRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "holding"

    var id: String
    var code: String
    var market: String
    var name: String
    var quantity: String
    var costPrice: String
    var currency: String
    var note: String?
    var inTicker: Bool
    var sortOrder: Int
    var createdAt: Date

    func toDomain() -> Holding? {
        guard let market = Market(rawValue: market),
              let currency = Currency(rawValue: currency),
              let quantity = Decimal(string: quantity),
              let cost = Decimal(string: costPrice),
              let id = UUID(uuidString: id) else { return nil }
        return Holding(
            id: id,
            symbol: SymbolID(code: code, market: market),
            name: name,
            quantity: quantity,
            costPrice: cost,
            currency: currency,
            note: note,
            inTicker: inTicker,
            sortOrder: sortOrder,
            createdAt: createdAt
        )
    }

    static func from(_ h: Holding) -> HoldingRecord {
        HoldingRecord(
            id: h.id.uuidString,
            code: h.symbol.code,
            market: h.symbol.market.rawValue,
            name: h.name,
            quantity: "\(h.quantity)",
            costPrice: "\(h.costPrice)",
            currency: h.currency.rawValue,
            note: h.note,
            inTicker: h.inTicker,
            sortOrder: h.sortOrder,
            createdAt: h.createdAt
        )
    }
}

struct HoldingsRepository {
    let dbPool: DatabasePool

    func all() throws -> [Holding] {
        try allIncludingClosed().filter { $0.quantity > 0 }
    }

    func allIncludingClosed() throws -> [Holding] {
        try dbPool.read { db in
            // sortOrder 优先,相同 order(没拖过)再按 createdAt 升序兜底
            try HoldingRecord
                .order(Column("sortOrder").asc, Column("createdAt").asc)
                .fetchAll(db)
        }.compactMap { $0.toDomain() }
    }

    func upsert(_ holding: Holding) throws {
        try dbPool.write { db in
            try Self.upsert(holding, in: db)
        }
    }

    /// Updates only editable metadata. Quantity, cost and symbol are
    /// deliberately excluded so a stale settings row cannot overwrite a
    /// newer transaction materialized by PortfolioOperationService.
    func updateMetadata(from holding: Holding) throws {
        try dbPool.write { db in
            try Self.updateMetadata(from: holding, in: db)
        }
    }

    func find(id: UUID, includingClosed: Bool = true) throws -> Holding? {
        try dbPool.read { db in
            try Self.find(id: id, includingClosed: includingClosed, in: db)
        }
    }

    func find(symbol: SymbolID, includingClosed: Bool = true) throws -> Holding? {
        try dbPool.read { db in
            try Self.find(symbol: symbol, includingClosed: includingClosed, in: db)
        }
    }

    static func upsert(_ holding: Holding, in db: GRDB.Database) throws {
        try HoldingRecord.from(holding).save(db)
    }

    static func updateMetadata(from holding: Holding, in db: GRDB.Database) throws {
        try db.execute(
            sql: "UPDATE holding SET name = ?, note = ?, inTicker = ? WHERE id = ?",
            arguments: [holding.name, holding.note, holding.inTicker, holding.id.uuidString]
        )
    }

    static func find(id: UUID, includingClosed: Bool = true, in db: GRDB.Database) throws -> Holding? {
        let record = try HoldingRecord.fetchOne(db, key: id.uuidString)
        guard let holding = record?.toDomain() else { return nil }
        return includingClosed || holding.quantity > 0 ? holding : nil
    }

    static func find(symbol: SymbolID, includingClosed: Bool = true, in db: GRDB.Database) throws -> Holding? {
        let record = try HoldingRecord
            .filter(Column("code") == symbol.code && Column("market") == symbol.market.rawValue)
            .order(Column("quantity").desc, Column("sortOrder").asc)
            .fetchOne(db)
        guard let holding = record?.toDomain() else { return nil }
        return includingClosed || holding.quantity > 0 ? holding : nil
    }

    func delete(id: UUID) throws {
        _ = try dbPool.write { db in
            try Self.delete(id: id, in: db)
        }
    }

    static func delete(id: UUID, in db: GRDB.Database) throws {
        _ = try HoldingRecord.deleteOne(db, key: id.uuidString)
    }

    func deleteAll() throws {
        _ = try dbPool.write { db in
            try Self.deleteAll(in: db)
        }
    }

    static func deleteAll(in db: GRDB.Database) throws {
        _ = try HoldingRecord.deleteAll(db)
    }

    func replaceAll(_ holdings: [Holding], in db: GRDB.Database) throws {
        _ = try HoldingRecord.deleteAll(db)
        for holding in holdings {
            try HoldingRecord.from(holding).insert(db)
        }
    }

    /// 用户拖拽改顺序后,把当前完整 id 序列 → 各自 sortOrder = 数组下标。
    /// 一次性 batch 写,避免 N 次写盘。
    func reorder(ids: [UUID]) throws {
        try dbPool.write { db in
            for (i, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE holding SET sortOrder = ? WHERE id = ?",
                    arguments: [i, id.uuidString]
                )
            }
        }
    }

    /// 提供给 SwiftUI 的 Combine-style 监听(简化版,改为 ObservableObject 自己 poll)。
    func observeAll() -> AsyncStream<[Holding]> {
        AsyncStream { continuation in
            let observation = ValueObservation.tracking { db -> [Holding] in
                try HoldingRecord
                    .order(Column("sortOrder").asc, Column("createdAt").asc)
                    .fetchAll(db)
                    .compactMap { $0.toDomain() }
                    .filter { $0.quantity > 0 }
            }
            let cancellable = observation.start(in: dbPool, onError: { _ in }) { holdings in
                continuation.yield(holdings)
            }
            continuation.onTermination = { @Sendable _ in
                cancellable.cancel()
            }
        }
    }
}
