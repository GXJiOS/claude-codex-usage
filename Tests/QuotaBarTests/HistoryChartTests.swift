import AppKit
import SwiftUI
import XCTest
@testable import QuotaBar

final class HistoryChartTests: XCTestCase {
    private var originalLanguage = AppLanguage.english

    override func setUp() {
        super.setUp()
        originalLanguage = L10n.language
    }

    @MainActor
    func testYAxisStaysFixedWhileBarsAndDatesScroll() async throws {
        for language in AppLanguage.allCases {
            for count in [30, 90] {
                let (window, host) = makeWindow(days: Array(0..<count), language: language)
                defer { window.close() }
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                    .first { $0.hasHorizontalScroller })
                let chartBounds = scroll.convert(scroll.bounds, to: host)
                let axisOrigin = Spacing.contentPadding + Spacing.cardPadding
                let axisBounds = NSRect(x: axisOrigin, y: chartBounds.minY,
                                        width: max(24, chartBounds.minX - axisOrigin), height: 142)
                let axisBefore = try snapshot(host, in: axisBounds)
                let plotBefore = try snapshot(host, in: chartBounds)
                let bitmap = try XCTUnwrap(NSBitmapImageRep(data: axisBefore))
                var textPixels = 0
                for y in stride(from: 0, to: bitmap.pixelsHigh, by: 2) {
                    for x in stride(from: 0, to: bitmap.pixelsWide, by: 2) {
                        if let color = bitmap.colorAt(x: x, y: y)?.usingColorSpace(.deviceRGB),
                           max(color.redComponent, color.greenComponent, color.blueComponent) < 0.7 {
                            textPixels += 1
                        }
                    }
                }
                XCTAssertGreaterThan(textPixels, 20, "The fixed axis contains visible numeric labels")
                let document = try XCTUnwrap(scroll.documentView)
                scroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - scroll.contentView.bounds.width, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                let axisAfter = try snapshot(host, in: axisBounds)
                let plotAfter = try snapshot(host, in: chartBounds)
                XCTAssertEqual(axisBefore, axisAfter, "Y-axis numbers stay fixed while the chart scrolls")
                XCTAssertNotEqual(plotBefore, plotAfter, "Bars and dates move through the visible plot")
                XCTAssertGreaterThan(chartBounds.minX, axisOrigin + 24,
                                     "The visible numeric axis sits outside the horizontal scroll view")
            }
        }
    }

    override func tearDown() {
        L10n.language = originalLanguage
        super.tearDown()
    }

    @MainActor
    func testLongHistoryCanScrollToBothEndsInsideVerticalScrollView() async throws {
        for language in AppLanguage.allCases {
            for count in [30, 90] {
                let (window, host) = makeWindow(days: Array(0..<count), language: language)
                defer { window.close() }
                try await Task.sleep(nanoseconds: 200_000_000)
                host.layoutSubtreeIfNeeded()
                try writeArtifact(host, name: "\(language.rawValue)-\(count)-start.png")
                let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                    .first { $0.hasHorizontalScroller }, "Daily token history needs its own horizontal scroll view")
                let document = try XCTUnwrap(scroll.documentView)
                let viewport = scroll.contentView.bounds.width
                XCTAssertGreaterThan(document.bounds.width, viewport * 2)
                scroll.contentView.scroll(to: NSPoint(x: document.bounds.maxX - viewport, y: 0))
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertGreaterThan(scroll.contentView.bounds.minX, viewport)
                try writeArtifact(host, name: "\(language.rawValue)-\(count)-end.png")
                scroll.contentView.scroll(to: .zero)
                scroll.reflectScrolledClipView(scroll.contentView)
                XCTAssertEqual(scroll.contentView.bounds.minX, 0, accuracy: 1)
            }
        }
    }

    @MainActor
    func testShortHistoryFitsWithoutHorizontalOverflow() async throws {
        for count in [1, 2, 7] {
            let (window, host) = makeWindow(days: Array(0..<count), language: .simplifiedChinese)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                .first { $0.hasHorizontalScroller })
            let document = try XCTUnwrap(scroll.documentView)
            XCTAssertEqual(document.bounds.width, scroll.contentView.bounds.width, accuracy: 1)
            try writeArtifact(host, name: "zh-Hans-\(count)-start.png")
        }
    }

    @MainActor
    func testSparseHistoryPreservesCalendarSpacing() async throws {
        var widths: [CGFloat] = []
        for days in [Array(0..<90), [0, 89]] {
            let (window, host) = makeWindow(days: days, language: .english)
            defer { window.close() }
            try await Task.sleep(nanoseconds: 100_000_000)
            host.layoutSubtreeIfNeeded()
            let scroll = try XCTUnwrap(descendants(host).compactMap { $0 as? NSScrollView }
                .first { $0.hasHorizontalScroller })
            widths.append(try XCTUnwrap(scroll.documentView).bounds.width)
        }
        XCTAssertEqual(widths[0], widths[1], accuracy: 1,
                       "Missing sample days retain their calendar spacing")
    }

    @MainActor
    func testHorizontalWheelScrollsChartAndVerticalWheelScrollsPage() async throws {
        let (window, host) = makeWindow(days: Array(0..<30), language: .english)
        defer { window.close() }
        try await Task.sleep(nanoseconds: 100_000_000)
        host.layoutSubtreeIfNeeded()
        let scrolls = descendants(host).compactMap { $0 as? NSScrollView }
        let horizontal = try XCTUnwrap(scrolls.first { $0.hasHorizontalScroller })
        let vertical = try XCTUnwrap(scrolls.first { $0.hasVerticalScroller })
        func wheel(horizontal x: Int32, vertical y: Int32) throws -> NSEvent {
            let event = try XCTUnwrap(CGEvent(scrollWheelEvent2Source: nil, units: .pixel,
                                             wheelCount: 2, wheel1: y, wheel2: x, wheel3: 0))
            return try XCTUnwrap(NSEvent(cgEvent: event))
        }
        horizontal.scrollWheel(with: try wheel(horizontal: -120, vertical: 0))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(horizontal.contentView.bounds.minX, 0)
        XCTAssertEqual(vertical.contentView.bounds.minY, 0, accuracy: 1)
        let horizontalOffset = horizontal.contentView.bounds.minX
        horizontal.scrollWheel(with: try wheel(horizontal: 0, vertical: -120))
        try await Task.sleep(nanoseconds: 100_000_000)
        XCTAssertGreaterThan(vertical.contentView.bounds.minY, 0,
                             "Scrolling vertically over the chart continues to move the page")
        XCTAssertEqual(horizontal.contentView.bounds.minX, horizontalOffset, accuracy: 1)
    }

    @MainActor
    private func makeWindow(days: [Int], language: AppLanguage) -> (NSWindow, NSView) {
        _ = NSApplication.shared
        L10n.language = language
        let first = Calendar.current.startOfDay(for: Date(timeIntervalSince1970: 1_790_300_000))
        let points = days.map { index in
            DailyTokenChart.DayPoint(day: Calendar.current.date(byAdding: .day, value: index, to: first)!,
                                    tokens: (index % 9 + 1) * 123_456_789)
        }
        let host = NSHostingView(rootView: ScrollView {
            VStack {
                SettingsCard("Tokens per day") {
                    DailyTokenChart(points: points)
                }
                Color.clear.frame(height: 800)
            }.padding(20)
        }.scrollIndicators(.hidden, axes: .vertical)
            .background(Color.white).environment(\.colorScheme, .light)
            .environment(\.locale, language.locale))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 530, height: 300),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.orderFront(nil)
        return (window, host)
    }

    @MainActor
    private func descendants(_ view: NSView) -> [NSView] {
        view.subviews.flatMap { [$0] + descendants($0) }
    }

    @MainActor
    private func snapshot(_ view: NSView, in bounds: NSRect) throws -> Data {
        view.display()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: bounds))
        view.cacheDisplay(in: bounds, to: bitmap)
        return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
    }

    @MainActor
    private func writeArtifact(_ view: NSView, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["HISTORY_ARTIFACT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        view.display()
        let bitmap = try XCTUnwrap(view.bitmapImageRepForCachingDisplay(in: view.bounds))
        view.cacheDisplay(in: view.bounds, to: bitmap)
        try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
            .write(to: directory.appendingPathComponent(name))
    }
}
