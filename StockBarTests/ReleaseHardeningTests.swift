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

    func testIndexRepositoryReplaceRollsBackAsOneTransaction() throws {
        let repo = IndexRepository(dbPool: database.dbPool)
        let original = try repo.all()
        let duplicateID = "duplicate-index"
        let first = IndexDescriptor(
            id: duplicateID,
            nameZh: "A",
            nameEn: "A",
            market: .us,
            emSecid: "105.DUPA",
            tencentCode: "usDUPA",
            currency: .usd
        )
        var duplicate = first
        duplicate.nameZh = "B"

        XCTAssertThrowsError(try database.dbPool.write { db in
            try repo.replaceAll([first, duplicate], in: db)
        })
        XCTAssertEqual(try repo.all().map(\.id), original.map(\.id))
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

    func testLegacyBackupWithoutIndicesUsesBuiltInDefaults() throws {
        let bundle = BackupBundle(
            schemaVersion: 1,
            exportedAt: Date(timeIntervalSince1970: 0),
            appVersion: "1.0.3",
            holdings: [],
            watchlist: [],
            indices: [],
            alerts: [],
            settings: [:]
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var object = try XCTUnwrap(
            JSONSerialization.jsonObject(with: encoder.encode(bundle)) as? [String: Any]
        )
        object.removeValue(forKey: "indices")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(BackupBundle.self, from: legacyData)
        XCTAssertEqual(decoded.indices.map(\.id), IndexCatalog.defaults.map(\.id))
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

    func testTencentFXParserReadsBothBasePairs() {
        let text = #"""
        v_whUSDCNY="310~USD/CNY~USDCNY~6.7240~0~20260820152704";
        v_whHKDCNY="310~HKD/CNY~HKDCNY~0.8569~0~20260820152723";
        """#
        let rates = TencentFXProvider().parse(text)
        let byPair = Dictionary(uniqueKeysWithValues: rates.map { ($0.from.rawValue + $0.to.rawValue, $0.rate) })
        XCTAssertEqual(byPair["USDCNY"], Decimal(string: "6.7240"))
        XCTAssertEqual(byPair["HKDCNY"], Decimal(string: "0.8569"))
    }

    func testFXFallbackFillsPartialPairs() async throws {
        let usd = FXRate(from: .usd, to: .cny, rate: 6.72, asOf: Date())
        let hkd = FXRate(from: .hkd, to: .cny, rate: 0.86, asOf: Date())
        let provider = FallbackFXProvider(providers: [
            StubFXProvider(id: "first", rates: [usd]),
            StubFXProvider(id: "second", rates: [hkd])
        ])

        let result = try await provider.fetch(pairs: [(.usd, .cny), (.hkd, .cny)])
        XCTAssertEqual(result.map { $0.from }, [.usd, .hkd])
    }

    func testTencentIndexParserReadsPriceAndPercentage() {
        let descriptor = IndexCatalog.all[0]
        var fields = Array(repeating: "", count: 33)
        fields[1] = "SSE Composite"
        fields[3] = "3903.72"
        fields[4] = "3894.42"
        fields[31] = "9.30"
        fields[32] = "0.24"
        let text = "v_\(descriptor.tencentCode)=\"\(fields.joined(separator: "~"))\";"

        let result = TencentIndexProvider().parse(text, indices: [descriptor])
        XCTAssertEqual(result.first?.price, Decimal(string: "3903.72"))
        XCTAssertEqual(result.first?.prevClose, Decimal(string: "3894.42"))
        XCTAssertEqual(result.first?.change, Decimal(string: "9.30"))
        XCTAssertEqual(result.first?.changePct ?? 0, 0.0024, accuracy: 0.000_001)
    }

    func testCustomIndexParsersUsePersistedProviderCodes() throws {
        let descriptor = IndexDescriptor(
            id: "custom-index",
            nameZh: "测试指数",
            nameEn: "Test Index",
            market: .us,
            emSecid: "105.TEST",
            tencentCode: "usTEST",
            currency: .usd
        )
        var fields = Array(repeating: "", count: 33)
        fields[3] = "123.45"
        fields[4] = "120.00"
        fields[31] = "3.45"
        fields[32] = "2.88"
        let tencentText = "v_\(descriptor.tencentCode)=\"\(fields.joined(separator: "~"))\";"
        let tencentResult = TencentIndexProvider().parse(tencentText, indices: [descriptor])

        let eastMoneyData = #"{"data":{"diff":[{"f2":123.45,"f3":2.88,"f4":3.45,"f12":"TEST","f13":105,"f14":"Test Index","f18":120.0}]}}"#.data(using: .utf8)!
        let eastMoneyResult = try EastMoneyIndexProvider().parse(eastMoneyData, indices: [descriptor])

        XCTAssertEqual(tencentResult.first?.id, descriptor.id)
        XCTAssertEqual(eastMoneyResult.first?.id, descriptor.id)
        XCTAssertEqual(eastMoneyResult.first?.price, Decimal(string: "123.45"))
    }

    func testIndexFallbackFillsPartialResults() async throws {
        let first = IndexCatalog.all[0]
        let second = IndexCatalog.all[1]
        let service = IndexService(providers: [
            StubIndexProvider(id: "first", quotes: [Self.indexQuote(first)]),
            StubIndexProvider(id: "second", quotes: [Self.indexQuote(second)])
        ])

        let result = try await service.fetchAll([first, second])
        XCTAssertEqual(result.map(\.id), [first.id, second.id])
    }

    private static func quote(_ symbol: SymbolID) -> Quote {
        Quote(
            symbol: symbol, name: symbol.code, price: 100, prevClose: 99,
            open: nil, high: nil, low: nil, volume: nil,
            currency: symbol.market.defaultCurrency, timestamp: Date(), isClosed: false
        )
    }

    private static func indexQuote(_ descriptor: IndexDescriptor) -> IndexQuote {
        IndexQuote(
            descriptor: descriptor,
            price: 100,
            prevClose: 99,
            change: 1,
            changePct: 0.01
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

private struct StubFXProvider: FXProvider {
    let id: String
    let rates: [FXRate]

    func fetch(pairs: [(Currency, Currency)]) async throws -> [FXRate] {
        let requested = Set(pairs.map { $0.0.rawValue + $0.1.rawValue })
        return rates.filter { requested.contains($0.from.rawValue + $0.to.rawValue) }
    }
}

private struct StubIndexProvider: IndexProvider {
    let id: String
    let quotes: [IndexQuote]

    func fetch(_ indices: [IndexDescriptor]) async throws -> [IndexQuote] {
        let requested = Set(indices.map(\.id))
        return quotes.filter { requested.contains($0.id) }
    }
}
