import AppKit
import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation
import ImageIO
import ScreenCaptureKit
import UniformTypeIdentifiers

enum ScreenError: Error, CustomStringConvertible {
    case usage
    case captureUnavailable
    case encoderUnavailable

    var description: String {
        switch self {
        case .usage:
            return "usage: macpp-screen [--max-width PIXELS] [--quality 0..1] [--stream-path PATH --stream-fps FPS]"
        case .captureUnavailable:
            return "screen capture unavailable; grant Screen Recording permission to Mac++ Remote"
        case .encoderUnavailable:
            return "could not encode the captured screen"
        }
    }
}

struct Options {
    var maxWidth = 1280
    var quality = 0.62
    var streamPath: String? = nil
    var streamFPS = 12.0
}

func parseOptions() throws -> Options {
    var options = Options()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        let argument = arguments.removeFirst()
        switch argument {
        case "--max-width":
            guard let raw = arguments.first, let width = Int(raw), width >= 320, width <= 4096 else {
                throw ScreenError.usage
            }
            arguments.removeFirst()
            options.maxWidth = width
        case "--quality":
            guard let raw = arguments.first, let quality = Double(raw), quality.isFinite, (0.25...0.95).contains(quality) else {
                throw ScreenError.usage
            }
            arguments.removeFirst()
            options.quality = quality
        case "--stream-path":
            guard let path = arguments.first, !path.isEmpty else {
                throw ScreenError.usage
            }
            arguments.removeFirst()
            options.streamPath = path
        case "--stream-fps":
            guard let raw = arguments.first,
                  let fps = Double(raw),
                  fps.isFinite,
                  (1.0...30.0).contains(fps) else {
                throw ScreenError.usage
            }
            arguments.removeFirst()
            options.streamFPS = fps
        default:
            throw ScreenError.usage
        }
    }
    if options.streamPath != nil && options.streamFPS <= 0 {
        throw ScreenError.usage
    }
    return options
}

func encodeJPEG(_ image: CGImage, quality: Double) throws -> Data {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.jpeg.identifier as CFString,
        1,
        nil
    ) else {
        throw ScreenError.encoderUnavailable
    }
    let properties: [CFString: Any] = [kCGImageDestinationLossyCompressionQuality: quality]
    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw ScreenError.encoderUnavailable
    }
    return output as Data
}

func capture(options: Options) async throws -> Data {
    guard #available(macOS 14.0, *) else {
        throw ScreenError.captureUnavailable
    }
    // ScreenCaptureKit gives us one current-display frame without keeping a
    // long-lived capture stream alive. The bridge only invokes this helper
    // while the phone's Live Mac window is open.
    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
    } catch {
        throw ScreenError.captureUnavailable
    }
    guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() }) ?? content.displays.first else {
        throw ScreenError.captureUnavailable
    }

    let scale = min(1.0, Double(options.maxWidth) / Double(max(1, display.width)))
    let configuration = SCStreamConfiguration()
    configuration.width = max(320, Int((Double(display.width) * scale).rounded()))
    configuration.height = max(180, Int((Double(display.height) * scale).rounded()))
    configuration.showsCursor = true
    configuration.queueDepth = 1
    let filter = SCContentFilter(display: display, excludingWindows: [])
    do {
        let image = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
        return try encodeJPEG(image, quality: options.quality)
    } catch {
        throw ScreenError.captureUnavailable
    }
}

func writeStreamFrame(_ data: Data, to path: String) throws {
    // `Data.write(options: .atomic)` replaces the destination only after the
    // JPEG is complete. The Game sampler can therefore read this file from a
    // timer without ever decoding a half-written frame.
    try data.write(to: URL(fileURLWithPath: path), options: [.atomic])
}

final class PersistentScreenStream: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    private let options: Options
    private let path: String
    private let outputQueue: DispatchQueue
    private let stateLock = NSLock()
    private var captureStream: SCStream?
    private var stopContinuation: CheckedContinuation<Void, Error>?
    private var pendingStopResult: Result<Void, Error>?
    private var finished = false
    private var stopped = false
    private var lastWriteError = Date.distantPast
    private var latestFrame: Data?
    private var heartbeat: DispatchSourceTimer?

    init(options: Options, path: String) {
        self.options = options
        self.path = path
        self.outputQueue = DispatchQueue(label: "org.macplusplus.macpp.screen-stream", qos: .userInitiated)
        super.init()
    }

    func run() async throws {
        let content: SCShareableContent
        do {
            content = try await SCShareableContent.excludingDesktopWindows(
                false,
                onScreenWindowsOnly: true
            )
        } catch {
            throw ScreenError.captureUnavailable
        }
        guard let display = content.displays.first(where: { $0.displayID == CGMainDisplayID() })
                ?? content.displays.first else {
            throw ScreenError.captureUnavailable
        }
        guard !wasStopped() else { throw CancellationError() }

        let scale = min(1.0, Double(options.maxWidth) / Double(max(1, display.width)))
        let configuration = SCStreamConfiguration()
        configuration.width = max(320, Int((Double(display.width) * scale).rounded()))
        configuration.height = max(180, Int((Double(display.height) * scale).rounded()))
        configuration.minimumFrameInterval = CMTime(
            value: 1,
            timescale: CMTimeScale(max(1, Int(options.streamFPS.rounded())))
        )
        configuration.pixelFormat = kCVPixelFormatType_32BGRA
        configuration.showsCursor = true
        configuration.queueDepth = 1

        let filter = SCContentFilter(display: display, excludingWindows: [])
        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        do {
            try stream.addStreamOutput(
                self,
                type: .screen,
                sampleHandlerQueue: outputQueue
            )
        } catch {
            throw error
        }

        let cancelledBeforeStart = installCaptureStream(stream)
        if cancelledBeforeStart {
            throw CancellationError()
        }

        try await stream.startCapture()
        if wasStopped() { throw CancellationError() }
        startHeartbeat()
        try await waitUntilStopped()
    }

    func stop() {
        stateLock.lock()
        stopped = true
        stateLock.unlock()
        // The process is a short-lived launchd worker. Resuming the waiter
        // immediately lets its owning Task release SCStream; the OS also
        // tears the stream down on process termination. Normal stream errors
        // already arrive through didStopWithError before this path is used.
        finish(.success(()))
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of type: SCStreamOutputType
    ) {
        guard type == .screen,
              let image = image(from: sampleBuffer) else { return }
        do {
            let frame = try encodeJPEG(image, quality: options.quality)
            storeLatestFrame(frame)
            try writeStreamFrame(frame, to: path)
        } catch {
            let now = Date()
            if now.timeIntervalSince(lastWriteError) >= 1.0 {
                lastWriteError = now
                FileHandle.standardError.write(
                    Data("macpp-screen stream: \(error)\n".utf8)
                )
            }
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        finish(.failure(error))
    }

    private func image(from sampleBuffer: CMSampleBuffer) -> CGImage? {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return nil }
        CVPixelBufferLockBaseAddress(pixelBuffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, .readOnly) }
        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let width = CVPixelBufferGetWidth(pixelBuffer)
        let height = CVPixelBufferGetHeight(pixelBuffer)
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let bitmapInfo = CGImageAlphaInfo.premultipliedFirst.rawValue
            | CGBitmapInfo.byteOrder32Little.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo
        ) else { return nil }
        return context.makeImage()
    }

    private func waitUntilStopped() async throws {
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            if let result = registerStopWaiter(continuation) {
                continuation.resume(with: result)
            }
        }
    }

    private func registerStopWaiter(
        _ continuation: CheckedContinuation<Void, Error>
    ) -> Result<Void, Error>? {
        stateLock.lock()
        defer { stateLock.unlock() }
        if let result = pendingStopResult {
            pendingStopResult = nil
            return result
        }
        stopContinuation = continuation
        return nil
    }

    private func installCaptureStream(_ stream: SCStream) -> Bool {
        stateLock.lock()
        captureStream = stream
        let cancelled = stopped
        stateLock.unlock()
        return cancelled
    }

    private func wasStopped() -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return stopped
    }

    private func finish(_ result: Result<Void, Error>) {
        stateLock.lock()
        guard !finished else {
            stateLock.unlock()
            return
        }
        finished = true
        let continuation = stopContinuation
        stopContinuation = nil
        let heartbeat = self.heartbeat
        self.heartbeat = nil
        if continuation == nil { pendingStopResult = result }
        stateLock.unlock()
        heartbeat?.cancel()
        continuation?.resume(with: result)
    }

    private func startHeartbeat() {
        let timer = DispatchSource.makeTimerSource(queue: outputQueue)
        let interval = 1.0 / options.streamFPS
        timer.schedule(
            deadline: .now() + interval,
            repeating: interval,
            leeway: .milliseconds(2)
        )
        timer.setEventHandler { [weak self] in
            self?.writeLatestFrame()
        }
        stateLock.lock()
        heartbeat = timer
        stateLock.unlock()
        timer.resume()
    }

    private func storeLatestFrame(_ frame: Data) {
        stateLock.lock()
        latestFrame = frame
        stateLock.unlock()
    }

    private func writeLatestFrame() {
        stateLock.lock()
        let frame = latestFrame
        stateLock.unlock()
        guard let frame else { return }
        do {
            try writeStreamFrame(frame, to: path)
        } catch {
            let now = Date()
            if now.timeIntervalSince(lastWriteError) >= 1.0 {
                lastWriteError = now
                FileHandle.standardError.write(
                    Data("macpp-screen stream heartbeat: \(error)\n".utf8)
                )
            }
        }
    }
}


func stream(options: Options, path: String) async throws -> Never {
    var retryDelay: UInt64 = 250_000_000
    while true {
        do {
            let worker = PersistentScreenStream(options: options, path: path)
            try await withTaskCancellationHandler {
                try await worker.run()
            } onCancel: {
                worker.stop()
            }
            if Task.isCancelled { throw CancellationError() }
            retryDelay = 250_000_000
        } catch {
            if error is CancellationError { throw error }
            // Keep a persistent launchd owner alive through a transient
            // WindowServer/display handoff. The consumer's stale-frame gate
            // decides when the owner itself needs to be restarted.
            FileHandle.standardError.write(Data("macpp-screen stream: \(error)\n".utf8))
            try await Task.sleep(nanoseconds: retryDelay)
            retryDelay = min(8_000_000_000, retryDelay * 2)
        }
    }
}

@main
struct MacPlusPlusScreenMain {
    static func main() async {
        do {
            let options = try parseOptions()
            if let streamPath = options.streamPath {
                try await stream(options: options, path: streamPath)
            }
            FileHandle.standardOutput.write(try await capture(options: options))
        } catch {
            FileHandle.standardError.write(Data("macpp-screen: \(error)\n".utf8))
            exit(2)
        }
    }
}
