import Foundation

/// A normalized focal point for the part of a wallpaper that should remain in
/// Mac++'s aspect-filled desktop frame. The source media stays untouched, so
/// the same editor works for stills and videos and every edit can be undone.
struct MacPlusPlusWallpaperCropSelection: Codable, Equatable, Sendable {
    static let targetAspect = 21.0 / 9.0

    var x: Double
    var y: Double

    init(x: Double = 0.5, y: Double = 0.5) {
        self.x = Self.clamp(x)
        self.y = Self.clamp(y)
    }

    private static func clamp(_ value: Double) -> Double {
        guard value.isFinite else { return 0.5 }
        return min(1, max(0, value))
    }
}

/// The normalized crop window used by both the editor and the wallpaper
/// renderer. `selection` is a focal point in source UV space, while the
/// actual crop origin is clamped by the amount of source media that fits in
/// the display frame. Keeping that distinction here prevents the UI from
/// treating a focal point like a pixel offset.
struct MacPlusPlusWallpaperCropGeometry: Equatable, Sendable {
    let sourceAspect: Double
    let viewportAspect: Double

    init(sourceAspect: Double, viewportAspect: Double) {
        self.sourceAspect = Self.sanitize(sourceAspect, fallback: 1)
        self.viewportAspect = Self.sanitize(
            viewportAspect,
            fallback: MacPlusPlusWallpaperCropSelection.targetAspect
        )
    }

    /// The portion of the normalized source width visible in the frame.
    var visibleSourceWidth: Double {
        min(1, viewportAspect / sourceAspect)
    }

    /// The portion of the normalized source height visible in the frame.
    var visibleSourceHeight: Double {
        min(1, sourceAspect / viewportAspect)
    }

    var sourceTravelX: Double { max(0, 1 - visibleSourceWidth) }
    var sourceTravelY: Double { max(0, 1 - visibleSourceHeight) }

    /// Returns the top-left of the visible source window in normalized UVs.
    /// This mirrors the Metal shader's `clamp` sampler behavior at the edges.
    func cropOrigin(for selection: MacPlusPlusWallpaperCropSelection) -> (x: Double, y: Double) {
        (
            clamp(selection.x - visibleSourceWidth * 0.5, upperBound: sourceTravelX),
            clamp(selection.y - visibleSourceHeight * 0.5, upperBound: sourceTravelY)
        )
    }

    private static func sanitize(_ value: Double, fallback: Double) -> Double {
        guard value.isFinite else { return fallback }
        return max(0.25, value)
    }

    private func clamp(_ value: Double, upperBound: Double) -> Double {
        min(upperBound, max(0, value))
    }
}

/// One small atomic sidecar per source avoids a shared catalog merge race when
/// Shell and the wallpaper engine are both running. The key is the standardized
/// source path, so bundled palette media and managed user files are both
/// editable without copying or re-encoding their pixels.
enum MacPlusPlusWallpaperFramingStore {
    private static let directory = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacPlusPlus/WallpaperFraming", isDirectory: true)

    private static func sidecarURL(for path: String) -> URL {
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        let encoded = Data(normalized.utf8)
            .base64EncodedString()
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "=", with: "")
        return directory.appendingPathComponent(encoded).appendingPathExtension("json")
    }

    static func load(for path: String) -> MacPlusPlusWallpaperCropSelection {
        let data: Data
        do {
            data = try Data(contentsOf: sidecarURL(for: path))
        } catch {
            let fallback = MacPlusPlusWallpaperCropSelection()
            return fallback
        }
        let decoded: MacPlusPlusWallpaperCropSelection
        do {
            decoded = try JSONDecoder().decode(
                MacPlusPlusWallpaperCropSelection.self,
                from: data
            )
        } catch {
            let fallback = MacPlusPlusWallpaperCropSelection()
            return fallback
        }
        return MacPlusPlusWallpaperCropSelection(x: decoded.x, y: decoded.y)
    }

    static func save(
        _ selection: MacPlusPlusWallpaperCropSelection,
        for path: String
    ) throws {
        let normalized = MacPlusPlusWallpaperCropSelection(x: selection.x, y: selection.y)
        let sidecar = sidecarURL(for: path)
        if normalized == MacPlusPlusWallpaperCropSelection() {
            guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
            try FileManager.default.removeItem(at: sidecar)
            return
        }
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
        try JSONEncoder().encode(normalized).write(to: sidecar, options: .atomic)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o600],
            ofItemAtPath: sidecar.path
        )
    }

    static func reset(for path: String) throws {
        let sidecar = sidecarURL(for: path)
        guard FileManager.default.fileExists(atPath: sidecar.path) else { return }
        try FileManager.default.removeItem(at: sidecar)
    }
}
