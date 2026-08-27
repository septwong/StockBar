import Foundation
import GRDB

private struct IndexRecord: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "indexItem"

    var id: String
    var nameZh: String
    var nameEn: String
    var market: String
    var emSecid: String
    var tencentCode: String
    var currency: String
    var sortOrder: Int
    var createdAt: Date

    func toDomain() -> IndexDescriptor? {
        guard let market = Market(rawValue: market),
              let currency = Currency(rawValue: currency) else { return nil }
        return IndexDescriptor(
            id: id,
            nameZh: nameZh,
            nameEn: nameEn,
            market: market,
            emSecid: emSecid,
            tencentCode: tencentCode,
            currency: currency
        )
    }

    static func from(_ descriptor: IndexDescriptor, sortOrder: Int, createdAt: Date = Date()) -> IndexRecord {
        IndexRecord(
            id: descriptor.id,
            nameZh: descriptor.nameZh,
            nameEn: descriptor.nameEn,
            market: descriptor.market.rawValue,
            emSecid: descriptor.emSecid,
            tencentCode: descriptor.tencentCode,
            currency: descriptor.currency.rawValue,
            sortOrder: sortOrder,
            createdAt: createdAt
        )
    }
}

enum IndexRepositoryError: Error, Equatable {
    case nameRequired
    case tencentCodeRequired
    case eastMoneySecidRequired
    case duplicateTencentCode
    case duplicateEastMoneySecid
}

struct IndexRepository {
    let dbPool: DatabasePool

    func all() throws -> [IndexDescriptor] {
        try dbPool.read { db in
            try IndexRecord
                .order(Column("sortOrder").asc, Column("createdAt").asc)
                .fetchAll(db)
                .compactMap { $0.toDomain() }
        }
    }

    func upsert(_ descriptor: IndexDescriptor) throws {
        try dbPool.write { db in
            try validate(descriptor, in: db, excludingID: descriptor.id)
            let existing = try IndexRecord.fetchOne(db, key: descriptor.id)
            let order: Int
            if let existing {
                order = existing.sortOrder
            } else {
                order = try nextSortOrder(in: db)
            }
            let createdAt = existing?.createdAt ?? Date()
            try IndexRecord.from(descriptor, sortOrder: order, createdAt: createdAt).save(db)
        }
    }

    func delete(id: String) throws {
        _ = try dbPool.write { db in
            try IndexRecord.deleteOne(db, key: id)
        }
    }

    func reorder(ids: [String]) throws {
        try dbPool.write { db in
            for (order, id) in ids.enumerated() {
                try db.execute(
                    sql: "UPDATE indexItem SET sortOrder = ? WHERE id = ?",
                    arguments: [order, id]
                )
            }
        }
    }

    /// 只补回缺失的内置项，不覆盖已被用户编辑的内置项，也不删除自定义项。
    @discardableResult
    func restoreDefaults() throws -> [IndexDescriptor] {
        try dbPool.write { db in
            try Self.seedMissing(IndexCatalog.defaults, in: db)
        }
        return try all()
    }

    func replaceAll(_ descriptors: [IndexDescriptor], in db: GRDB.Database) throws {
        _ = try IndexRecord.deleteAll(db)
        for (order, descriptor) in descriptors.enumerated() {
            try validate(descriptor, in: db, excludingID: descriptor.id)
            try IndexRecord.from(descriptor, sortOrder: order).insert(db)
        }
    }

    static func seedDefaults(in db: GRDB.Database) throws {
        for (order, descriptor) in IndexCatalog.defaults.enumerated() {
            try IndexRecord.from(descriptor, sortOrder: order).insert(db)
        }
    }

    static func seedMissing(_ descriptors: [IndexDescriptor], in db: GRDB.Database) throws {
        for descriptor in descriptors {
            guard try IndexRecord.fetchOne(db, key: descriptor.id) == nil else { continue }
            let nextOrder = (try Int.fetchOne(
                db,
                sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM indexItem"
            )) ?? 0
            try IndexRecord.from(descriptor, sortOrder: nextOrder).insert(db)
        }
    }

    /// 在指定指数前插入缺失项，并为后续项目让出一个排序位置。
    static func insertMissing(
        _ descriptor: IndexDescriptor,
        beforeID: String,
        in db: GRDB.Database
    ) throws {
        guard try IndexRecord.fetchOne(db, key: descriptor.id) == nil else { return }

        let order = try IndexRecord.fetchOne(db, key: beforeID)?.sortOrder ??
            ((try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM indexItem")) ?? 0)
        try db.execute(
            sql: "UPDATE indexItem SET sortOrder = sortOrder + 1 WHERE sortOrder >= ?",
            arguments: [order]
        )
        try IndexRecord.from(descriptor, sortOrder: order).insert(db)
    }

    /// 将已有项目移动到指定项目之前，保留其余项目的相对顺序。
    static func move(id: String, beforeID: String, in db: GRDB.Database) throws {
        guard let source = try IndexRecord.fetchOne(db, key: id),
              let target = try IndexRecord.fetchOne(db, key: beforeID),
              source.id != target.id else { return }

        if source.sortOrder < target.sortOrder {
            guard source.sortOrder + 1 != target.sortOrder else { return }
            try db.execute(
                sql: """
                UPDATE indexItem
                SET sortOrder = sortOrder - 1
                WHERE sortOrder > ? AND sortOrder < ?
                """,
                arguments: [source.sortOrder, target.sortOrder]
            )
            try db.execute(
                sql: "UPDATE indexItem SET sortOrder = ? WHERE id = ?",
                arguments: [target.sortOrder - 1, id]
            )
        } else {
            try db.execute(
                sql: """
                UPDATE indexItem
                SET sortOrder = sortOrder + 1
                WHERE sortOrder >= ? AND sortOrder < ?
                """,
                arguments: [target.sortOrder, source.sortOrder]
            )
            try db.execute(
                sql: "UPDATE indexItem SET sortOrder = ? WHERE id = ?",
                arguments: [target.sortOrder, id]
            )
        }
    }

    func validate(_ descriptor: IndexDescriptor, excludingID: String? = nil) throws {
        try dbPool.read { db in
            try validate(descriptor, in: db, excludingID: excludingID)
        }
    }

    private func validate(
        _ descriptor: IndexDescriptor,
        in db: GRDB.Database,
        excludingID: String? = nil
    ) throws {
        guard !descriptor.nameZh.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
                !descriptor.nameEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndexRepositoryError.nameRequired
        }
        guard !descriptor.tencentCode.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndexRepositoryError.tencentCodeRequired
        }
        guard !descriptor.emSecid.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw IndexRepositoryError.eastMoneySecidRequired
        }

        let records = try IndexRecord.fetchAll(db)
        if records.contains(where: {
            $0.id != excludingID &&
            $0.tencentCode.caseInsensitiveCompare(descriptor.tencentCode) == .orderedSame
        }) {
            throw IndexRepositoryError.duplicateTencentCode
        }
        if records.contains(where: {
            $0.id != excludingID && $0.emSecid == descriptor.emSecid
        }) {
            throw IndexRepositoryError.duplicateEastMoneySecid
        }
    }

    private func nextSortOrder(in db: GRDB.Database) throws -> Int {
        (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(sortOrder), -1) + 1 FROM indexItem")) ?? 0
    }
}
