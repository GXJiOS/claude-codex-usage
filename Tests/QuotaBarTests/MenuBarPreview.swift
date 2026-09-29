import XCTest
import AppKit
import SwiftUI
import AVFoundation
@testable import QuotaBar

/// Renders the real menu bar image, riders included, at actual size and enlarged.
final class MenuBarPreview: XCTestCase {
    @MainActor
    func testLivePreviewAnimatesOnlyWithCyclists() async throws {
        guard ProcessInfo.processInfo.environment["LIVE_PREVIEW_TEST"] == "1" else {
            throw XCTSkip("set LIVE_PREVIEW_TEST=1 for the window animation check")
        }
        _ = NSApplication.shared
        let model = SettingsModel(persistChanges: false)
        model.settings = .default
        model.settings.menuBarStyle = .percentageBadge
        let store = UsageStore(providers: [], preview: usageStatuses())
        let rates = UsageRateMonitor(isLive: false)
        rates.absorb([.claude: 300, .codex: 7_000], at: Date())
        let statusBar = StatusBarController(store: store, model: model, rates: rates)
        let host = NSHostingView(rootView: MenuBarLivePreview().environmentObject(statusBar))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 410),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        window.center()
        window.makeKeyAndOrderFront(nil)
        defer { window.close() }

        func capture() throws -> Data {
            host.layoutSubtreeIfNeeded()
            host.displayIfNeeded()
            let bitmap = try XCTUnwrap(host.bitmapImageRepForCachingDisplay(in: host.bounds))
            host.cacheDisplay(in: host.bounds, to: bitmap)
            return try XCTUnwrap(bitmap.representation(using: .png, properties: [:]))
        }
        func settle(_ interval: TimeInterval) async throws {
            try await Task.sleep(nanoseconds: UInt64(interval * 1_000_000_000))
        }

        try await settle(0.3)
        let first = try capture()
        try writeArtifact(first, name: "preview-controls.png")
        try await settle(0.17)
        XCTAssertNotEqual(first, try capture(), "Visible preview must advance its rider frames")

        model.settings.showCyclist = false
        try await settle(0.3)
        let disabled = try capture()
        try await settle(0.17)
        XCTAssertEqual(disabled, try capture(), "Indicators stay static with riders disabled")

        model.settings.menuBarStyle = .ring
        try await settle(0.3)
        let ring = try capture()
        XCTAssertNotEqual(disabled, ring, "The first style change updates the preview")
        model.settings.menuBarStyle = .percentageBadge
        try await settle(0.3)
        XCTAssertEqual(disabled, try capture(), "Restoring the style immediately restores its image")
        model.showRemaining = true
        try await settle(0.3)
        XCTAssertNotEqual(disabled, try capture(), "Remaining usage updates on the first change")
        model.showRemaining = false
        try await settle(0.3)
        XCTAssertEqual(disabled, try capture())

        model.settings.showCyclist = true
        try await settle(0.3)
        let resumed = try capture()
        try await settle(0.17)
        XCTAssertNotEqual(resumed, try capture(), "Re-enabling riders resumes the animation")
    }

    @MainActor
    func testNativeMenuCaptureIsCroppedAndTracksUsage() async throws {
        try requireNativeCapture()
        var settings = Settings.default
        settings.menuBarStyle = .percentageBadge
        let (window, view) = nativeWindow(image: sampleImage(settings: settings))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertEqual(view.material, .menu)
        XCTAssertEqual(view.blendingMode, .behindWindow)
        let first = try await captureNative(view)
        XCTAssertEqual(first.pixelsWide, 320)
        XCTAssertEqual(first.pixelsHigh, 320)
        let edge = try XCTUnwrap(first.colorAt(x: 3, y: 160)?.usingColorSpace(.deviceRGB))
        XCTAssertLessThan(abs(edge.redComponent - edge.greenComponent), 0.3, "The crop excludes the magenta surround")
        try writeArtifact(XCTUnwrap(first.representation(using: .png, properties: [:])), name: "native-menu.png")
        view.image = StatusTitleImage.make(statuses: usageStatuses(claude: 72, codex: 14), settings: settings, mode: .used)
        try await Task.sleep(nanoseconds: 100_000_000)
        let second = try await captureNative(view)
        XCTAssertNotEqual(first.tiffRepresentation, second.tiffRepresentation)
        window.orderOut(nil)
        do {
            _ = try await view.captureSession()
            XCTFail("A hidden preview cannot start a capture")
        } catch { }
    }

    @MainActor
    func testNativeStreamRecordsOnlySquareRegion() async throws {
        try requireNativeCapture()
        var settings = Settings.default
        settings.menuBarStyle = .percentageBadge
        let (window, view) = nativeWindow(image: sampleImage(settings: settings))
        defer { window.close() }
        try await Task.sleep(nanoseconds: 200_000_000)
        let session = try await view.captureSession()
        try await session.start()
        defer { Task { await session.stop() } }
        let movie = try PreviewMovieWriter()
        defer { movie.cancel() }
        let producer = Task { @MainActor in
            for index in 0..<40 {
                view.image = sampleImage(settings: settings, index: index)
                try await Task.sleep(nanoseconds: 40_000_000)
            }
        }
        defer { producer.cancel() }
        var firstTime: CMTime?
        var elapsed = 0.0
        var count = 0
        for try await frame in session.frames {
            if firstTime == nil { firstTime = frame.time }
            elapsed = (frame.time - firstTime!).seconds
            try movie.append(frame.buffer, at: elapsed)
            count += 1
            if elapsed >= 0.75 { break }
        }
        await session.stop()
        XCTAssertGreaterThan(count, 5)
        let url = try await movie.finish(at: elapsed + 1.0 / 30)
        let asset = AVURLAsset(url: url)
        let tracks = try await asset.loadTracks(withMediaType: .video)
        let track = try XCTUnwrap(tracks.first)
        let size = try await track.load(.naturalSize)
        XCTAssertEqual(size, CGSize(width: 320, height: 320))
        let duration = try await asset.load(.duration)
        XCTAssertEqual(duration.seconds, elapsed + 1.0 / 30, accuracy: 0.05)
        let audio = try await asset.loadTracks(withMediaType: .audio)
        XCTAssertTrue(audio.isEmpty)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.requestedTimeToleranceBefore = .zero
        let first = try generator.copyCGImage(at: .zero, actualTime: nil)
        let last = try generator.copyCGImage(at: CMTime(seconds: elapsed - 0.03, preferredTimescale: 600), actualTime: nil)
        XCTAssertNotEqual(NSBitmapImageRep(cgImage: first).tiffRepresentation, NSBitmapImageRep(cgImage: last).tiffRepresentation)
        try writeArtifact(Data(contentsOf: url), name: "native-menu.mp4")
        try writeArtifact(XCTUnwrap(NSBitmapImageRep(cgImage: first).representation(using: .png, properties: [:])), name: "native-video-frame.png")
    }

    @MainActor
    func testCancellingRecordingRemovesTemporaryMovie() throws {
        let movie = try PreviewMovieWriter()
        movie.cancel()
        XCTAssertFalse(FileManager.default.fileExists(atPath: movie.url.path))
    }

    private func requireNativeCapture() throws {
        guard ProcessInfo.processInfo.environment["LIVE_PREVIEW_TEST"] == "1" else {
            throw XCTSkip("set LIVE_PREVIEW_TEST=1 for native window capture")
        }
        guard #available(macOS 14.4, *) else { throw XCTSkip("Own-process capture requires macOS 14.4") }
    }

    @MainActor
    private func nativeWindow(image: NSImage) -> (NSWindow, NativePreviewView) {
        _ = NSApplication.shared
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 220),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let root = NSView(frame: NSRect(x: 0, y: 0, width: 300, height: 220))
        root.wantsLayer = true
        root.layer?.backgroundColor = NSColor.magenta.cgColor
        let view = NativePreviewView()
        view.frame.origin = NSPoint(x: 35, y: 25)
        view.image = image
        root.addSubview(view)
        window.contentView = root
        window.center()
        window.makeKeyAndOrderFront(nil)
        return (window, view)
    }

    @MainActor
    private func captureNative(_ view: NativePreviewView) async throws -> NSBitmapImageRep {
        let session = try await view.captureSession()
        defer { Task { await session.stop() } }
        try await session.start()
        var iterator = session.frames.makeAsyncIterator()
        let next = try await iterator.next()
        let frame = try XCTUnwrap(next)
        let input = CIImage(cvPixelBuffer: frame.buffer)
        let cgImage = try XCTUnwrap(CIContext().createCGImage(input, from: input.extent))
        await session.stop()
        return NSBitmapImageRep(cgImage: cgImage)
    }

    private func sampleImage(settings: QuotaBar.Settings, index: Int = 0) -> NSImage {
        let poses: [ProviderKind: CyclistFrame] = settings.showCyclist
            ? [.claude: CyclistFrame(cadence: .normal, index: index % 8),
               .codex: CyclistFrame(cadence: .standing, index: (index + 3) % 8)] : [:]
        return StatusTitleImage.make(statuses: usageStatuses(), settings: settings, mode: .used, cyclists: poses)
    }

    private func usageStatuses(claude: Double = 11, codex: Double = 87) -> [ProviderKind: ProviderStatus] {
        Dictionary(uniqueKeysWithValues: ProviderKind.allCases.map { kind in
            (kind, ProviderStatus(snapshot: UsageSnapshot(
                session: UsageWindow(usedPercent: kind == .claude ? claude : codex, resetsAt: nil),
                weekly: nil, planLabel: nil, fetchedAt: Date(timeIntervalSince1970: 0), sourceNote: nil)))
        })
    }

    private func writeArtifact(_ data: Data, name: String) throws {
        guard let path = ProcessInfo.processInfo.environment["PREVIEW_ARTIFACT_DIR"] else { return }
        let directory = URL(fileURLWithPath: path, isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(name))
    }

    func testWriteMenuBarSheet() throws {
        guard let out = ProcessInfo.processInfo.environment["MENUBAR_OUT"] else {
            throw XCTSkip("set MENUBAR_OUT to render")
        }
        let statuses = PreviewData.statuses()
        // Claude steady, Codex sprinting: the pair that has to stay legible side by side.
        let poses: [ProviderKind: CyclistFrame] = [.claude: CyclistFrame(cadence: .normal, index: 2),
                                                   .codex: CyclistFrame(cadence: .standing, index: 5)]

        struct Row { let caption: String; let style: MenuBarStyle; let colors: IndicatorColorMode }
        let rows = [Row(caption: "ring · usage colors", style: .ring, colors: .usage),
                    Row(caption: "ring · monochrome", style: .ring, colors: .monochrome),
                    Row(caption: "badge · usage colors", style: .percentageBadge, colors: .usage),
                    Row(caption: "bar · monochrome", style: .bar, colors: .monochrome)]

        let rowHeight: CGFloat = 116
        let sheet = NSSize(width: 980, height: rowHeight * CGFloat(rows.count) + 20)
        let image = NSImage(size: sheet)
        image.lockFocus()
        NSColor.white.setFill()
        NSRect(origin: .zero, size: sheet).fill()

        for (index, row) in rows.enumerated() {
            var settings = Settings.default
            settings.showCyclist = true
            settings.menuBarStyle = row.style
            settings.colorMode = row.colors
            let top = sheet.height - CGFloat(index) * rowHeight - 24
            (row.caption as NSString).draw(at: NSPoint(x: 16, y: top),
                                           withAttributes: [.font: NSFont.systemFont(ofSize: 13, weight: .medium),
                                                            .foregroundColor: NSColor.black])

            for (column, appearance) in [NSAppearance(named: .aqua), NSAppearance(named: .darkAqua)].enumerated() {
                let light = column == 0
                let originX: CGFloat = 16 + CGFloat(column) * 480
                appearance?.performAsCurrentDrawingAppearance {
                    let bar = StatusTitleImage.make(statuses: statuses, settings: settings,
                                                    mode: .used, cyclists: poses)
                    // Actual size, on a menu bar of the matching appearance.
                    let strip = NSRect(x: originX, y: top - 34, width: bar.size.width + 20, height: 26)
                    (light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                    strip.fill()
                    bar.draw(in: NSRect(x: strip.minX + 10, y: strip.minY + 2, width: bar.size.width, height: 22))

                    // Enlarged, to judge the drawing rather than the screen.
                    let zoom: CGFloat = 2.6
                    let big = NSRect(x: originX, y: top - 44 - 22 * zoom,
                                     width: bar.size.width * zoom, height: 22 * zoom)
                    (light ? NSColor(white: 0.96, alpha: 1) : NSColor(white: 0.13, alpha: 1)).setFill()
                    big.insetBy(dx: -6, dy: -4).fill()
                    bar.draw(in: big)
                }
            }
        }
        image.unlockFocus()

        guard let tiff = image.tiffRepresentation, let rep = NSBitmapImageRep(data: tiff),
              let png = rep.representation(using: .png, properties: [:]) else { return XCTFail("no png") }
        try png.write(to: URL(fileURLWithPath: out))
    }
}
