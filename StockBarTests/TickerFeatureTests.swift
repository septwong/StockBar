import XCTest
import GRDB
@testable import StockBar

final class TickerFeatureTests: XCTestCase {
    func testSingleQuoteCandidatesPreserveOrderAndMergeDuplicates() {
        let shared = SymbolID(code: "600519", market: .a)
        let holding = Holding(
            symbol: shared,
            name: "贵州茅台",
            quantity: 1,
            costPrice: 100,
            inTicker: false
        )
        let otherHolding = Holding(
            symbol: SymbolID(code: "AAPL", market: .us),
            name: "Apple",
            quantity: 1,
            costPrice: 100,
            inTicker: true
        )
        let duplicateWatch = WatchItem(symbol: shared, name: "茅台", order: 0, inTicker: true)
        let watch = WatchItem(symbol: SymbolID(code: "00700", market: .hk), name: "腾讯控股", order: 1)

        let candidates = SingleQuoteSelection.candidates(
            holdings: [holding, otherHolding],
            watchlist: [duplicateWatch, watch]
        )

        XCTAssertEqual(candidates.map(\.symbol), [shared, otherHolding.symbol, watch.symbol])
        XCTAssertEqual(candidates.first?.name, "贵州茅台")
        XCTAssertTrue(candidates.first?.inTicker == true)
        XCTAssertEqual(SingleQuoteSelection.defaultSymbol(in: candidates), shared)
    }

    func testSingleQuoteFormattingUsesTwoDecimalsAndPlaceholders() {
        XCTAssertEqual(TickerDisplayFormatting.price(Decimal(string: "12.3")!), "12.30")
        XCTAssertEqual(TickerDisplayFormatting.percent(-0.0183), "-1.83%")
        XCTAssertEqual(TickerDisplayFormatting.percent(0.0062), "+0.62%")
        XCTAssertEqual(TickerDisplayFormatting.percent(-0.0), "+0.00%")
        XCTAssertEqual(SingleQuoteTickerView.formattedPrice(nil), "--")
        XCTAssertEqual(SingleQuoteTickerView.formattedChange(nil), "--")
    }

    func testQuoteFormattingKeepsOptionalThirdDecimal() {
        XCTAssertEqual(Currency.cny.formatQuote(Decimal(string: "1.139")!), "¥1.139")
        XCTAssertEqual(Currency.cny.formatQuote(Decimal(string: "6.89")!), "¥6.89")
    }
}

@MainActor
final class SingleQuotePreferencesTests: XCTestCase {
    private var database: StockBar.Database!
    private var databasePath: String!

    override func setUpWithError() throws {
        databasePath = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-single-quote-\(UUID().uuidString).sqlite")
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

    func testSingleQuoteSymbolRoundTripsAndInvalidJSONFallsBackToNil() throws {
        let settings = SettingsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "AAPL", market: .us)
        let prefs = TickerPreferences(repo: settings)

        prefs.displayMode = .singleQuote
        prefs.singleQuoteSymbol = symbol
        XCTAssertEqual(TickerPreferences(repo: settings).displayMode, .singleQuote)
        XCTAssertEqual(TickerPreferences(repo: settings).singleQuoteSymbol, symbol)

        try settings.set(SettingsRepository.Keys.tickerSingleQuoteSymbol, "not-json")
        XCTAssertNil(TickerPreferences(repo: settings).singleQuoteSymbol)

        prefs.singleQuoteSymbol = nil
        XCTAssertNil(settings.string(SettingsRepository.Keys.tickerSingleQuoteSymbol))
    }

    func testSingleQuoteWidthPreferencesRoundTrip() throws {
        let settings = SettingsRepository(dbPool: database.dbPool)
        let prefs = TickerPreferences(repo: settings)

        XCTAssertTrue(prefs.singleQuoteAutoWidth)
        XCTAssertEqual(prefs.singleQuoteMenuBarWidth, 160)

        prefs.singleQuoteAutoWidth = false
        prefs.singleQuoteMenuBarWidth = 220

        let restored = TickerPreferences(repo: settings)
        XCTAssertFalse(restored.singleQuoteAutoWidth)
        XCTAssertEqual(restored.singleQuoteMenuBarWidth, 220)
    }
}
