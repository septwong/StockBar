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

    func testWeightedAverageCostAndPartialSell() throws {
        let symbol = SymbolID(code: "600519", market: .a)
        let holdingID = UUID()
        let transactions = [
            PortfolioTransaction(
                holdingID: holdingID,
                symbol: symbol,
                name: "Test",
                type: .openingBalance,
                quantity: 100,
                price: 10,
                occurredAt: date("2026-08-20T01:00:00Z")
            ),
            PortfolioTransaction(
                holdingID: holdingID,
                symbol: symbol,
                name: "Test",
                type: .buy,
                quantity: 50,
                price: 14,
                fee: 1,
                occurredAt: date("2026-08-21T01:00:00Z")
            ),
            PortfolioTransaction(
                holdingID: holdingID,
                symbol: symbol,
                name: "Test",
                type: .sell,
                quantity: 60,
                price: 16,
                fee: 2,
                occurredAt: date("2026-08-22T01:00:00Z")
            )
        ]

        let summary = try PortfolioLedger.replay(transactions)

        XCTAssertEqual(summary.quantity, 90)
        XCTAssertEqual(summary.averageCost, Decimal(string: "11.34")!)
        XCTAssertEqual(summary.realizedPnL, Decimal(string: "277.6")!)
        XCTAssertEqual(summary.adjustedCostAmount, 743)
        XCTAssertEqual(summary.adjustedCostPrice, 743.0 / 90.0)
        XCTAssertEqual(summary.entries.last?.averageCostAfter, Decimal(string: "11.34")!)
    }

    func testBrokerStyleAdjustedCostAndIntradayPnl() {
        let symbol = SymbolID(code: "000567", market: .a)
        let holdingID = UUID()
        let opening = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "海德股份",
            type: .openingBalance,
            quantity: 1000,
            price: Decimal(string: "5.991")!,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        let sell = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "海德股份",
            type: .sell,
            quantity: 500,
            price: Decimal(string: "6.23")!,
            fee: Decimal(string: "2.56")!,
            occurredAt: date("2026-08-24T01:00:00Z")
        )
        let holding = Holding(
            id: holdingID,
            symbol: symbol,
            name: "海德股份",
            quantity: 500,
            costPrice: Decimal(string: "5.991")!,
            createdAt: date("2026-08-20T01:00:00Z")
        )
        let quote = quote(price: Decimal(string: "6.18")!, prevClose: 6, for: symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [holding],
            transactions: [opening, sell],
            quotes: [symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: date("2026-08-24T02:00:00Z")
        )
        let position = try! XCTUnwrap(snapshot.positions.first)

        XCTAssertEqual(snapshot.todayPnL, 205)
        XCTAssertEqual(snapshot.todayPnLPct, 205.0 / 6000.0, accuracy: 0.000_000_1)
        XCTAssertEqual(snapshot.allTimePnL, Decimal(string: "211.44")!)
        XCTAssertEqual(snapshot.adjustedCostBase, Decimal(string: "2878.56")!)
        XCTAssertEqual(snapshot.allTimePnLPct, 211.44 / 2878.56, accuracy: 0.000_000_1)
        XCTAssertEqual(position.adjustedCostPrice, Decimal(string: "5.75712")!)
        XCTAssertEqual(position.pnlPct, 211.44 / 2878.56, accuracy: 0.000_000_1)
        // The ledger keeps the true average acquisition cost for future sells.
        XCTAssertEqual(position.holding.costPrice, Decimal(string: "5.991")!)
    }

    func testLegacyClearLedgerLeavesZeroAssetsButRetainsRealizedPnl() {
        let symbol = SymbolID(code: "600519", market: .a)
        let holdingID = UUID()
        let opening = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "Test",
            type: .openingBalance,
            quantity: 10,
            price: 10,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        let clear = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "Test",
            type: .clear,
            quantity: 10,
            price: 15,
            fee: 2,
            occurredAt: date("2026-08-24T01:00:00Z")
        )
        let quote = quote(price: 15, prevClose: 15, for: symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [],
            transactions: [opening, clear],
            quotes: [symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: date("2026-08-24T02:00:00Z")
        )

        XCTAssertEqual(snapshot.totalAssets, 0)
        XCTAssertEqual(snapshot.allTimePnL, 48)
        XCTAssertEqual(snapshot.historicalCostBase, 100)
        XCTAssertEqual(snapshot.todayPnL, 0)
        XCTAssertEqual(snapshot.allTimePnLPct, 0.48, accuracy: 0.000_000_1)
    }

    func testClearDeletesHoldingHistoryAndRebuyStartsFresh() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-clear-cycle-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let holdingsRepo = HoldingsRepository(dbPool: database.dbPool)
        let transactionsRepo = PortfolioTransactionsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "000567", market: .a)
        let initial = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 1000,
            price: Decimal(string: "5.991")!,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        _ = try operations.sell(
            holdingID: initial.id,
            quantity: 500,
            price: Decimal(string: "6.23")!,
            occurredAt: date("2026-08-24T01:00:00Z")
        )

        try operations.clear(holdingID: initial.id)

        XCTAssertNil(try holdingsRepo.find(id: initial.id, includingClosed: true))
        XCTAssertTrue(try transactionsRepo.all(for: initial.id).isEmpty)

        let fresh = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 500,
            price: Decimal(string: "5.757")!,
            occurredAt: date("2026-08-25T01:00:00Z")
        )
        XCTAssertNotEqual(fresh.id, initial.id)
        XCTAssertEqual(fresh.quantity, 500)
        XCTAssertEqual(fresh.costPrice, Decimal(string: "5.757")!)
        XCTAssertEqual(try transactionsRepo.all(for: fresh.id).count, 1)

        let quote = quote(price: Decimal(string: "6.21")!, prevClose: Decimal(string: "6.18")!, for: symbol)
        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: try holdingsRepo.all(),
            transactions: try transactionsRepo.all(),
            quotes: [symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: date("2026-08-25T02:00:00Z")
        )
        XCTAssertEqual(snapshot.allTimePnL, Decimal(string: "226.5")!)
        XCTAssertEqual(snapshot.todayPnL, Decimal(string: "226.5")!)
    }

    func testLegacyClearCycleIsTrimmedBeforeRebuy() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-legacy-clear-migration-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let holdingsRepo = HoldingsRepository(dbPool: database.dbPool)
        let transactionsRepo = PortfolioTransactionsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "000567", market: .a)
        let holdingID = UUID()
        let oldDate = date("2026-08-20T01:00:00Z")
        let clearDate = date("2026-08-24T01:00:00Z")
        let rebuyDate = date("2026-08-25T01:00:00Z")
        let holding = Holding(
            id: holdingID,
            symbol: symbol,
            name: "Test",
            quantity: 500,
            costPrice: Decimal(string: "5.757")!,
            createdAt: oldDate
        )
        let legacyTransactions = [
            PortfolioTransaction(
                holdingID: holdingID, symbol: symbol, name: "Test", type: .openingBalance,
                quantity: 1000, price: Decimal(string: "5.991")!, occurredAt: oldDate
            ),
            PortfolioTransaction(
                holdingID: holdingID, symbol: symbol, name: "Test", type: .sell,
                quantity: 500, price: Decimal(string: "6.23")!, occurredAt: clearDate
            ),
            PortfolioTransaction(
                holdingID: holdingID, symbol: symbol, name: "Test", type: .clear,
                quantity: 500, price: Decimal(string: "6.18")!, occurredAt: clearDate.addingTimeInterval(60)
            ),
            PortfolioTransaction(
                holdingID: holdingID, symbol: symbol, name: "Test", type: .buy,
                quantity: 500, price: Decimal(string: "5.757")!, occurredAt: rebuyDate
            )
        ]

        try database.dbPool.write { db in
            try HoldingsRepository.upsert(holding, in: db)
            for transaction in legacyTransactions {
                try PortfolioTransactionsRepository.insert(transaction, in: db)
            }
            try PortfolioTransactionsRepository.removeLegacyClearCycles(in: db)
        }

        let remaining = try transactionsRepo.all(for: holdingID)
        XCTAssertEqual(remaining.map(\.type), [.buy])
        XCTAssertEqual(try holdingsRepo.find(id: holdingID)?.quantity, 500)
        XCTAssertEqual(try holdingsRepo.find(id: holdingID)?.costPrice, Decimal(string: "5.757")!)
        XCTAssertEqual(try holdingsRepo.find(id: holdingID)?.createdAt, rebuyDate)
    }

    func testOperationRollbackKeepsTransactionAndHoldingAtomic() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-portfolio-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        let holding = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 100,
            price: 10,
            occurredAt: date("2026-08-20T01:00:00Z")
        )

        XCTAssertThrowsError(try operations.sell(
            holdingID: holding.id,
            quantity: 101,
            price: 12,
            occurredAt: date("2026-08-24T01:00:00Z")
        )) { error in
            XCTAssertEqual(error as? PortfolioOperationError, .oversell)
        }
        let holdingsRepo = HoldingsRepository(dbPool: database.dbPool)
        XCTAssertEqual(try holdingsRepo.find(id: holding.id)?.quantity, 100)
        XCTAssertEqual(try PortfolioTransactionsRepository(dbPool: database.dbPool).all().count, 1)
    }

    func testUpdatingBuyAndSellFeesReplaysOriginalTransactions() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-fee-update-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let transactionsRepo = PortfolioTransactionsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        let initial = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 100,
            price: 10,
            fee: 1,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        _ = try operations.sell(
            holdingID: initial.id,
            quantity: 50,
            price: 12,
            fee: 2,
            occurredAt: date("2026-08-24T01:00:00Z")
        )

        let transactionRows = try transactionsRepo.all(for: initial.id)
        let buyID = try XCTUnwrap(transactionRows.first(where: { $0.type == .buy })?.id)
        let sellID = try XCTUnwrap(transactionRows.first(where: { $0.type == .sell })?.id)
        _ = try operations.updateFee(transactionID: buyID, fee: 3)
        _ = try operations.updateFee(transactionID: sellID, fee: 5)

        let updatedHolding = try XCTUnwrap(HoldingsRepository(dbPool: database.dbPool).find(id: initial.id))
        XCTAssertEqual(updatedHolding.quantity, 50)
        XCTAssertEqual(updatedHolding.costPrice, Decimal(string: "10.03")!)

        let transactions = try transactionsRepo.all(for: initial.id)
        XCTAssertEqual(transactions.count, 2)
        XCTAssertEqual(transactions.first(where: { $0.type == .buy })?.fee, 3)
        XCTAssertEqual(transactions.first(where: { $0.type == .sell })?.fee, 5)
        XCTAssertEqual(transactions.first(where: { $0.type == .buy })?.feeStatus, .confirmed)
        XCTAssertEqual(transactions.first(where: { $0.type == .sell })?.feeStatus, .confirmed)

        let entries = try operations.history(for: initial.id)
        XCTAssertEqual(entries.first(where: { $0.transaction.type == .sell })?.realizedPnL, Decimal(string: "93.5")!)
    }

    func testDeletingTransactionReplaysHoldingFromRemainingHistory() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-transaction-delete-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let transactionsRepo = PortfolioTransactionsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        let initial = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 100,
            price: 10,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        _ = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 50,
            price: 14,
            fee: 1,
            occurredAt: date("2026-08-21T01:00:00Z")
        )
        _ = try operations.sell(
            holdingID: initial.id,
            quantity: 60,
            price: 16,
            fee: 2,
            occurredAt: date("2026-08-22T01:00:00Z")
        )

        let sellID = try XCTUnwrap(
            transactionsRepo.all(for: initial.id).first(where: { $0.type == .sell })?.id
        )
        let updated = try operations.deleteTransaction(transactionID: sellID)

        XCTAssertEqual(updated.quantity, 150)
        XCTAssertEqual(updated.costPrice, Decimal(string: "11.34")!)
        XCTAssertEqual(try transactionsRepo.all(for: initial.id).count, 2)
        XCTAssertEqual(try operations.history(for: initial.id).count, 2)
    }

    func testDeletingTransactionRollsBackWhenRemainingHistoryIsInvalid() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-transaction-delete-rollback-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }

        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let transactionsRepo = PortfolioTransactionsRepository(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        let initial = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 100,
            price: 10,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        _ = try operations.sell(
            holdingID: initial.id,
            quantity: 60,
            price: 12,
            occurredAt: date("2026-08-21T01:00:00Z")
        )
        let openingID = try XCTUnwrap(
            transactionsRepo.all(for: initial.id).first(where: { $0.type == .buy })?.id
        )

        XCTAssertThrowsError(try operations.deleteTransaction(transactionID: openingID)) { error in
            XCTAssertEqual(error as? PortfolioOperationError, .oversell)
        }
        XCTAssertEqual(try transactionsRepo.all(for: initial.id).count, 2)
        XCTAssertEqual(try HoldingsRepository(dbPool: database.dbPool).find(id: initial.id)?.quantity, 40)
    }

    func testTodayBuyAndSellUseCashFlowsWithoutFees() throws {
        let symbol = SymbolID(code: "600519", market: .a)
        let holdingID = UUID()
        let opening = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "Test",
            type: .openingBalance,
            quantity: 100,
            price: 10,
            occurredAt: date("2026-08-20T01:00:00Z")
        )
        let buy = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "Test",
            type: .buy,
            quantity: 50,
            price: 14,
            fee: 1,
            occurredAt: date("2026-08-24T01:00:00Z")
        )
        let sell = PortfolioTransaction(
            holdingID: holdingID,
            symbol: symbol,
            name: "Test",
            type: .sell,
            quantity: 60,
            price: 16,
            fee: 2,
            occurredAt: date("2026-08-24T01:30:00Z")
        )
        let holding = Holding(
            id: holdingID,
            symbol: symbol,
            name: "Test",
            quantity: 90,
            costPrice: Decimal(string: "11.34")!,
            createdAt: date("2026-08-20T01:00:00Z")
        )
        let quote = quote(price: 16, prevClose: 15, for: symbol)

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: [holding],
            transactions: [opening, buy, sell],
            quotes: [symbol: quote],
            converter: .empty,
            baseCurrency: .cny,
            asOf: date("2026-08-24T02:00:00Z")
        )

        XCTAssertEqual(snapshot.todayPnL, 200)
        XCTAssertEqual(snapshot.todayPnLPct, 200.0 / 2200.0, accuracy: 0.000_000_1)
        XCTAssertEqual(snapshot.allTimePnL, 697)
        XCTAssertEqual(snapshot.positions.first?.holding.quantity, 90)
        XCTAssertEqual(snapshot.positions.first?.holding.costPrice, Decimal(string: "11.34")!)
    }

    func testAdjustmentDoesNotCreateRealizedTradingPnl() throws {
        let symbol = SymbolID(code: "600519", market: .a)
        let id = UUID()
        let summary = try PortfolioLedger.replay([
            PortfolioTransaction(
                holdingID: id,
                symbol: symbol,
                name: "Test",
                type: .openingBalance,
                quantity: 100,
                price: 10,
                occurredAt: date("2026-08-20T01:00:00Z")
            ),
            PortfolioTransaction(
                holdingID: id,
                symbol: symbol,
                name: "Test",
                type: .adjustment,
                quantity: 120,
                price: 12,
                occurredAt: date("2026-08-24T01:00:00Z")
            )
        ])

        XCTAssertEqual(summary.quantity, 120)
        XCTAssertEqual(summary.averageCost, 12)
        XCTAssertEqual(summary.realizedPnL, 0)
        XCTAssertEqual(summary.historicalCostBase, 1000)
    }

    func testMarketDayUsesEachMarketTimezone() {
        let asOf = date("2026-08-24T02:00:00Z")
        let aSymbol = SymbolID(code: "600519", market: .a)
        let usSymbol = SymbolID(code: "AAPL", market: .us)
        let aID = UUID()
        let usID = UUID()
        let occurredAt = date("2026-08-23T10:00:00Z")
        let transactions = [
            PortfolioTransaction(
                holdingID: aID, symbol: aSymbol, name: "A", type: .openingBalance,
                quantity: 10, price: 10, occurredAt: occurredAt
            ),
            PortfolioTransaction(
                holdingID: usID, symbol: usSymbol, name: "US", type: .openingBalance,
                quantity: 10, price: 10, currency: .usd, occurredAt: occurredAt
            )
        ]
        let holdings = [
            Holding(id: aID, symbol: aSymbol, name: "A", quantity: 10, costPrice: 10, createdAt: occurredAt),
            Holding(id: usID, symbol: usSymbol, name: "US", quantity: 10, costPrice: 10, currency: .usd, createdAt: occurredAt)
        ]
        let quotes = [
            aSymbol: quote(price: 12, prevClose: 11, for: aSymbol),
            usSymbol: quote(price: 12, prevClose: 11, for: usSymbol)
        ]

        let snapshot = PortfolioService.computeSnapshotSync(
            holdings: holdings,
            transactions: transactions,
            quotes: quotes,
            converter: CurrencyConverter(usdcny: 1, hkdcny: nil),
            baseCurrency: .cny,
            asOf: asOf
        )

        // 10:00 UTC is already the next day in Shanghai but still the same
        // market day in New York at this asOf instant.
        XCTAssertEqual(snapshot.todayPnL, 30)
    }

    func testBackdatedBuyIsReplayedIntoCurrentHolding() throws {
        let path = FileManager.default.temporaryDirectory
            .appendingPathComponent("stockbar-history-\(UUID().uuidString).sqlite").path
        defer {
            for suffix in ["", "-wal", "-shm"] {
                try? FileManager.default.removeItem(atPath: path + suffix)
            }
        }
        let database = try StockBar.Database(path: path)
        let operations = PortfolioOperationService(dbPool: database.dbPool)
        let symbol = SymbolID(code: "600519", market: .a)
        let current = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 100,
            price: 10,
            occurredAt: date("2026-08-24T01:00:00Z")
        )
        let updated = try operations.buy(
            symbol: symbol,
            name: "Test",
            quantity: 50,
            price: 14,
            fee: 1,
            occurredAt: date("2026-08-23T01:00:00Z")
        )

        XCTAssertEqual(updated.quantity, 150)
        XCTAssertEqual(updated.costPrice, Decimal(string: "11.34")!)
        XCTAssertEqual(try operations.history(for: current.id).count, 2)
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
