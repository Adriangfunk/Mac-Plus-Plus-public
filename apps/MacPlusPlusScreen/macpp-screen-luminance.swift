import AppKit
import CoreGraphics
import Foundation
@preconcurrency import ScreenCaptureKit

@main
@MainActor
private struct MacPlusPlusScreenLuminanceMain {
    static func main() async {
        do {
            guard #available(macOS 14.0, *) else { throw NSError(domain: "Mac++", code: 0) }
            let screen = NSScreen.main ?? NSScreen.screens.first
            guard let screen,
                  let id = (screen.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? NSNumber)?.uint32Value else { throw NSError(domain: "Mac++", code: 1) }
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            guard let display = content.displays.first(where: { $0.displayID == id }) else { throw NSError(domain: "Mac++", code: 2) }
            let configuration = SCStreamConfiguration()
            configuration.width = min(96, display.width)
            configuration.height = min(96, display.height)
            configuration.showsCursor = false
            configuration.queueDepth = 1
            let image = try await SCScreenshotManager.captureImage(
                contentFilter: SCContentFilter(display: display, excludingWindows: []),
                configuration: configuration
            )
            let colorSpace = CGColorSpaceCreateDeviceRGB()
            var pixels = [UInt8](repeating: 0, count: 4)
            guard let context = CGContext(
                data: &pixels,
                width: 1,
                height: 1,
                bitsPerComponent: 8,
                bytesPerRow: 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else { throw NSError(domain: "Mac++", code: 3) }
            context.interpolationQuality = .low
            context.draw(image, in: CGRect(x: 0, y: 0, width: 1, height: 1))
            let r = Double(pixels[0]) / 255
            let g = Double(pixels[1]) / 255
            let b = Double(pixels[2]) / 255
            let value = 0.2126 * r + 0.7152 * g + 0.0722 * b
            let output = ["schema_version": 1, "luminance": value] as [String: Any]
            let data = try JSONSerialization.data(withJSONObject: output, options: [.sortedKeys])
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        } catch {
            FileHandle.standardError.write(Data("macpp-screen-luminance: \(error)\n".utf8))
            exit(2)
        }
    }
}
