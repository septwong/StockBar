import Foundation
import GRDB

enum Migrations {
    static func register(_ dbPool: DatabasePool) throws {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.create(table: "holding") { t in
                t.column("id", .text).primaryKey()
                t.column("code", .text).notNull()
                t.column("market", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("quantity", .text).notNull()      // Decimal 序列化为字符串保证精度
                t.column("costPrice", .text).notNull()
                t.column("currency", .text).notNull()
                t.column("note", .text)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "watchItem") { t in
                t.column("id", .text).primaryKey()
                t.column("code", .text).notNull()
                t.column("market", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("order", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }

            try db.create(table: "appSetting") { t in
                t.column("key", .text).primaryKey()
                t.column("value", .text).notNull()
            }

            try db.create(table: "fxCache") { t in
                t.column("pair", .text).primaryKey()
                t.column("rate", .text).notNull()
                t.column("asOf", .datetime).notNull()
            }
        }

        migrator.registerMigration("v2_alerts") { db in
            try db.create(table: "alert") { t in
                t.column("id", .text).primaryKey()
                t.column("code", .text).notNull()
                t.column("market", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("condition", .text).notNull()
                t.column("threshold", .text).notNull()
                t.column("isActive", .boolean).notNull().defaults(to: true)
                t.column("lastTriggeredAt", .datetime)
                t.column("cooldownSeconds", .integer).notNull().defaults(to: 300)
                t.column("createdAt", .datetime).notNull()
            }
        }

        migrator.registerMigration("v3_in_ticker") { db in
            try db.alter(table: "holding") { t in
                t.add(column: "inTicker", .boolean).notNull().defaults(to: true)
            }
            try db.alter(table: "watchItem") { t in
                t.add(column: "inTicker", .boolean).notNull().defaults(to: true)
            }
        }

        migrator.registerMigration("v4_alert_advanced") { db in
            try db.alter(table: "alert") { t in
                t.add(column: "secondaryCondition", .text)
                t.add(column: "secondaryThreshold", .text)
                t.add(column: "conditionLogic", .text).notNull().defaults(to: "and")
                t.add(column: "maxTriggersPerDay", .integer)            // null = 无限
                t.add(column: "triggerCountToday", .integer).notNull().defaults(to: 0)
                t.add(column: "lastTriggerDay", .text)                  // "YYYY-MM-DD"
                t.add(column: "tradingHoursOnly", .boolean).notNull().defaults(to: false)
                t.add(column: "weekdaysOnly", .boolean).notNull().defaults(to: false)
            }
        }

        // 行情磁盘缓存:首次打开 popover 时用,避免空列表等网络
        migrator.registerMigration("v5_quote_cache") { db in
            try db.create(table: "quoteCache") { t in
                t.column("symbolKey", .text).primaryKey()    // SymbolID.storageKey
                t.column("code", .text).notNull()
                t.column("market", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("price", .text).notNull()           // Decimal
                t.column("prevClose", .text).notNull()
                t.column("currency", .text).notNull()
                t.column("isClosed", .boolean).notNull().defaults(to: false)
                t.column("asOf", .datetime).notNull()
            }
        }

        // 持仓加 sortOrder 列(自选已经有 order),用户可拖拽改顺序
        migrator.registerMigration("v6_holding_sort_order") { db in
            try db.alter(table: "holding") { t in
                t.add(column: "sortOrder", .integer).notNull().defaults(to: 0)
            }
            // 初始化:按 createdAt 升序给 sortOrder 0,1,2...,这样老用户拖前的默认顺序
            // 跟之前看到的一致,不会一更新就乱
            let ids = try String.fetchAll(db, sql: "SELECT id FROM holding ORDER BY createdAt ASC")
            for (i, id) in ids.enumerated() {
                try db.execute(sql: "UPDATE holding SET sortOrder = ? WHERE id = ?", arguments: [i, id])
            }
        }

        // 用户可配置的大盘指数。内置项沿用原来的稳定 ID,这样已有
        // ticker_index_ids 不需要迁移就能继续匹配。
        migrator.registerMigration("v7_index_items") { db in
            try db.create(table: "indexItem") { t in
                t.column("id", .text).primaryKey()
                t.column("nameZh", .text).notNull().defaults(to: "")
                t.column("nameEn", .text).notNull().defaults(to: "")
                t.column("market", .text).notNull()
                t.column("emSecid", .text).notNull()
                t.column("tencentCode", .text).notNull()
                t.column("currency", .text).notNull()
                t.column("sortOrder", .integer).notNull().defaults(to: 0)
                t.column("createdAt", .datetime).notNull()
            }
            try IndexRepository.seedDefaults(in: db)
        }

        // Portfolio operations are kept separately from the materialized
        // holding row so buys/sells can preserve realized P&L and history.
        migrator.registerMigration("v8_portfolio_transactions") { db in
            try db.create(table: "portfolioTransaction") { t in
                t.column("id", .text).primaryKey()
                t.column("holdingID", .text).notNull()
                t.column("code", .text).notNull()
                t.column("market", .text).notNull()
                t.column("name", .text).notNull().defaults(to: "")
                t.column("type", .text).notNull()
                t.column("quantity", .text).notNull()
                t.column("price", .text).notNull()
                t.column("fee", .text).notNull().defaults(to: "0")
                t.column("currency", .text).notNull()
                t.column("occurredAt", .datetime).notNull()
                t.column("recordedAt", .datetime).notNull()
                t.column("note", .text)
            }
            try db.create(
                index: "portfolioTransaction_holding_time",
                on: "portfolioTransaction",
                columns: ["holdingID", "occurredAt", "recordedAt"]
            )

            let rows = try Row.fetchAll(db, sql: """
                SELECT id, code, market, name, quantity, costPrice, currency, note, createdAt
                FROM holding
                """)
            for row in rows {
                let holdingID: String = row["id"]
                let createdAt: Date = row["createdAt"]
                try db.execute(
                    sql: """
                    INSERT INTO portfolioTransaction
                    (id, holdingID, code, market, name, type, quantity, price, fee,
                     currency, occurredAt, recordedAt, note)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                    arguments: [
                        UUID().uuidString,
                        holdingID,
                        row["code"] as String,
                        row["market"] as String,
                        row["name"] as String,
                        PortfolioTransactionType.openingBalance.rawValue,
                        row["quantity"] as String,
                        row["costPrice"] as String,
                        "0",
                        row["currency"] as String,
                        createdAt,
                        createdAt,
                        row["note"] as String?
                    ]
                )
            }
        }

        migrator.registerMigration("v9_transaction_fee_settlement") { db in
            try db.alter(table: "portfolioTransaction") { t in
                t.add(column: "feeStatus", .text).notNull().defaults(to: PortfolioTransactionFeeStatus.confirmed.rawValue)
                t.add(column: "feeUpdatedAt", .datetime)
            }
        }

        try migrator.migrate(dbPool)
    }
}
