import AppKit
import CoreGraphics
import Foundation
import ImageIO
@preconcurrency import ScreenCaptureKit
import UniformTypeIdentifiers

private struct FrozenDisplay {
    let screen: NSScreen
    let image: CGImage
}

private struct FreezeCaptureResult {
    let copied: Bool
    let savedURL: URL?
    let pixelWidth: Int
    let pixelHeight: Int

    var json: [String: Any] {
        [
            "schema_version": 1,
            "status": "captured",
            "copied": copied,
            "saved": savedURL?.path ?? NSNull(),
            "width": pixelWidth,
            "height": pixelHeight,
        ]
    }
}

private func writeJSON(_ object: [String: Any]) throws {
    let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@MainActor
private func targetScreen(for target: MacPlusPlusFreezeDisplayTarget) -> NSScreen? {
    switch target {
    case .main:
        return NSScreen.main ?? NSScreen.screens.first
    case .pointer:
        let pointer = NSEvent.mouseLocation
        return NSScreen.screens.first(where: { NSMouseInRect(pointer, $0.frame, false) })
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}

@MainActor
private func displayID(for screen: NSScreen) -> CGDirectDisplayID? {
    (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value
}

@MainActor
private func freezeDisplay(options: MacPlusPlusFreezeCaptureOptions) async throws -> FrozenDisplay {
    guard #available(macOS 14.0, *) else {
        throw MacPlusPlusFreezeCaptureError.captureUnavailable
    }
    // This is deliberately the first interactive operation. MacPlusPlus owns no
    // window and does not activate until this one-shot screenshot has fully
    // completed, so menus, hover cards, and transient shell UI survive in it.
    guard let screen = targetScreen(for: options.displayTarget),
          let targetID = displayID(for: screen) else {
        throw MacPlusPlusFreezeCaptureError.captureUnavailable
    }

    let content: SCShareableContent
    do {
        content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
    } catch {
        throw MacPlusPlusFreezeCaptureError.captureUnavailable
    }
    guard let display = content.displays.first(where: { $0.displayID == targetID }) else {
        throw MacPlusPlusFreezeCaptureError.captureUnavailable
    }

    let configuration = SCStreamConfiguration()
    configuration.width = display.width
    configuration.height = display.height
    configuration.showsCursor = options.showsCursor
    configuration.queueDepth = 1
    let filter = SCContentFilter(display: display, excludingWindows: [])
    do {
        let image = try await SCScreenshotManager.captureImage(
            contentFilter: filter,
            configuration: configuration
        )
        return FrozenDisplay(screen: screen, image: image)
    } catch {
        throw MacPlusPlusFreezeCaptureError.captureUnavailable
    }
}

private func encodePNG(_ image: CGImage) throws -> Data {
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(
        output,
        UTType.png.identifier as CFString,
        1,
        nil
    ) else {
        throw MacPlusPlusFreezeCaptureError.imageEncodingFailed
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else {
        throw MacPlusPlusFreezeCaptureError.imageEncodingFailed
    }
    return output as Data
}

private func persist(
    image: CGImage,
    options: MacPlusPlusFreezeCaptureOptions,
    homeDirectory: URL
) throws -> FreezeCaptureResult {
    let data = try encodePNG(image)
    let savedURL = try macppFreezeWritePNG(
        data,
        target: options.saveTarget,
        replacing: options.replaceExisting,
        homeDirectory: homeDirectory
    )

    if options.copyToClipboard {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        guard pasteboard.setData(data, forType: .png) else {
            throw MacPlusPlusFreezeCaptureError.outputFailed("could not place the selected PNG on the clipboard")
        }
    }

    return FreezeCaptureResult(
        copied: options.copyToClipboard,
        savedURL: savedURL,
        pixelWidth: image.width,
        pixelHeight: image.height
    )
}

@MainActor
private final class FreezeSelectionView: NSView {
    let frozenImage: CGImage
    var onSelection: ((CGRect) -> Void)?
    var onCancel: (() -> Void)?

    private var anchor: CGPoint?
    private var selection: CGRect?

    init(frame: CGRect, frozenImage: CGImage) {
        self.frozenImage = frozenImage
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) {
        nil
    }

    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() {
        addCursorRect(bounds, cursor: .crosshair)
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        let image = NSImage(cgImage: frozenImage, size: bounds.size)
        image.draw(in: bounds, from: .zero, operation: .copy, fraction: 1)

        if let selection, selection.width >= 1, selection.height >= 1 {
            let shade = NSBezierPath(rect: bounds)
            shade.appendRect(selection)
            shade.windingRule = .evenOdd
            NSColor.black.withAlphaComponent(0.34).setFill()
            shade.fill()

            NSColor.white.withAlphaComponent(0.94).setStroke()
            let border = NSBezierPath(rect: selection.insetBy(dx: 0.5, dy: 0.5))
            border.lineWidth = 1
            border.stroke()

            let size = "\(Int(selection.width.rounded())) × \(Int(selection.height.rounded()))"
            let attributes: [NSAttributedString.Key: Any] = [
                .font: NSFont.monospacedSystemFont(ofSize: 11, weight: .medium),
                .foregroundColor: NSColor.white,
                .backgroundColor: NSColor.black.withAlphaComponent(0.68),
            ]
            let label = NSAttributedString(string: "  \(size)  ", attributes: attributes)
            let labelSize = label.size()
            var origin = CGPoint(x: selection.minX, y: selection.maxY + 6)
            if origin.y + labelSize.height > bounds.maxY {
                origin.y = max(bounds.minY, selection.minY - labelSize.height - 6)
            }
            label.draw(at: origin)
        }
    }

    override func mouseDown(with event: NSEvent) {
        let point = constrained(convert(event.locationInWindow, from: nil))
        anchor = point
        selection = CGRect(origin: point, size: .zero)
        needsDisplay = true
    }

    override func mouseDragged(with event: NSEvent) {
        guard let anchor else { return }
        selection = CGRect(origin: anchor, size: CGSize(
            width: constrained(convert(event.locationInWindow, from: nil)).x - anchor.x,
            height: constrained(convert(event.locationInWindow, from: nil)).y - anchor.y
        )).standardized
        needsDisplay = true
    }

    override func mouseUp(with event: NSEvent) {
        guard let anchor else { return }
        let end = constrained(convert(event.locationInWindow, from: nil))
        let final = CGRect(
            x: min(anchor.x, end.x),
            y: min(anchor.y, end.y),
            width: abs(end.x - anchor.x),
            height: abs(end.y - anchor.y)
        )
        self.anchor = nil
        if final.width < 2 || final.height < 2 {
            selection = nil
            needsDisplay = true
            NSSound.beep()
            return
        }
        selection = final
        needsDisplay = true
        onSelection?(final)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 {
            onCancel?()
        } else {
            super.keyDown(with: event)
        }
    }

    private func constrained(_ point: CGPoint) -> CGPoint {
        CGPoint(
            x: min(max(point.x, bounds.minX), bounds.maxX),
            y: min(max(point.y, bounds.minY), bounds.maxY)
        )
    }
}

@MainActor
private final class FreezePickerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    private let frozen: FrozenDisplay
    private let options: MacPlusPlusFreezeCaptureOptions
    private let homeDirectory: URL
    private(set) var outcome: Result<FreezeCaptureResult, Error>?
    private var window: NSWindow?

    init(frozen: FrozenDisplay, options: MacPlusPlusFreezeCaptureOptions, homeDirectory: URL) {
        self.frozen = frozen
        self.options = options
        self.homeDirectory = homeDirectory
    }

    func start() {
        let application = NSApplication.shared
        application.setActivationPolicy(.accessory)

        let window = NSWindow(
            contentRect: frozen.screen.frame,
            styleMask: .borderless,
            backing: .buffered,
            defer: false,
            screen: frozen.screen
        )
        window.level = .screenSaver
        window.isOpaque = true
        window.backgroundColor = .black
        window.hasShadow = false
        window.isReleasedWhenClosed = false
        window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        window.delegate = self

        let view = FreezeSelectionView(
            frame: CGRect(origin: .zero, size: frozen.screen.frame.size),
            frozenImage: frozen.image
        )
        view.onCancel = { [weak self] in self?.cancel() }
        view.onSelection = { [weak self] selection in self?.finish(selection: selection, in: view.bounds.size) }
        window.contentView = view
        self.window = window

        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(view)
        application.activate(ignoringOtherApps: true)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func windowWillClose(_ notification: Notification) {
        if outcome == nil {
            cancel()
        }
    }

    private func finish(selection: CGRect, in viewSize: CGSize) {
        do {
            let plan = try MacPlusPlusFreezeCropPlan.make(
                selection: selection,
                viewSize: viewSize,
                imageSize: CGSize(width: frozen.image.width, height: frozen.image.height)
            )
            guard let cropped = frozen.image.cropping(to: plan.pixelRect) else {
                throw MacPlusPlusFreezeCaptureError.imageEncodingFailed
            }
            outcome = .success(try persist(image: cropped, options: options, homeDirectory: homeDirectory))
        } catch {
            outcome = .failure(error)
        }
        stop()
    }

    private func cancel() {
        guard outcome == nil else { return }
        outcome = .failure(MacPlusPlusFreezeCaptureError.cancelled)
        stop()
    }

    private func stop() {
        window?.orderOut(nil)
        window?.close()
        NSApplication.shared.stop(nil)
        if let wake = NSEvent.otherEvent(
            with: .applicationDefined,
            location: .zero,
            modifierFlags: [],
            timestamp: ProcessInfo.processInfo.systemUptime,
            windowNumber: 0,
            context: nil,
            subtype: 0,
            data1: 0,
            data2: 0
        ) {
            NSApplication.shared.postEvent(wake, atStart: false)
        }
    }
}

@main
@MainActor
struct MacPlusPlusFreezeCaptureMain {
    static func main() async {
        if CommandLine.arguments.dropFirst().contains(where: { $0 == "--help" || $0 == "-h" }) {
            print(MacPlusPlusFreezeCaptureOptions.usage)
            return
        }

        let homeDirectory = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL
        let options: MacPlusPlusFreezeCaptureOptions
        do {
            options = try MacPlusPlusFreezeCaptureOptions.parse(
                Array(CommandLine.arguments.dropFirst()),
                homeDirectory: homeDirectory
            )
        } catch {
            FileHandle.standardError.write(Data("macpp-freeze-capture: \(error)\n".utf8))
            Foundation.exit(2)
        }

        if options.isDryRun {
            do {
                if options.json {
                    try writeJSON(options.plan(homeDirectory: homeDirectory))
                } else {
                    let outputs = [
                        options.copyToClipboard ? "clipboard" : nil,
                        options.saveTarget == .none ? nil : "PNG file",
                    ].compactMap { $0 }.joined(separator: " + ")
                    print("DRY-RUN: would freeze the \(options.displayTarget.rawValue) display before activation, then pick a region → \(outputs)")
                    print("No screen, clipboard, or file state changed. Add --apply to begin.")
                }
            } catch {
                FileHandle.standardError.write(Data("macpp-freeze-capture: \(error)\n".utf8))
                Foundation.exit(2)
            }
            return
        }

        do {
            // Do not move NSApplication creation above this await: the ordering
            // is the freeze guarantee that preserves transient source pixels.
            let frozen = try await freezeDisplay(options: options)
            let application = NSApplication.shared
            let controller = FreezePickerController(
                frozen: frozen,
                options: options,
                homeDirectory: homeDirectory
            )
            application.delegate = controller
            controller.start()
            application.run()

            guard let outcome = controller.outcome else {
                throw MacPlusPlusFreezeCaptureError.outputFailed("picker exited without a result")
            }
            switch outcome {
            case let .success(result):
                if options.json {
                    try writeJSON(result.json)
                } else {
                    var destinations: [String] = []
                    if result.copied { destinations.append("clipboard") }
                    if let path = result.savedURL?.path { destinations.append(path) }
                    print("Captured \(result.pixelWidth)×\(result.pixelHeight) → \(destinations.joined(separator: " + "))")
                }
            case let .failure(error as MacPlusPlusFreezeCaptureError) where error == .cancelled:
                if options.json {
                    try writeJSON(["schema_version": 1, "status": "cancelled"])
                }
                Foundation.exit(130)
            case let .failure(error):
                throw error
            }
        } catch {
            FileHandle.standardError.write(Data("macpp-freeze-capture: \(error)\n".utf8))
            Foundation.exit(2)
        }
    }
}
