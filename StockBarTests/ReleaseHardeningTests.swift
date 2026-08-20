import XCTest
import GRDB
@testable import StockBar

final class ReleaseHardeningTests: XCTestCase {
    private var database: StockBar.Database!
    private var databasePath: String!

    override func setUpWithError() throws {
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-hardening-\(UUID().uuidString).sqlite").path
        database = try StockBar.Database(path: databasePath)
    }

    override func tearDownWithError() throws {
        database = nil
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: databasePath + suffix) }
        databasePath = nil
    }

    func testRepositoryReplaceRollsBackAsOneTransaction() throws {
        let repo = WatchlistRepository(dbPool: database.dbPool)
        let original = WatchItem(symbol: SymbolID(code: "AAPL", market: .us), name: "Apple")
        try repo.upsert(original)

        let duplicateID = UUID()
        let first = WatchItem(id: duplicateID, symbol: SymbolID(code: "600519", market: .a), name: "A")
        let duplicate = WatchItem(id: duplicateID, symbol: SymbolID(code: "00700", market: .hk), name: "B")

        XCTAssertThrowsError(try database.dbPool.write { db in
            try repo.replaceAll([first, duplicate], in: db)
        })
        let restored = try repo.all()
        XCTAssertEqual(restored.count, 1)
        XCTAssertEqual(restored.first?.id, original.id)
        XCTAssertEqual(restored.first?.symbol, original.symbol)
        XCTAssertEqual(restored.first?.name, original.name)
    }

    @MainActor
    func testBackupSettingsExcludeProviderSecrets() {
        let result = BackupService.sanitizedSettings([
            DataSourcePreferences.Keys.finnhubKey: "secret-value",
            SettingsRepository.Keys.language: "en"
        ])
        XCTAssertNil(result[DataSourcePreferences.Keys.finnhubKey])
        XCTAssertEqual(result[SettingsRepository.Keys.language], "en")
    }

    func testAlertDateKeyUsesItsMarketTimeZone() {
        let date = ISO8601DateFormatter().date(from: "2026-01-01T16:30:00Z")!
        XCTAssertEqual(Alert.todayKey(at: date, in: Market.a.timeZone), "2026-01-02")
        XCTAssertEqual(Alert.todayKey(at: date, in: Market.us.timeZone), "2026-01-01")
    }

    @MainActor
    func testAShareAlertDoesNotFireDuringUSHours() throws {
        let repo = AlertsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        try repo.upsert(Alert(
            symbol: symbol,
            name: "Test",
            condition: .priceAbove,
            threshold: 1,
            tradingHoursOnly: true
        ))
        let quote = Quote(
            symbol: symbol, name: "Test", price: 2, prevClose: 1,
            open: nil, high: nil, low: nil, volume: nil, currency: .cny,
            timestamp: Date(), isClosed: true
        )
        // 10:00 New York / 22:00 Shanghai on a weekday.
        let date = ISO8601DateFormatter().date(from: "2026-08-19T14:00:00Z")!
        let engine = AlertEngine(alertsRepo: repo, notifier: .shared, clock: MarketClock())
        XCTAssertTrue(engine.evaluate(quotes: [symbol: quote], at: date).isEmpty)
    }

    func testProviderFallbackFillsPartialResults() async throws {
        let aapl = SymbolID(code: "AAPL", market: .us)
        let msft = SymbolID(code: "MSFT", market: .us)
        let first = StubQuoteProvider(id: "first", quotes: [aapl: Self.quote(aapl)])
        let second = StubQuoteProvider(id: "second", quotes: [msft: Self.quote(msft)])
        let prefs = ProviderPreference(
            order: [.tencent, .yahoo],
            enabled: [.tencent: true, .yahoo: true]
        )
        let orchestrator = ProviderOrchestrator(
            providers: [.tencent: first, .yahoo: second],
            preferences: [.us: prefs]
        )

        let result = try await orchestrator.fetch([aapl, msft])
        XCTAssertEqual(Set(result.keys), Set([aapl, msft]))
    }

    private static func quote(_ symbol: SymbolID) -> Quote {
        Quote(
            symbol: symbol, name: symbol.code, price: 100, prevClose: 99,
            open: nil, high: nil, low: nil, volume: nil,
            currency: symbol.market.defaultCurrency, timestamp: Date(), isClosed: false
        )
    }
}

private struct StubQuoteProvider: QuoteProvider {
    let id: String
    let supportedMarkets: Set<Market> = [.a, .hk, .us]
    let quotes: [SymbolID: Quote]

    func fetch(_ symbols: [SymbolID]) async throws -> [SymbolID: Quote] {
        Dictionary(uniqueKeysWithValues: symbols.compactMap { symbol in
            quotes[symbol].map { (symbol, $0) }
        })
    }
}
