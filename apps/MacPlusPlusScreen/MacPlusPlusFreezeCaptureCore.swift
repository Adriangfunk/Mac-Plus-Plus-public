import CoreGraphics
import Foundation

enum MacPlusPlusFreezeCaptureError: Error, CustomStringConvertible, Equatable {
    case cancelled
    case invalidArguments(String)
    case captureUnavailable
    case emptySelection
    case imageEncodingFailed
    case outputFailed(String)

    var description: String {
        switch self {
        case .cancelled:
            return "capture cancelled"
        case let .invalidArguments(message):
            return message
        case .captureUnavailable:
            return "screen capture unavailable; grant Screen Recording permission to macpp-freeze-capture"
        case .emptySelection:
            return "drag a region at least 2 points wide and high"
        case .imageEncodingFailed:
            return "could not encode the selected region as PNG"
        case let .outputFailed(message):
            return message
        }
    }
}

enum MacPlusPlusFreezeDisplayTarget: String, Equatable {
    case pointer
    case main
}

enum MacPlusPlusFreezeSaveTarget: Equatable {
    case none
    case automatic
    case explicit(URL)
}

struct MacPlusPlusFreezeCaptureOptions: Equatable {
    static let usage = """
    usage: macpp-freeze-capture [--dry-run | --apply] [--copy]
                               [--save-default | --save ABSOLUTE.png [--replace]]
                               [--display pointer|main] [--cursor] [--json]

    The command is a read-only plan unless --apply is present. With no output
    flag, the selected PNG is copied to the clipboard. --save-default writes
    to Pictures/Screenshots/YYYY-MM-DD without replacing an existing capture.
    """

    var apply = false
    var copyToClipboard = false
    var saveTarget: MacPlusPlusFreezeSaveTarget = .none
    var replaceExisting = false
    var displayTarget: MacPlusPlusFreezeDisplayTarget = .pointer
    var showsCursor = false
    var json = false

    var isDryRun: Bool { !apply }

    static func parse(_ arguments: [String], homeDirectory: URL) throws -> MacPlusPlusFreezeCaptureOptions {
        var result = MacPlusPlusFreezeCaptureOptions()
        var sawDryRun = false
        var sawOutput = false
        var index = 0

        while index < arguments.count {
            let argument = arguments[index]
            switch argument {
            case "--apply":
                guard !sawDryRun else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--apply and --dry-run are mutually exclusive")
                }
                result.apply = true
            case "--dry-run":
                guard !result.apply else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--apply and --dry-run are mutually exclusive")
                }
                sawDryRun = true
            case "--copy":
                result.copyToClipboard = true
                sawOutput = true
            case "--save-default":
                guard result.saveTarget == .none else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("choose only one of --save-default and --save")
                }
                result.saveTarget = .automatic
                sawOutput = true
            case "--save":
                index += 1
                guard index < arguments.count else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--save requires an absolute .png path")
                }
                guard result.saveTarget == .none else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("choose only one of --save-default and --save")
                }
                let expanded = (arguments[index] as NSString).expandingTildeInPath
                guard expanded.hasPrefix("/") else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--save requires an absolute .png path")
                }
                let url = URL(fileURLWithPath: expanded, isDirectory: false).standardizedFileURL
                guard url.pathExtension.lowercased() == "png" else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--save requires an absolute .png path")
                }
                result.saveTarget = .explicit(url)
                sawOutput = true
            case "--replace":
                result.replaceExisting = true
            case "--display":
                index += 1
                guard index < arguments.count,
                      let target = MacPlusPlusFreezeDisplayTarget(rawValue: arguments[index]) else {
                    throw MacPlusPlusFreezeCaptureError.invalidArguments("--display must be pointer or main")
                }
                result.displayTarget = target
            case "--no-cursor":
                result.showsCursor = false
            case "--cursor":
                result.showsCursor = true
            case "--json":
                result.json = true
            case "--help", "-h":
                throw MacPlusPlusFreezeCaptureError.invalidArguments(usage)
            default:
                throw MacPlusPlusFreezeCaptureError.invalidArguments("unknown argument: \(argument)\n\n\(usage)")
            }
            index += 1
        }

        if !sawOutput {
            result.copyToClipboard = true
        }
        if result.replaceExisting {
            guard case .explicit = result.saveTarget else {
                throw MacPlusPlusFreezeCaptureError.invalidArguments("--replace is valid only with --save")
            }
        }

        // Resolve the home directory during parsing so plans and applied runs
        // use the same trusted root. The value is consulted by automaticURL.
        guard homeDirectory.isFileURL, homeDirectory.path.hasPrefix("/") else {
            throw MacPlusPlusFreezeCaptureError.invalidArguments("the home directory is not an absolute file URL")
        }
        return result
    }

    func plan(homeDirectory: URL) -> [String: Any] {
        let saveDescription: Any
        switch saveTarget {
        case .none:
            saveDescription = NSNull()
        case .automatic:
            saveDescription = homeDirectory
                .appendingPathComponent("Pictures/Screenshots/YYYY-MM-DD/MacPlusPlus-Freeze-YYYY-MM-DD-HHMMSS.png")
                .path
        case let .explicit(url):
            saveDescription = url.path
        }
        return [
            "schema_version": 1,
            "action": apply ? "apply" : "dry-run",
            "capture_before_activation": true,
            "display": displayTarget.rawValue,
            "shows_cursor": showsCursor,
            "copy": copyToClipboard,
            "save": saveDescription,
            "replace": replaceExisting,
        ]
    }
}

struct MacPlusPlusFreezeCropPlan: Equatable {
    let pixelRect: CGRect
    let pixelWidth: Int
    let pixelHeight: Int

    static func make(selection: CGRect, viewSize: CGSize, imageSize: CGSize) throws -> MacPlusPlusFreezeCropPlan {
        guard viewSize.width > 0, viewSize.height > 0,
              imageSize.width > 0, imageSize.height > 0 else {
            throw MacPlusPlusFreezeCaptureError.emptySelection
        }

        let normalized = selection.standardized.intersection(
            CGRect(origin: .zero, size: viewSize)
        )
        guard !normalized.isNull, normalized.width >= 2, normalized.height >= 2 else {
            throw MacPlusPlusFreezeCaptureError.emptySelection
        }

        let scaleX = imageSize.width / viewSize.width
        let scaleY = imageSize.height / viewSize.height
        let minX = max(0, floor(normalized.minX * scaleX))
        let minY = max(0, floor(normalized.minY * scaleY))
        let maxX = min(imageSize.width, ceil(normalized.maxX * scaleX))
        let maxY = min(imageSize.height, ceil(normalized.maxY * scaleY))
        let width = Int(maxX - minX)
        let height = Int(maxY - minY)
        guard width > 0, height > 0 else {
            throw MacPlusPlusFreezeCaptureError.emptySelection
        }
        return MacPlusPlusFreezeCropPlan(
            pixelRect: CGRect(x: minX, y: minY, width: CGFloat(width), height: CGFloat(height)),
            pixelWidth: width,
            pixelHeight: height
        )
    }
}

func macppFreezeAutomaticURL(homeDirectory: URL, date: Date, fileExists: (String) -> Bool) -> URL {
    let formatter = DateFormatter()
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = .current
    formatter.dateFormat = "yyyy-MM-dd"
    let day = formatter.string(from: date)
    formatter.dateFormat = "yyyy-MM-dd-HHmmss"
    let stamp = formatter.string(from: date)

    let directory = homeDirectory
        .appendingPathComponent("Pictures", isDirectory: true)
        .appendingPathComponent("Screenshots", isDirectory: true)
        .appendingPathComponent(day, isDirectory: true)
    let base = "MacPlusPlus-Freeze-\(stamp)"
    var candidate = directory.appendingPathComponent(base).appendingPathExtension("png")
    var suffix = 2
    while fileExists(candidate.path) {
        candidate = directory.appendingPathComponent("\(base)-\(suffix)").appendingPathExtension("png")
        suffix += 1
    }
    return candidate
}

private func macppFreezeValidateSaveDestination(
    _ url: URL,
    replacing: Bool,
    fileManager: FileManager
) throws {
    var isDirectory: ObjCBool = false
    guard fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) else { return }
    if isDirectory.boolValue {
        throw MacPlusPlusFreezeCaptureError.outputFailed("save destination is a directory: \(url.path)")
    }
    let values: URLResourceValues
    do {
        values = try url.resourceValues(forKeys: [.isSymbolicLinkKey])
    } catch {
        throw MacPlusPlusFreezeCaptureError.outputFailed(
            "could not validate save destination: \(url.path)"
        )
    }
    if values.isSymbolicLink == true {
        throw MacPlusPlusFreezeCaptureError.outputFailed("refusing to replace symbolic link: \(url.path)")
    }
    if !replacing {
        throw MacPlusPlusFreezeCaptureError.outputFailed("capture already exists; choose another path or add --replace: \(url.path)")
    }
}

@discardableResult
func macppFreezeWritePNG(
    _ data: Data,
    target: MacPlusPlusFreezeSaveTarget,
    replacing: Bool,
    homeDirectory: URL,
    date: Date = Date(),
    fileManager: FileManager = .default
) throws -> URL? {
    let destination: URL
    let overwrite: Bool
    switch target {
    case .none:
        return nil
    case .automatic:
        destination = macppFreezeAutomaticURL(
            homeDirectory: homeDirectory,
            date: date,
            fileExists: fileManager.fileExists(atPath:)
        )
        overwrite = false
    case let .explicit(url):
        try macppFreezeValidateSaveDestination(url, replacing: replacing, fileManager: fileManager)
        destination = url
        overwrite = replacing
    }

    do {
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if overwrite {
            try data.write(to: destination, options: .atomic)
        } else {
            // Foundation traps when .atomic and .withoutOverwriting are used
            // together. Publish a fully written sibling through an atomic
            // hard link instead: link(2) fails if the destination exists and
            // readers can never observe a partial PNG.
            let temporary = destination.deletingLastPathComponent()
                .appendingPathComponent(".\(destination.lastPathComponent).macpp-\(UUID().uuidString).tmp")
            // macpp:silent-ok temporary cleanup is idempotent after link publication
            defer { try? fileManager.removeItem(at: temporary) }
            try data.write(to: temporary, options: .atomic)
            try fileManager.linkItem(at: temporary, to: destination)
        }
    } catch let error as MacPlusPlusFreezeCaptureError {
        throw error
    } catch {
        throw MacPlusPlusFreezeCaptureError.outputFailed(
            "could not save capture to \(destination.path): \(error.localizedDescription)"
        )
    }
    return destination
}
