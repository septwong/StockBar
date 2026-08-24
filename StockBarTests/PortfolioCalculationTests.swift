import XCTest
@testable import StockBar

final class PortfolioCalculationTests: XCTestCase {
    func testNewHoldingUsesCostAsTodayBaseline() {
        let asOf = date("2026-08-24T02:00:00Z") // 10:00 in Shanghai
        let holding = Holding(
            symbol: SymbolID(code: "600519", market: .a),
            name: "Test",
            quantity: 1,
            costPrice: 5991,
            createdAt: date("2026-08-24T01:00:00Z") // 09:00 in Shanghai
        )
        let quote = quote(price: 5880, prevClose: 5930, for: holding.symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [holding],
            quotes: [holding.symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: asOf
        )

        XCTAssertEqual(snapshot.totalAssets, 5880)
        XCTAssertEqual(snapshot.todayPnL, -111)
        XCTAssertEqual(snapshot.allTimePnL, -111)
        XCTAssertEqual(snapshot.todayPnLPct, -111.0 / 5991.0, accuracy: 0.000_000_1)
        XCTAssertEqual(snapshot.allTimePnLPct, -111.0 / 5991.0, accuracy: 0.000_000_1)
    }

    func testExistingHoldingUsesPreviousCloseForToday() {
        let asOf = date("2026-08-24T02:00:00Z")
        let holding = Holding(
            symbol: SymbolID(code: "600519", market: .a),
            name: "Test",
            quantity: 1,
            costPrice: 5991,
            createdAt: date("2026-08-23T01:00:00Z")
        )
        let quote = quote(price: 5880, prevClose: 5930, for: holding.symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [holding],
            quotes: [holding.symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: asOf
        )

        XCTAssertEqual(snapshot.totalAssets, 5880)
        XCTAssertEqual(snapshot.todayPnL, -50)
        XCTAssertEqual(snapshot.allTimePnL, -111)
        XCTAssertEqual(snapshot.todayPnLPct, -50.0 / 5930.0, accuracy: 0.000_000_1)
        XCTAssertEqual(snapshot.allTimePnLPct, -111.0 / 5991.0, accuracy: 0.000_000_1)
    }

    func testMissingPreviousCloseDoesNotCreateArtificialTodayLoss() {
        let asOf = date("2026-08-24T02:00:00Z")
        let holding = Holding(
            symbol: SymbolID(code: "600519", market: .a),
            name: "Test",
            quantity: 10,
            costPrice: 90,
            createdAt: date("2026-08-23T01:00:00Z")
        )
        let quote = quote(price: 100, prevClose: 0, for: holding.symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [holding],
            quotes: [holding.symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: asOf
        )

        XCTAssertEqual(snapshot.totalAssets, 1000)
        XCTAssertEqual(snapshot.todayPnL, 0)
        XCTAssertEqual(snapshot.allTimePnL, 100)
        XCTAssertEqual(snapshot.todayPnLPct, 0)
    }

    private func quote(price: Decimal, prevClose: Decimal, for symbol: SymbolID) -> Quote {
        Quote(
            symbol: symbol,
            name: "Test",
            price: price,
            prevClose: prevClose,
            open: nil,
            high: nil,
            low: nil,
            volume: nil,
            currency: symbol.market.defaultCurrency,
            timestamp: Date(),
            isClosed: false
        )
    }

    private func date(_ string: String) -> Date {
        ISO8601DateFormatter().date(from: string)!
    }
}
