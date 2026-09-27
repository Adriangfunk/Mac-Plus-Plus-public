import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

private struct ColorPickerOptions {
    var apply = false
    var hex: String?
}

private enum ColorPickerError: Error, CustomStringConvertible {
    case usage
    case captureUnavailable
    case invalidHex

    var description: String {
        switch self {
        case .usage: return "usage: macpp-color-picker [--apply] [--hex RRGGBB]"
        case .captureUnavailable: return "screen capture unavailable; grant Screen Recording to macpp-color-picker"
        case .invalidHex: return "colour must be exactly six hexadecimal digits"
        }
    }
}

private func parseOptions() throws -> ColorPickerOptions {
    var options = ColorPickerOptions()
    var arguments = Array(CommandLine.arguments.dropFirst())
    while !arguments.isEmpty {
        switch arguments.removeFirst() {
        case "--apply": options.apply = true
        case "--dry-run": options.apply = false
        case "--hex":
            guard let value = arguments.first else { throw ColorPickerError.usage }
            arguments.removeFirst()
            guard value.replacingOccurrences(of: "#", with: "").count == 6 else { throw ColorPickerError.invalidHex }
            options.hex = value
        default: throw ColorPickerError.usage
        }
    }
    return options
}

private func normalizedHex(_ value: String) throws -> String {
    let hex = value.trimmingCharacters(in: .whitespacesAndNewlines)
        .replacingOccurrences(of: "#", with: "")
        .uppercased()
    guard hex.count == 6, UInt64(hex, radix: 16) != nil else { throw ColorPickerError.invalidHex }
    return "#\(hex)"
}

private func emit(_ hex: String, applied: Bool) {
    let value: [String: Any] = ["schema_version": 1, "status": "picked", "hex": hex, "applied": applied]
    // macpp:silent-ok the machine-readable result is best-effort after the color was copied
    guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
    FileHandle.standardOutput.write(data)
    FileHandle.standardOutput.write(Data("\n".utf8))
}

@MainActor
private func applyPickedColor(_ hex: String, apply: Bool) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.setString(hex, forType: .string)
    guard apply else {
        emit(hex, applied: false)
        return
    }

    let defaults = UserDefaults(suiteName: "org.macplusplus.shell") ?? .standard
    let currentName = defaults.string(forKey: "shellPalette") ?? "midnight"
    let configured = ProcessInfo.processInfo.environment["MACPP_PALETTE_CONFIG_PATH"]
        .flatMap { $0.isEmpty ? nil : URL(fileURLWithPath: $0) }
    let root = ProcessInfo.processInfo.environment["MACPP_ROOT"]
        .map { URL(fileURLWithPath: $0, isDirectory: true) }
        ?? URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    let catalogCandidates = [
        configured,
        Bundle.main.resourceURL?.appendingPathComponent("palettes.json"),
        root.appendingPathComponent("config/palettes.json")
    ].compactMap { $0 }
    var colors = ["frame": "080D19", "panel": "02050B", "text": "DDE9FF"]
    if let catalogURL = catalogCandidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }),
       let data = try? Data(contentsOf: catalogURL),
       let document = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let presets = document["presets"] as? [String: [String: Any]],
       let preset = presets[currentName] ?? presets["midnight"] {
        for role in colors.keys {
            if let value = preset[role] as? String { colors[role] = value.uppercased() }
        }
    }
    defaults.set(colors["frame"], forKey: "shellCustom.frame")
    defaults.set(colors["panel"], forKey: "shellCustom.panel")
    defaults.set(colors["text"], forKey: "shellCustom.text")
    defaults.set(String(hex.dropFirst()), forKey: "shellCustom.accent")
    defaults.set("custom", forKey: "shellPalette")
    defaults.synchronize()
    emit(hex, applied: true)
}

@MainActor
private final class ColorPickerView: NSView {
    let image: CGImage
    var onPick: ((String) -> Void)?
    var onCancel: (() -> Void)?

    init(frame: CGRect, image: CGImage) {
        self.image = image
        super.init(frame: frame)
        wantsLayer = true
    }

    required init?(coder: NSCoder) { nil }
    override var isFlipped: Bool { true }
    override var acceptsFirstResponder: Bool { true }

    override func resetCursorRects() { addCursorRect(bounds, cursor: .crosshair) }

    override func draw(_ dirtyRect: NSRect) {
        NSImage(cgImage: image, size: bounds.size).draw(in: bounds, from: .zero, operation: .copy, fraction: 1)
        let attributes: [NSAttributedString.Key: Any] = [
            .font: NSFont.monospacedSystemFont(ofSize: 12, weight: .bold),
            .foregroundColor: NSColor.white,
            .backgroundColor: NSColor.black.withAlphaComponent(0.70),
        ]
        NSAttributedString(string: "  CLICK A PIXEL  ·  ESC TO CANCEL  ", attributes: attributes)
            .draw(at: CGPoint(x: 18, y: 18))
    }

    override func mouseDown(with event: NSEvent) {
        let point = convert(event.locationInWindow, from: nil)
        guard let hex = hex(at: point) else { NSSound.beep(); return }
        onPick?(hex)
    }

    override func keyDown(with event: NSEvent) {
        if event.keyCode == 53 { onCancel?() } else { super.keyDown(with: event) }
    }

    private func hex(at point: CGPoint) -> String? {
        guard bounds.width > 0, bounds.height > 0,
              let provider = image.dataProvider,
              let data = provider.data,
              let bytes = CFDataGetBytePtr(data) else { return nil }
        let x = min(image.width - 1, max(0, Int((point.x / bounds.width) * CGFloat(image.width))))
        let y = min(image.height - 1, max(0, Int((point.y / bounds.height) * CGFloat(image.height))))
        let bytesPerPixel = max(3, image.bitsPerPixel / 8)
        let offset = y * image.bytesPerRow + x * bytesPerPixel
        let littleEndian = (image.bitmapInfo.rawValue & CGBitmapInfo.byteOrder32Little.rawValue) != 0
        let r = littleEndian ? bytes[offset + 2] : bytes[offset]
        let g = littleEndian ? bytes[offset + 1] : bytes[offset + 1]
        let b = littleEndian ? bytes[offset] : bytes[offset + 2]
        return String(format: "#%02X%02X%02X", r, g, b)
    }
}

@MainActor
private final class ColorPickerController: NSObject, NSApplicationDelegate, NSWindowDelegate {
    let options: ColorPickerOptions
    var window: NSWindow?

    init(options: ColorPickerOptions) { self.options = options }

    func applicationDidFinishLaunching(_ notification: Notification) {
        if let hex = options.hex {
            do {
                applyPickedColor(try normalizedHex(hex), apply: options.apply)
                NSApp.terminate(nil)
            }
            catch { FileHandle.standardError.write(Data("macpp-color-picker: \(error)\n".utf8)); NSApp.terminate(nil) }
            return
        }
        Task { await beginCapture() }
    }

    private func beginCapture() async {
        guard #available(macOS 14.0, *) else {
            fail(ColorPickerError.captureUnavailable)
            return
        }
        let screen = NSScreen.screens.first(where: { NSMouseInRect(NSEvent.mouseLocation, $0.frame, false) }) ?? NSScreen.main
        guard let screen,
              let displayID = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else {
            fail(ColorPickerError.captureUnavailable); return
        }
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == displayID }) else { throw ColorPickerError.captureUnavailable }
            let configuration = SCStreamConfiguration()
            configuration.width = display.width
            configuration.height = display.height
            configuration.showsCursor = false
            configuration.queueDepth = 1
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
            let view = ColorPickerView(frame: screen.frame, image: image)
            view.onPick = { [weak self] hex in
                applyPickedColor(hex, apply: self?.options.apply == true)
                self?.window?.orderOut(nil)
                NSApp.terminate(nil)
            }
            view.onCancel = { NSApp.terminate(nil) }
            let panel = NSWindow(contentRect: screen.frame, styleMask: [.borderless], backing: .buffered, defer: false)
            panel.contentView = view
            panel.isOpaque = true
            panel.backgroundColor = .black
            panel.level = .screenSaver
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.ignoresMouseEvents = false
            panel.delegate = self
            window = panel
            panel.makeKeyAndOrderFront(nil)
            panel.makeFirstResponder(view)
        } catch {
            fail(error)
        }
    }

    private func fail(_ error: Error) {
        FileHandle.standardError.write(Data("macpp-color-picker: \(error)\n".utf8))
        NSApp.terminate(nil)
    }

    func windowWillClose(_ notification: Notification) { NSApp.terminate(nil) }
}

@main
@MainActor
private struct MacPlusPlusColorPickerMain {
    static func main() {
        do {
            let controller = ColorPickerController(options: try parseOptions())
            let app = NSApplication.shared
            app.setActivationPolicy(.accessory)
            app.delegate = controller
            app.run()
        } catch {
            FileHandle.standardError.write(Data("macpp-color-picker: \(error)\n".utf8))
            exit(2)
        }
    }
}
