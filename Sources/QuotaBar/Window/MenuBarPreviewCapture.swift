import AppKit
import AVFoundation
import SwiftUI
import UniformTypeIdentifiers
import ScreenCaptureKit

struct MenuBarLivePreview: View {
    @EnvironmentObject private var statusBar: StatusBarController
    @StateObject private var capture = MenuBarPreviewCapture()

    var body: some View {
        HStack(spacing: 24) {
            NativeMenuPreview(image: statusBar.currentImage, capture: capture)
                .frame(width: 160, height: 160)
                .accessibilityLabel(L("Menu bar style preview"))
            VStack(spacing: 12) {
                Button { capture.saveScreenshot() } label: {
                    Label(L("Screenshot"), systemImage: "camera")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.bordered)
                .disabled(capture.isRecording || capture.isExporting)
                Button {
                    if capture.isRecording { capture.stopAndSaveRecording() }
                    else { capture.startRecording() }
                } label: {
                    Label(L(capture.isRecording ? "Stop recording" : "Start recording"),
                          systemImage: capture.isRecording ? "stop.circle.fill" : "record.circle")
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 3)
                }
                .buttonStyle(.borderedProminent)
                .tint(capture.isRecording ? .red : .accentColor)
                .disabled(capture.isExporting)

                Group {
                    if capture.isRecording {
                        Text(L("Recording %@", capture.durationText)).foregroundColor(.red)
                    } else if capture.isExporting {
                        Text(L("Saving preview…"))
                            .foregroundColor(.secondary)
                    } else {
                        Text(verbatim: "\(MenuBarPreviewRenderer.side) × \(MenuBarPreviewRenderer.side) · PNG / MP4")
                            .foregroundColor(.secondary)
                    }
                }
                .font(Typography.caption).monospacedDigit()
                .frame(height: 16)
            }
            .controlSize(.large)
            .frame(width: 160)
            .frame(maxWidth: .infinity)
        }
        .onAppear { capture.startPreview() }
        .onDisappear { capture.stopPreview() }
    }
}

enum MenuBarPreviewRenderer {
    static let side = 320
    static let size = NSSize(width: side, height: side)
}

private struct NativeMenuPreview: NSViewRepresentable {
    let image: NSImage
    let capture: MenuBarPreviewCapture

    func makeNSView(context: Context) -> NativePreviewView {
        let view = NativePreviewView()
        view.capture = capture
        capture.view = view
        view.image = image
        return view
    }

    func updateNSView(_ view: NativePreviewView, context: Context) {
        view.image = image
    }
}

/// System menu material and the exact current status-bar image share one capture region.
final class NativePreviewView: NSVisualEffectView {
    weak var capture: MenuBarPreviewCapture?
    private let imageView = NSImageView()
    private var observers: [NSObjectProtocol] = []

    var image: NSImage? {
        get { imageView.image }
        set { imageView.image = newValue }
    }

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 160, height: 160))
        material = .menu
        blendingMode = .behindWindow
        state = .active
        wantsLayer = true
        layer?.cornerRadius = 12
        layer?.masksToBounds = true
        imageView.imageScaling = .scaleProportionallyUpOrDown
        imageView.setAccessibilityLabel(L("Menu bar style preview"))
        addSubview(imageView)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func layout() {
        super.layout()
        imageView.frame = bounds.insetBy(dx: bounds.width * 0.075, dy: bounds.height * 0.35)
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        observers.forEach(NotificationCenter.default.removeObserver)
        observers.removeAll()
        guard let window else { return }
        for name in [NSWindow.willCloseNotification, NSWindow.didBecomeKeyNotification, NSWindow.didResizeNotification] {
            observers.append(NotificationCenter.default.addObserver(forName: name, object: window, queue: .main) { [weak self] note in
                MainActor.assumeIsolated {
                    if note.name == NSWindow.didBecomeKeyNotification { self?.capture?.startPreview() }
                    else if note.name == NSWindow.willCloseNotification { self?.capture?.stopPreview() }
                    else { self?.capture?.geometryChanged() }
                }
            })
        }
        if let clip = enclosingScrollView?.contentView {
            clip.postsBoundsChangedNotifications = true
            observers.append(NotificationCenter.default.addObserver(forName: NSView.boundsDidChangeNotification,
                                                                      object: clip, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.capture?.geometryChanged() }
            })
        }
    }

    deinit { observers.forEach(NotificationCenter.default.removeObserver) }

    @MainActor
    func captureSession() async throws -> NativePreviewStream {
        guard let window, window.isVisible, !window.isMiniaturized else { throw PreviewExportError.render }
        let content: SCShareableContent
        if #available(macOS 14.4, *) {
            content = try await SCShareableContent.currentProcess
        } else {
            content = try await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true)
        }
        try Task.checkCancellation()
        guard self.window === window, window.isVisible,
              visibleRect.insetBy(dx: -0.5, dy: -0.5).contains(bounds),
              let target = content.windows.first(where: {
                  $0.windowID == CGWindowID(window.windowNumber)
                      && $0.owningApplication?.processID == ProcessInfo.processInfo.processIdentifier
              }) else { throw PreviewExportError.render }
        layoutSubtreeIfNeeded()
        let config = SCStreamConfiguration()
        config.width = MenuBarPreviewRenderer.side
        config.height = MenuBarPreviewRenderer.side
        config.pixelFormat = kCVPixelFormatType_32BGRA
        config.minimumFrameInterval = CMTime(value: 1, timescale: 30)
        config.queueDepth = 3
        config.showsCursor = false
        config.capturesAudio = false
        config.backgroundColor = NSColor.windowBackgroundColor.cgColor
        if #available(macOS 14.0, *) { config.ignoreShadowsSingleWindow = true }
        let rect = convert(bounds, to: nil)
        config.sourceRect = CGRect(x: rect.minX, y: window.frame.height - rect.maxY,
                                   width: rect.width, height: rect.height)
        return try NativePreviewStream(filter: SCContentFilter(desktopIndependentWindow: target), configuration: config)
    }
}

/// Keeps at most the newest unconsumed frame, so encoder backpressure cannot queue screenshots.
@MainActor
final class NativePreviewStream: NSObject, SCStreamOutput, SCStreamDelegate {
    struct Frame: @unchecked Sendable {
        let buffer: CVPixelBuffer
        let time: CMTime
    }
    let frames: AsyncThrowingStream<Frame, Error>
    nonisolated private let continuation: AsyncThrowingStream<Frame, Error>.Continuation
    private var stream: SCStream!
    private var stopped = false

    init(filter: SCContentFilter, configuration: SCStreamConfiguration) throws {
        let pair = AsyncThrowingStream<Frame, Error>.makeStream(bufferingPolicy: .bufferingNewest(1))
        frames = pair.stream
        continuation = pair.continuation
        super.init()
        stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: DispatchQueue(label: "quotabar.preview.frames"))
    }

    func start() async throws { try await stream.startCapture() }

    func stop() async {
        guard !stopped else { return }
        stopped = true
        continuation.finish()
        try? await stream.stopCapture()
        try? stream.removeStreamOutput(self, type: .screen)
        stream = nil
    }

    nonisolated func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen, sampleBuffer.isValid,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false) as? [[SCStreamFrameInfo: Any]],
              let status = attachments.first?[.status] as? Int, status == SCFrameStatus.complete.rawValue,
              let buffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        continuation.yield(Frame(buffer: buffer, time: CMSampleBufferGetPresentationTimeStamp(sampleBuffer)))
    }

    nonisolated func stream(_ stream: SCStream, didStopWithError error: Error) {
        continuation.finish(throwing: error)
    }
}

@MainActor
final class MenuBarPreviewCapture: ObservableObject {
    @Published private(set) var isRecording = false
    @Published private(set) var isExporting = false
    @Published private(set) var recordedSeconds = 0
    weak var view: NativePreviewView?
    private var visible = false
    private var operation: Task<Void, Never>?
    private var reader: Task<Void, Never>?
    private var session: NativePreviewStream?
    private var movie: PreviewMovieWriter?
    private var durationTimer: Timer?
    private var recordingStart: TimeInterval = 0

    var durationText: String { String(format: "%02d:%02d", recordedSeconds / 60, recordedSeconds % 60) }

    deinit { durationTimer?.invalidate() }

    func startPreview() { visible = true }

    func stopPreview() {
        visible = false
        geometryChanged()
    }

    /// Stop before a scroll or resize can move other content into the fixed capture rectangle.
    func geometryChanged() {
        operation?.cancel()
        if isRecording { stopAndSaveRecording() }
    }

    func saveScreenshot() {
        guard visible, !isRecording, !isExporting, let view else { return }
        isExporting = true
        operation = Task { [self] in
            do {
                let session = try await view.captureSession()
                defer { Task { await session.stop() } }
                try await session.start()
                var iterator = session.frames.makeAsyncIterator()
                guard let frame = try await iterator.next() else { throw CancellationError() }
                try Task.checkCancellation()
                let context = CIContext()
                let input = CIImage(cvPixelBuffer: frame.buffer)
                guard let image = context.createCGImage(input, from: input.extent),
                      let png = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
                    throw PreviewExportError.render
                }
                await session.stop()
                let panel = savePanel(type: .png, extension: "png")
                panel.begin { [self] response in
                    defer { isExporting = false }
                    guard response == .OK, let url = panel.url else { return }
                    do { try png.write(to: url, options: .atomic) }
                    catch { report(error) }
                }
            } catch {
                isExporting = false
                if !Task.isCancelled { report(error) }
            }
        }
    }

    func startRecording() {
        guard visible, !isRecording, !isExporting, let view else { return }
        isExporting = true
        operation = Task { [self] in
            var prepared: NativePreviewStream?
            do {
                let session = try await view.captureSession()
                prepared = session
                try await session.start()
                var iterator = session.frames.makeAsyncIterator()
                guard let first = try await iterator.next() else { throw CancellationError() }
                try Task.checkCancellation()
                guard visible else { throw CancellationError() }
                let writer = try PreviewMovieWriter()
                try writer.append(first.buffer, at: 0)
                self.session = session
                movie = writer
                recordingStart = ProcessInfo.processInfo.systemUptime
                recordedSeconds = 0
                isRecording = true
                isExporting = false
                let timer = Timer(timeInterval: 1, repeats: true) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self else { return }
                        self.recordedSeconds = Int(ProcessInfo.processInfo.systemUptime - self.recordingStart)
                    }
                }
                RunLoop.main.add(timer, forMode: .common)
                durationTimer = timer
                reader = Task {
                    do {
                        while let frame = try await iterator.next() {
                            guard !Task.isCancelled, isRecording else { break }
                            let elapsed = max(0, (frame.time - first.time).seconds)
                            try writer.append(frame.buffer, at: elapsed)
                            recordedSeconds = Int(ProcessInfo.processInfo.systemUptime - recordingStart)
                        }
                    } catch {
                        guard !Task.isCancelled, isRecording else { return }
                        isRecording = false
                        durationTimer?.invalidate()
                        durationTimer = nil
                        self.session = nil
                        movie = nil
                        await session.stop()
                        writer.cancel()
                        report(error)
                    }
                }
            } catch {
                await prepared?.stop()
                isExporting = false
                if !Task.isCancelled { report(error) }
            }
        }
    }

    func stopAndSaveRecording() {
        guard isRecording, let movie, let session else { return }
        self.movie = nil
        self.session = nil
        isRecording = false
        isExporting = true
        durationTimer?.invalidate()
        durationTimer = nil
        reader?.cancel()
        reader = nil
        let duration = ProcessInfo.processInfo.systemUptime - recordingStart
        Task {
            do {
                await session.stop()
                let url = try await movie.finish(at: duration)
                let panel = savePanel(type: .mpeg4Movie, extension: "mp4")
                panel.begin { [self] response in
                    defer { movie.cancel(); isExporting = false }
                    guard response == .OK, let destination = panel.url else { return }
                    do {
                        if FileManager.default.fileExists(atPath: destination.path) {
                            _ = try FileManager.default.replaceItemAt(destination, withItemAt: url)
                        } else { try FileManager.default.copyItem(at: url, to: destination) }
                    } catch { report(error) }
                }
            } catch {
                movie.cancel()
                isExporting = false
                report(error)
            }
        }
    }

    private func savePanel(type: UTType, extension suffix: String) -> NSSavePanel {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [type]
        panel.nameFieldStringValue = "quotabar-preview.\(suffix)"
        panel.title = L("Save preview")
        return panel
    }

    private func report(_ error: Error) {
        let alert = NSAlert()
        alert.messageText = L("Preview export failed")
        alert.informativeText = error.localizedDescription
        alert.addButton(withTitle: L("OK"))
        alert.runModal()
    }
}

private enum PreviewExportError: LocalizedError {
    case render, encode
    var errorDescription: String? {
        L(self == .render ? "Could not render the preview." : "Could not encode the preview video.")
    }
}

/// Encodes only square preview pixels; frame timestamps follow elapsed recording time.
@MainActor
final class PreviewMovieWriter {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("quotabar-preview-\(UUID()).mp4")
    private let writer: AVAssetWriter
    private let input: AVAssetWriterInput
    private let adaptor: AVAssetWriterInputPixelBufferAdaptor
    private var lastTime: CMTime = .invalid

    init() throws {
        writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: MenuBarPreviewRenderer.side,
            AVVideoHeightKey: MenuBarPreviewRenderer.side,
            AVVideoCompressionPropertiesKey: [AVVideoAverageBitRateKey: 4_000_000,
                                              AVVideoExpectedSourceFrameRateKey: 30]
        ])
        input.expectsMediaDataInRealTime = true
        adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: MenuBarPreviewRenderer.side,
            kCVPixelBufferHeightKey as String: MenuBarPreviewRenderer.side,
            kCVPixelBufferCGImageCompatibilityKey as String: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey as String: true
        ])
        guard writer.canAdd(input) else { throw PreviewExportError.encode }
        writer.add(input)
        guard writer.startWriting() else { throw writer.error ?? PreviewExportError.encode }
        writer.startSession(atSourceTime: .zero)
    }

    deinit { try? FileManager.default.removeItem(at: url) }

    func append(_ buffer: CVPixelBuffer, at seconds: TimeInterval) throws {
        guard writer.status == .writing else { throw writer.error ?? PreviewExportError.encode }
        guard input.isReadyForMoreMediaData else { return }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 60_000)
        guard !lastTime.isValid || time > lastTime else { return }
        guard adaptor.append(buffer, withPresentationTime: time) else { throw writer.error ?? PreviewExportError.encode }
        lastTime = time
    }

    func finish(at seconds: TimeInterval) async throws -> URL {
        guard lastTime.isValid, writer.status == .writing else {
            throw writer.error ?? PreviewExportError.encode
        }
        let end = max(CMTime(seconds: seconds, preferredTimescale: 60_000),
                      lastTime + CMTime(value: 1, timescale: 30))
        writer.endSession(atSourceTime: end)
        input.markAsFinished()
        await writer.finishWriting()
        guard writer.status == .completed else { throw writer.error ?? PreviewExportError.encode }
        return url
    }

    func cancel() {
        if writer.status == .writing { writer.cancelWriting() }
        try? FileManager.default.removeItem(at: url)
    }
}
