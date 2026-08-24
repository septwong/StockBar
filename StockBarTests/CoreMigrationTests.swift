import XCTest
import GRDB
@testable import StockBar

final class CoreMigrationTests: XCTestCase {
    private var database: StockBar.Database!
    private var databasePath: String!

    override func setUpWithError() throws {
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-tests-\(UUID().uuidString).sqlite")
            .path
        database = try StockBar.Database(path: databasePath)
    }

    override func tearDownWithError() throws {
        database = nil
        for suffix in ["", "-wal", "-shm"] {
            try? FileManager.default.removeItem(atPath: databasePath + suffix)
        }
        databasePath = nil
    }

    func testMigrationsCreateCurrentSchema() throws {
        let tables = try database.dbPool.read { db in
            try String.fetchAll(
                db,
                sql: "SELECT name FROM sqlite_master WHERE type = 'table' ORDER BY name"
            )
        }

        XCTAssertTrue(tables.contains("holding"))
        XCTAssertTrue(tables.contains("watchItem"))
        XCTAssertTrue(tables.contains("appSetting"))
        XCTAssertTrue(tables.contains("alert"))
        XCTAssertTrue(tables.contains("quoteCache"))
        XCTAssertTrue(tables.contains("indexItem"))
    }

    func testRepositoriesRoundTripAndReorder() throws {
        let settings = SettingsRepository(dbPool: database.dbPool)
        try settings.set(SettingsRepository.Keys.language, "en")
        XCTAssertEqual(settings.string(SettingsRepository.Keys.language), "en")

        let repository = WatchlistRepository(dbPool: database.dbPool)
        let first = WatchItem(symbol: SymbolID(code: "600519", market: .a), name: "Kweichow Moutai", order: 0)
        let second = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple", order: 1)
        try repository.upsert(first)
        try repository.upsert(second)
        try repository.reorder(ids: [second.id, first.id])

        XCTAssertEqual(try repository.all().map(\.id), [second.id, first.id])
    }

    func testIndexRepositoryRoundTripReorderDeleteAndRestoreDefaults() throws {
        let repository = IndexRepository(dbPool: database.dbPool)
        let defaults = try repository.all()
        XCTAssertEqual(defaults.map(\.id), IndexCatalog.defaults.map(\.id))

        let custom = IndexDescriptor(
            id: "custom-index",
            nameZh: "测试指数",
            nameEn: "Test Index",
            market: .us,
            emSecid: "105.TEST",
            tencentCode: "usTEST",
            currency: .usd
        )
        try repository.upsert(custom)
        XCTAssertEqual(try repository.all().count, defaults.count + 1)

        var edited = custom
        edited.nameZh = "编辑后的指数"
        try repository.upsert(edited)
        XCTAssertEqual(try repository.all().first(where: { $0.id == custom.id })?.nameZh, "编辑后的指数")

        let reorderedIDs = [custom.id] + (try repository.all().map(\.id).filter { $0 != custom.id })
        try repository.reorder(ids: reorderedIDs)
        XCTAssertEqual(try repository.all().first?.id, custom.id)

        try repository.delete(id: custom.id)
        XCTAssertNil(try repository.all().first(where: { $0.id == custom.id }))
        XCTAssertEqual(try repository.restoreDefaults().map(\.id), Array(reorderedIDs.dropFirst()))

        XCTAssertThrowsError(try repository.upsert(IndexDescriptor(
            id: "duplicate",
            nameZh: "重复",
            nameEn: "Duplicate",
            market: .a,
            emSecid: IndexCatalog.defaults[0].emSecid,
            tencentCode: "shduplicate",
            currency: .cny
        ))) { error in
            XCTAssertEqual(error as? IndexRepositoryError, .duplicateEastMoneySecid)
        }
    }

    func testSymbolEncodingAcrossMarkets() {
        XCTAssertEqual(SymbolEncoder.tencent(SymbolID(code: "600519", market: .a)), "sh600519")
        XCTAssertEqual(SymbolEncoder.eastMoney(SymbolID(code: "00700", market: .hk)), "116.00700")
        XCTAssertEqual(SymbolEncoder.yahoo(SymbolID(code: "AAPL", market: .us)), "AAPL")
        XCTAssertNil(SymbolEncoder.finnhub(SymbolID(code: "600519", market: .a)))
    }

    func testNumberAbbreviationUsesCurrencyConvention() {
        XCTAssertEqual(NumberAbbreviation.format(12_300, currency: .cny), "1.23万")
        XCTAssertEqual(NumberAbbreviation.format(1_200, currency: .usd), "1.20K")
        XCTAssertEqual(NumberAbbreviation.formatCurrency(-150_000_000, currency: .cny), "-¥1.50亿")
    }
}
