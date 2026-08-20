import Foundation
import GRDB

/// 数据库门面:统一持有 DatabasePool,负责 schema 迁移。
final class Database {
    let dbPool: DatabasePool

    init(path: String) throws {
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL;")
            try db.execute(sql: "PRAGMA foreign_keys = ON;")
        }
        self.dbPool = try DatabasePool(path: path, configuration: config)
        try Migrations.register(dbPool)
        Log.db.info("opened db at \(path, privacy: .public)")
    }

    /// 应用支持目录下的默认数据库路径。
    ///
    /// 目录名跟着 `CFBundleName`(Release 是 "StockBar",Debug 是 "StockBar-Dev"),
    /// 这样开发和正式版数据完全隔离,改 dev 的不会污染线上数据库。
    static func defaultPath() throws -> String {
        let fm = FileManager.default
        let folderName = appSupportFolderName()
        let base = try fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        ).appendingPathComponent(folderName, isDirectory: true)
        try fm.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("stockbar.sqlite").path
    }

    /// Release: "StockBar";Debug: "StockBar-Dev"。读 CFBundleName,fallback 到 "StockBar"。
    private static func appSupportFolderName() -> String {
        if let name = Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String,
           !name.isEmpty {
            return name
        }
        return "StockBar"
    }

}
