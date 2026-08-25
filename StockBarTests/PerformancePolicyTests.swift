import AppKit
import XCTest
@testable import StockBar

final class PerformancePolicyTests: XCTestCase {
    func testQuoteRefreshIntervalPolicy() {
        XCTAssertEqual(QuoteRefresher.effectiveQuoteInterval(
            userInterval: 5,
            popoverOpen: true,
            lowPowerMode: false
        ), 3)
        XCTAssertEqual(QuoteRefresher.effectiveQuoteInterval(
            userInterval: 1,
            popoverOpen: true,
            lowPowerMode: true
        ), 1)
        XCTAssertEqual(QuoteRefresher.effectiveQuoteInterval(
            userInterval: 5,
            popoverOpen: false,
            lowPowerMode: true
        ), 15)
        XCTAssertEqual(QuoteRefresher.effectiveQuoteInterval(
            userInterval: 30,
            popoverOpen: false,
            lowPowerMode: true
        ), 30)
    }

    func testIndexRefreshIntervalPolicy() {
        XCTAssertEqual(QuoteRefresher.effectiveIndexInterval(popoverOpen: true, lowPowerMode: true), 15)
        XCTAssertEqual(QuoteRefresher.effectiveIndexInterval(popoverOpen: false, lowPowerMode: true), 30)
        XCTAssertEqual(QuoteRefresher.effectiveIndexInterval(popoverOpen: false, lowPowerMode: false), 15)
    }

    func testQuoteCacheWritesAtMostOncePerMinuteAfterFirstSuccess() {
        let now = Date(timeIntervalSinceReferenceDate: 10_000)
        XCTAssertTrue(QuoteRefresher.shouldPersistCache(lastPersistedAt: nil, now: now))
        XCTAssertFalse(QuoteRefresher.shouldPersistCache(
            lastPersistedAt: now.addingTimeInterval(-59.9),
            now: now
        ))
        XCTAssertTrue(QuoteRefresher.shouldPersistCache(
            lastPersistedAt: now.addingTimeInterval(-60),
            now: now
        ))
    }

    func testNextOpeningIncludesMainlandAndHongKongAfternoonSession() throws {
        let clock = MarketClock()
        let lunch = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T04:00:00Z"))
        let expected = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-25T05:00:00Z"))
        XCTAssertEqual(clock.nextOpening(after: lunch), expected)
    }

    func testNextOpeningSkipsWeekend() throws {
        let clock = MarketClock()
        let fridayAfterUSClose = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-28T21:00:00Z"))
        let mondayShanghaiOpen = try XCTUnwrap(ISO8601DateFormatter().date(from: "2026-08-31T01:30:00Z"))
        XCTAssertEqual(clock.nextOpening(after: fridayAfterUSClose), mondayShanghaiOpen)
    }

    @MainActor
    func testScreenSharingDoesNotScanWithoutCandidateApplication() {
        var scanCount = 0
        let monitor = ScreenSharingMonitor(
            candidateAppsRunning: { false },
            sharingWindowScanner: {
                scanCount += 1
                return nil
            }
        )
        monitor.setEnabled(true)
        XCTAssertEqual(scanCount, 0)
        XCTAssertFalse(monitor.isSharing)
        monitor.setEnabled(false)
    }

    @MainActor
    func testScreenSharingScansImmediatelyWhenCandidateAppears() {
        var scanCount = 0
        let monitor = ScreenSharingMonitor(
            candidateAppsRunning: { true },
            sharingWindowScanner: {
                scanCount += 1
                return (owner: "Test Meeting", name: "Screen Sharing")
            }
        )
        monitor.setEnabled(true)
        XCTAssertEqual(scanCount, 1)
        XCTAssertTrue(monitor.isSharing)
        monitor.setEnabled(false)
        XCTAssertFalse(monitor.isSharing)
    }

    @MainActor
    func testTickerAnimationStopsForPausePrivacyAndDetachedView() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 22), styleMask: [], backing: .buffered, defer: false)
        let ticker = TickerView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = ticker
        ticker.update(attributed: NSAttributedString(string: "StockBar 123.45"))
        XCTAssertTrue(ticker.isAnimationRunning)

        ticker.setPaused(true)
        XCTAssertFalse(ticker.isAnimationRunning)
        ticker.setPaused(false)
        XCTAssertTrue(ticker.isAnimationRunning)

        ticker.privacyHidden = true
        XCTAssertFalse(ticker.isAnimationRunning)
        ticker.privacyHidden = false
        XCTAssertTrue(ticker.isAnimationRunning)

        window.contentView = nil
        XCTAssertFalse(ticker.isAnimationRunning)
    }

    @MainActor
    func testCarouselDoesNotAnimateWithFewerThanTwoItems() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 240, height: 22), styleMask: [], backing: .buffered, defer: false)
        let ticker = CarouselTickerView(frame: window.contentView?.bounds ?? .zero)
        window.contentView = ticker
        ticker.update(items: [NSAttributedString(string: "Only one")])
        XCTAssertFalse(ticker.isAnimationRunning)
        ticker.update(items: [NSAttributedString(string: "One"), NSAttributedString(string: "Two")])
        XCTAssertTrue(ticker.isAnimationRunning)
        ticker.invalidateAnimation()
    }
}
