import SwiftUI
import AppKit
import Carbon
import Darwin

#if MACPP_CAELESTIA_SHELL
private let launcherWidth: CGFloat = CaelestiaParityTokens.Sizes.launcherItemWidth
private let nexusWidth: CGFloat = CaelestiaParityTokens.Sizes.launcherNexusWidth
// The wallpaper picker shares Nexus's broad horizontal envelope, but keeps
// its own shallow height so it still reads as a flattened media strip rather
// than a second control-centre page.
private let wallpaperWidth: CGFloat = nexusWidth
private let nexusHeight: CGFloat = CaelestiaParityTokens.Nexus.surfaceHeight
#elseif MACPPCAST_EMBEDDED
// The original Mac++ Shell embeds this shared Cast source without the
// parity-only token file. Keep its established geometry independent while
// allowing the isolated Caelestia target to opt into the 960pt Nexus canvas.
private let launcherWidth: CGFloat = 680
private let nexusWidth: CGFloat = launcherWidth
private let wallpaperWidth: CGFloat = nexusWidth
private let nexusHeight: CGFloat = 460
#else
private let launcherWidth: CGFloat = 680
private let nexusWidth: CGFloat = launcherWidth
private let wallpaperWidth: CGFloat = nexusWidth
private let nexusHeight: CGFloat = 460
#endif
// Resolve the checkout once and use it for every Search-owned helper. The
// previous literals assumed a particular Documents path, which meant a
// relocated checkout could still open Search while every mode/action command
// quietly pointed at a dead path.
private let macppRoot: String = {
    let configured = ProcessInfo.processInfo.environment["MACPP_ROOT"]
        .flatMap { $0.isEmpty ? nil : $0 }
    let bundledRoot = (0..<4).reduce(Bundle.main.bundleURL) { url, _ in
        url.deletingLastPathComponent()
    }.path
    let candidates: [String] = [configured, bundledRoot, FileManager.default.currentDirectoryPath].compactMap { $0 }
    return candidates.first(where: {
        FileManager.default.fileExists(atPath: $0 + "/config/public-shell.json")
    }) ?? bundledRoot
}()

private func macppPath(_ relativePath: String) -> String {
    URL(fileURLWithPath: macppRoot, isDirectory: true)
        .appendingPathComponent(relativePath)
        .path
}


/// Embedded Search actions that must be performed by the Shell's live model.
/// Keeping these bounded prevents launcher text from becoming an arbitrary
/// system-control channel while still letting Search reach the same
/// state-aware helpers as Nexus.
enum MacPlusPlusLauncherQuickAction: String, CaseIterable, Sendable {
    case toggleMicrophone
    case toggleOutputMute
    case toggleFocus
    case toggleWiFi
    case toggleVPN
    case toggleDesktopLayer
    case toggleCenterClock
    case toggleVisualizer
    case toggleEQ
    case toggleShellBorder
    case toggleMenuMask
    case toggleAppDock
    case focusWindow
    case pullWindow
    case lockScreen
}

private extension MacPlusPlusLauncherQuickAction {
    init?(launcherIdentifier: String) {
        switch launcherIdentifier {
        case "toggle-microphone": self = .toggleMicrophone
        case "toggle-output-mute": self = .toggleOutputMute
        case "toggle-focus": self = .toggleFocus
        case "toggle-wifi": self = .toggleWiFi
        case "toggle-vpn": self = .toggleVPN
        case "toggle-desktop-layer": self = .toggleDesktopLayer
        case "toggle-center-clock": self = .toggleCenterClock
        case "toggle-visualizer": self = .toggleVisualizer
        case "toggle-eq": self = .toggleEQ
        case "toggle-shell-border": self = .toggleShellBorder
        case "toggle-menu-mask": self = .toggleMenuMask
        case "toggle-app-dock": self = .toggleAppDock
        default: return nil
        }
    }
}

#if MACPPCAST_EMBEDDED
// The shell owns the physical 7pt bottom rim.  Embedded Search begins at
// its inner edge, so its surface unfolds outward without occupying the rim.
private let shellEdgeDepth: CGFloat = 0
#else
private let shellEdgeDepth: CGFloat = 7
#endif

private enum CastMotion {
    case hover, press, selection, surface, dismiss, resize, content, results

    var duration: TimeInterval {
#if MACPPCAST_EMBEDDED
        switch self {
        case .hover: ShellMotion.hover.duration
        case .press: ShellMotion.press.duration
        case .surface: ShellMotion.topPopout.duration
        case .dismiss: ShellMotion.topDismiss.duration
        case .resize: ShellMotion.launcherResize.duration
        case .selection: ShellMotion.panelSwitch.duration
        case .content: ShellMotion.contentIn.duration
        // Result geometry is re-triggered while the user types. Keep it on
        // the same monotonic token as the live launcher resize so a new
        // search never restarts an overshoot from the previous frame.
        case .results: ShellMotion.launcherResize.duration
        }
#else
        switch self {
        case .hover: 0.10
        case .press: 0.22
        case .selection: 0.26
        case .surface: 0.40
        case .dismiss: 0.27
        case .resize: 0.30
        case .content: 0.20
        case .results: 0.24
        }
#endif
    }

    var animation: Animation {
#if MACPPCAST_EMBEDDED
        switch self {
        case .hover: ShellMotion.hover.animation
        case .press: ShellMotion.press.animation
        case .surface: ShellMotion.topPopout.animation
        case .dismiss: ShellMotion.topDismiss.animation
        case .resize: ShellMotion.launcherResize.animation
        case .selection: ShellMotion.panelSwitch.animation
        case .content: ShellMotion.contentIn.animation
        // Search results can change several times per second. The
        // retriggerable launcher-resize curve is monotonic, so rows glide to
        // their new slots instead of bouncing from every interrupted diff.
        case .results: ShellMotion.launcherResize.animation
        }
#else
        switch self {
        case .hover: .easeOut(duration: duration)
        case .press: .interactiveSpring(response: 0.22, dampingFraction: 0.84)
        case .selection: .interactiveSpring(response: 0.28, dampingFraction: 0.86)
        case .surface: .interactiveSpring(response: 0.36, dampingFraction: 0.82)
        case .dismiss: .smooth(duration: duration)
        // A spring is pleasant for a one-shot opener, but it makes live
        // result geometry overshoot, get interrupted, and jump again before
        // it settles. Keep height and result movement bounded while typing.
        case .resize: .easeOut(duration: duration)
        case .content: .easeOut(duration: duration)
        case .results: .easeOut(duration: duration)
        }
#endif
    }

    var appKitTiming: CAMediaTimingFunction {
#if MACPPCAST_EMBEDDED
        switch self {
        case .hover: ShellMotion.hover.appKitTiming
        case .press: ShellMotion.press.appKitTiming
        case .surface: ShellMotion.topPopout.appKitTiming
        case .dismiss: ShellMotion.topDismiss.appKitTiming
        case .resize: ShellMotion.launcherResize.appKitTiming
        case .selection: ShellMotion.panelSwitch.appKitTiming
        case .content: ShellMotion.contentIn.appKitTiming
        case .results: ShellMotion.launcherResize.appKitTiming
        }
#else
        switch self {
        case .dismiss: CAMediaTimingFunction(controlPoints: 0.55, 0.0, 0.8, 0.22)
        default: CAMediaTimingFunction(controlPoints: 0.16, 1.0, 0.3, 1.0)
        }
#endif
    }

    static let stagger: TimeInterval = 0.035
}

// MacPlusPlusCast shares the shell's rounded system face, but its launcher is denser
// than a full Nexus page. These few values keep the query field, result rows,
// and secondary copy on a deliberate hierarchy instead of accumulating one-
// off sizes as commands are added.
// `CastMotion` above already delegates every case to `ShellMotion` when
// embedded. These two did not, so a Search result subtitle rendered at 11pt
// beside shell chrome at 10pt, and a result row at radius 8 sat next to a card
// at radius 12 -- one surface, one motion curve, three different scales.
//
// Both now delegate the same way. The standalone values are unchanged: outside
// the shell there is no chrome to agree with, and Search is then the only thing
// on screen.
//
// Every embedded mapping is flat or one step *down*, never up. Search is
// deliberately denser than a Nexus page and its launcher is a fixed 680pt
// surface with a 22pt shoulder each side, so a naive nearest-step map would
// have pushed `resultTitle` from 13.5 up to 15 and overflowed result rows long
// before it looked wrong anywhere else.
private enum CastTypography {
    // 17 -> 17. Exact: the query field and a Nexus section title are the two
    // places the shell speaks at full size, and they should match.
    static var query: CGFloat {
#if MACPPCAST_EMBEDDED
        ShellTypography.section
#else
        17
#endif
    }
    // 13.5 -> 13. Down, not up: this is the line that sets result row height.
    static var resultTitle: CGFloat {
#if MACPPCAST_EMBEDDED
        ShellTypography.title
#else
        13.5
#endif
    }
    // 10 -> 10 exact.
    static var chip: CGFloat {
#if MACPPCAST_EMBEDDED
        ShellTypography.label
#else
        10
#endif
    }
    // 14 -> 13. A symbol, so it maps onto the icon scale rather than the type
    // scale; down for the same row-height reason as `resultTitle`.
    static var icon: CGFloat {
#if MACPPCAST_EMBEDDED
        ShellIcon.medium
#else
        14
#endif
    }
}

private enum CastRounding {
    // 10 -> 12. Corner radius does not change a view's bounds, so unlike the
    // type mapping this one can round toward the shell's own card radius
    // without any risk to the launcher's fixed width.
    static var control: CGFloat {
#if MACPPCAST_EMBEDDED
        Rounding.normal
#else
        10
#endif
    }
    // 8 -> 8 and 22 -> 22. Both already agreed with the shell's scale; routing
    // them through it keeps them agreeing if either side is retuned.
    static var row: CGFloat {
#if MACPPCAST_EMBEDDED
        Rounding.small
#else
        8
#endif
    }
    static var surface: CGFloat {
#if MACPPCAST_EMBEDDED
        Rounding.shell
#else
        22
#endif
    }
}

// One or two compositor turns are enough for SwiftUI to lay out the hidden
// destination before AppKit resizes the host. A fixed 16.7 ms wait was tuned
// for 60 Hz and added four unnecessary frames on a 240 Hz display. Keep an
// 8.3 ms floor so the background still receives a real commit even when the
// display reports an unusually high refresh rate.
private func displayCommitDelayNanoseconds() -> UInt64 {
    let framesPerSecond = max(60, NSScreen.main?.maximumFramesPerSecond ?? 60)
    let oneFrame = 1_000_000_000.0 / Double(framesPerSecond)
    return UInt64(max(8_333_333.0, oneFrame).rounded())
}

#if MACPPCAST_EMBEDDED
typealias LauncherMotionState = SurfaceMotionState
#else
final class LauncherMotionState: ObservableObject {
    let id = UUID()
    @Published var presented = false
    @Published var progress: CGFloat = 0
}
#endif

private struct CastButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .background(
                Palette.pale.opacity(configuration.isPressed ? 0.10 : 0),
                in: RoundedRectangle(cornerRadius: CastRounding.control, style: .continuous)
            )
            .animation(CastMotion.content.animation, value: configuration.isPressed)
    }
}

#if !MACPPCAST_EMBEDDED
private struct StandalonePaletteValues {
    let frame: Color
    let panel: Color
    let text: Color
    let accent: Color

    var seam: Color {
        let frameColor = NSColor(frame).usingColorSpace(.sRGB) ?? .black
        let accentColor = NSColor(accent).usingColorSpace(.sRGB) ?? .white
        let amount: CGFloat = 0.28
        return Color(nsColor: NSColor(
            srgbRed: frameColor.redComponent * (1 - amount) + accentColor.redComponent * amount,
            green: frameColor.greenComponent * (1 - amount) + accentColor.greenComponent * amount,
            blue: frameColor.blueComponent * (1 - amount) + accentColor.blueComponent * amount,
            alpha: 1
        ))
    }
}

/// Standalone Search is used after the Work shell is intentionally stopped.
/// Keep its surface on the same palette contract as the shell instead of
/// falling back to a second fixed blue theme. Game and Performance use the
/// configured palette for each mode.
private enum StandalonePaletteStore {
    private static var nonworkMode: String?

    static func setNonworkMode(_ value: String?) {
        let normalized = value?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        nonworkMode = (normalized == "game" || normalized == "performance") ? normalized : nil
    }

    private static func color(_ hex: String, fallback: Color) -> Color {
        let raw = hex.trimmingCharacters(in: CharacterSet.alphanumerics.inverted)
        guard raw.count == 6, let value = UInt64(raw, radix: 16) else { return fallback }
        return Color(
            red: Double((value >> 16) & 0xff) / 255,
            green: Double((value >> 8) & 0xff) / 255,
            blue: Double(value & 0xff) / 255
        )
    }

    private static func values(frame: String, panel: String, text: String, accent: String) -> StandalonePaletteValues {
        StandalonePaletteValues(
            frame: color(frame, fallback: Color(red: 0.03, green: 0.05, blue: 0.10)),
            panel: color(panel, fallback: Color(red: 0.01, green: 0.02, blue: 0.04)),
            text: color(text, fallback: Color(red: 0.87, green: 0.91, blue: 1.0)),
            accent: color(accent, fallback: Color(red: 0.52, green: 0.72, blue: 1.0))
        )
    }

    static var current: StandalonePaletteValues {
        if nonworkMode != nil, let game = MacPlusPlusPaletteCatalog.preset(named: "game") {
            return values(frame: game.frame, panel: game.panel, text: game.text, accent: game.accent)
        }

        // MacPlusPlusCast is a separate app bundle, so its standard defaults domain
        // is not the shell's. Read the shared shell domain explicitly, with
        // the local domain as a safe fallback for older installs.
        let defaults = UserDefaults(suiteName: "org.macplusplus.shell") ?? .standard
        let requested = defaults.string(forKey: "shellPalette") ?? MacPlusPlusPaletteCatalog.defaultName
        if requested == "custom" {
            let fallback = MacPlusPlusPaletteCatalog.defaultPreset
            return values(
                frame: defaults.string(forKey: "shellCustom.frame") ?? fallback.frame,
                panel: defaults.string(forKey: "shellCustom.panel") ?? fallback.panel,
                text: defaults.string(forKey: "shellCustom.text") ?? fallback.text,
                accent: defaults.string(forKey: "shellCustom.accent") ?? fallback.accent
            )
        }
        let preset = MacPlusPlusPaletteCatalog.preset(named: requested) ?? MacPlusPlusPaletteCatalog.defaultPreset
        return values(frame: preset.frame, panel: preset.panel, text: preset.text, accent: preset.accent)
    }
}
#endif

enum Palette {
    static var cyan: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellAccentColor()
#else
        StandalonePaletteStore.current.accent
#endif
    }
    static var pale: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellTextColor()
#else
        StandalonePaletteStore.current.text
#endif
    }
    static var ink: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellPanelColor()
#else
        StandalonePaletteStore.current.panel
#endif
    }
    static var green: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellAccentColor()
#else
        StandalonePaletteStore.current.accent
#endif
    }
    static var muted: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellMutedTextColor()
#else
        StandalonePaletteStore.current.text.opacity(0.72)
#endif
    }
    static var frame: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellFrameColor()
#else
        StandalonePaletteStore.current.frame
#endif
    }
    // Exact opaque pixel colour used by Mac++ Shell's physical frame contour.
    // This must not be translucent: the content underneath each window is
    // different and would change the resulting seam colour.
    static var seam: Color {
#if MACPPCAST_EMBEDDED
        embeddedShellSeamColor()
#else
        StandalonePaletteStore.current.seam
#endif
    }
    static var seamWidth: CGFloat {
#if MACPPCAST_EMBEDDED
        embeddedShellSeamWidth()
#else
        1
#endif
    }
}

// The launcher uses the shell's canonical top attachment path reflected over
// the horizontal axis.  This keeps the shoulders, tangents and corner radii
// identical to every other shell extrusion instead of merely approximating it.
private func canonicalAttachedPath(
    in rect: CGRect,
    depth: CGFloat,
    shoulder: CGFloat,
    bodyRadius: CGFloat,
    outlineOnly: Bool
) -> Path {
    guard rect.width > 0, rect.height > 0 else { return Path() }

    // Keep this path on the same measurement contract as the shell's
    // canonicalTopMorphPath.  The old helper derived its radius from the
    // temporary height and forced a four-point minimum.  During a reveal that
    // made the first few samples a little square, then introduced the curve
    // abruptly once the wrapper was tall enough to satisfy the clamp.
    let shoulderLimit = max(0, (rect.width - 2) / 4)
    let s = min(max(0, shoulder), shoulderLimit)
    let d = min(max(0, depth), max(0, rect.height - 0.75))
    let bodyHeight = max(0, rect.height - d)
    let shoulderY = min(s, bodyHeight / 2)
    let b = min(max(0, bodyRadius), max(0, (rect.width - 2 * s) / 2))
    let bodyY = min(b, bodyHeight / 2)
    var path = Path()
    if outlineOnly {
        path.move(to: CGPoint(x: rect.maxX, y: d))
    } else {
        path.move(to: CGPoint(x: 0, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: 0))
        path.addLine(to: CGPoint(x: rect.maxX, y: d))
    }
    guard bodyHeight > 0.000_1 else {
        if !outlineOnly { path.closeSubpath() }
        return path
    }
    path.addQuadCurve(
        to: CGPoint(x: rect.maxX - s, y: d + shoulderY),
        control: CGPoint(x: rect.maxX - s, y: d)
    )
    path.addLine(to: CGPoint(x: rect.maxX - s, y: rect.maxY - bodyY))
    path.addQuadCurve(
        to: CGPoint(x: rect.maxX - s - b, y: rect.maxY),
        control: CGPoint(x: rect.maxX - s, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: s + b, y: rect.maxY))
    path.addQuadCurve(
        to: CGPoint(x: s, y: rect.maxY - bodyY),
        control: CGPoint(x: s, y: rect.maxY)
    )
    path.addLine(to: CGPoint(x: s, y: d + shoulderY))
    path.addQuadCurve(to: CGPoint(x: 0, y: d), control: CGPoint(x: s, y: d))
    if !outlineOnly { path.closeSubpath() }
    return path
}

private func bottomMorphRevealRect(
    in rect: CGRect,
    progress: CGFloat,
    contracting: Bool = false
) -> CGRect {
    let p = min(1, max(0, progress))
    let seedWidth = min(rect.width, 120)
    // The seed is useful on reveal because it establishes the attached
    // shoulder immediately. On dismissal it must not survive as a narrow
    // terminal cap: that cap is what rasterized as the isolated blue dot
    // below Nexus after the shell rim had already returned.
    let width = contracting
        ? rect.width * p
        : seedWidth + (rect.width - seedWidth) * p
    let height = rect.height * p
    guard width > 0.000_1, height > 0.000_1 else { return .zero }
    return CGRect(
        x: rect.midX - width / 2,
        y: rect.maxY - height,
        width: width,
        height: height
    )
}

private func bottomMorphPath(
    in rect: CGRect,
    progress: CGFloat,
    outlineOnly: Bool,
    topRadius: CGFloat,
    shoulder: CGFloat,
    contracting: Bool = false
) -> Path {
    let current = bottomMorphRevealRect(
        in: rect,
        progress: progress,
        contracting: contracting
    )
    guard current.width > 0.000_1, current.height > 0.000_1 else { return Path() }
    let local = CGRect(origin: .zero, size: current.size)
    let path = canonicalAttachedPath(
        in: local,
        depth: shellEdgeDepth,
        shoulder: shoulder,
        bodyRadius: topRadius,
        outlineOnly: outlineOnly
    ).applying(
        CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: current.height)
    )
    return path.applying(
        CGAffineTransform(translationX: current.minX, y: current.minY)
    )
}

private struct BottomMorphShape: Shape {
    var topRadius: CGFloat = 20
    var shoulder: CGFloat = 22
    var progress: CGFloat = 1
    var contracting = false
    func path(in rect: CGRect) -> Path {
        bottomMorphPath(
            in: rect,
            progress: progress,
            outlineOnly: false,
            topRadius: topRadius,
            shoulder: shoulder,
            contracting: contracting
        )
    }
}

private struct BottomMorphBorder: Shape {
    var topRadius: CGFloat = 20
    var shoulder: CGFloat = 22
    var progress: CGFloat = 1
    var contracting = false
    func path(in rect: CGRect) -> Path {
        bottomMorphPath(
            in: rect,
            progress: progress,
            outlineOnly: true,
            topRadius: topRadius,
            shoulder: shoulder,
            contracting: contracting
        )
    }
}

#if MACPP_CAELESTIA_SHELL
/// The parity launcher is the shell's `.bottom` LivingSurface. Search and
/// Nexus must therefore use the same contour contract as the other popouts:
/// one native clip, a 120pt reveal seed, the 20pt smoothing shoulder, and the
/// 25pt shell radius. The older launcher shape remains the fallback for the
/// wallpaper and desktop surfaces; keeping that branch intact is deliberate.
private struct LauncherSurfaceContourShape: Shape {
    let useSearchNexusContour: Bool
    var progress: CGFloat = 1
    var outlineOnly = false
    var contracting = false

    var animatableData: CGFloat {
        get { progress }
        set { progress = newValue }
    }

    func path(in rect: CGRect) -> Path {
        if useSearchNexusContour {
            // This is the local copy of ShellSurfaceMorphShape(.bottom)'s
            // LivingSurface path. It intentionally uses the parity shell
            // tokens rather than the launcher's 22/20 content constants.
            return bottomMorphPath(
                in: rect,
                progress: progress,
                outlineOnly: outlineOnly,
                topRadius: CaelestiaParityTokens.Border.rounding,
                shoulder: CaelestiaParityTokens.Border.smoothing,
                contracting: contracting
            )
        }

        // Do not change the existing wallpaper/desktop contour geometry.
        return bottomMorphPath(
            in: rect,
            progress: progress,
            outlineOnly: outlineOnly,
            topRadius: 20,
            shoulder: 22,
            contracting: contracting
        )
    }
}

/// LivingSurface clips its content directly. Search/Nexus follows that same
/// rule; the legacy two-point bottom paint and raster mask stay in place for
/// the other launcher-owned structures only.
private struct LauncherSearchNexusRevealModifier: ViewModifier {
    let useNativeContour: Bool
    let progress: CGFloat
    let contracting: Bool

    @ViewBuilder
    func body(content: Content) -> some View {
        if useNativeContour {
            content
        } else {
            content.mask {
                GeometryReader { geometry in
                    BottomMorphShape(
                        topRadius: 20,
                        shoulder: 22,
                        progress: progress,
                        contracting: contracting
                    )
                    .fill(Color.white)
                    .frame(width: geometry.size.width, height: geometry.size.height)
                }
            }
        }
    }
}
#endif

final class AppIconCache {
    static let shared = AppIconCache()
    private let cache = NSCache<NSString, NSImage>()
    private init() { cache.countLimit = 160 }
    func icon(for url: URL) -> NSImage {
        let key = url.path as NSString
        if let cached = cache.object(forKey: key) { return cached }
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        icon.size = NSSize(width: 64, height: 64)
        cache.setObject(icon, forKey: key)
        return icon
    }
}

final class ClipboardThumbnailCache {
    static let shared = ClipboardThumbnailCache()
    private let cache = NSCache<NSNumber, NSImage>()
    private init() { cache.countLimit = 64 }

    func image(for id: Int64, data: Data) -> NSImage? {
        let key = NSNumber(value: id)
        if let cached = cache.object(forKey: key) { return cached }
        guard let image = NSImage(data: data) else { return nil }
        cache.setObject(image, forKey: key)
        return image
    }
}

final class ApplicationCatalogWatcher {
    private let queue = DispatchQueue(label: "org.macplusplus.search.catalog-watch", qos: .utility)
    private var sources: [DispatchSourceFileSystemObject] = []
    private var pending: DispatchWorkItem?
    private var callback: (() -> Void)?

    func start(callback: @escaping () -> Void) {
        self.callback = callback
        rebuildSources()
    }

    private func rebuildSources() {
        queue.async { [weak self] in
            guard let self else { return }
            self.sources.forEach { $0.cancel() }
            self.sources.removeAll()
            for directory in self.catalogDirectories() {
                let descriptor = open(directory.path, O_EVTONLY)
                guard descriptor >= 0 else { continue }
                let source = DispatchSource.makeFileSystemObjectSource(
                    fileDescriptor: descriptor,
                    eventMask: [.write, .delete, .rename, .extend, .attrib, .link],
                    queue: self.queue
                )
                source.setCancelHandler { close(descriptor) }
                source.setEventHandler { [weak self] in self?.directoryChanged() }
                source.resume()
                self.sources.append(source)
            }
        }
    }

    private func catalogDirectories() -> [URL] {
        let roots = [URL(fileURLWithPath: "/Applications"), URL(fileURLWithPath: NSHomeDirectory() + "/Applications")]
        var directories = roots.filter { FileManager.default.fileExists(atPath: $0.path) }
        for root in roots {
            guard let enumerator = FileManager.default.enumerator(
                at: root,
                includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles, .skipsPackageDescendants]
            ) else { continue }
            for case let url as URL in enumerator {
                guard (try? url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
                if url.pathExtension.lowercased() == "app" { enumerator.skipDescendants(); continue }
                directories.append(url)
            }
        }
        return directories
    }

    private func directoryChanged() {
        pending?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            DispatchQueue.main.async { [weak self] in self?.callback?() }
            self.rebuildSources()
        }
        pending = work
        queue.asyncAfter(deadline: .now() + 0.55, execute: work)
    }

    deinit {
        pending?.cancel()
        sources.forEach { $0.cancel() }
    }
}

enum ItemKind: String {
    case app = "APP"
    case script = "MACPP"
    case action = "ACTION"
    case calculation = "CALC"
    case clipboard = "CLIP"
    case keybind = "KEY"
    case emoji = "EMOJI"
    case symbol = "SYMBOL"
    case window = "WINDOW"
}

struct CommandItem: Identifiable, Hashable {
    let id: String
    let title: String
    let subtitle: String
    let kind: ItemKind
    let icon: String
    var url: URL? = nil
    var script: ScriptCommand? = nil
    var clipboardEntryID: Int64? = nil
    var clipboardPinned = false
    var clipboardThumbnail: Data? = nil
    var copyValue: String? = nil
    var displayValue: String? = nil
    var windowID: Int? = nil
    var windowPullable = false
    /// Search synonyms are intentionally kept with the result instead of in a
    /// second global index, so a command's visible title, action, and aliases
    /// cannot drift apart as controls are added.
    var aliases: [String] = []
    /// How many lines of `title` this row is allowed to show. Every ordinary
    /// result is a single line -- an app or command name that should truncate
    /// rather than reflow. The local-AI answer is the exception: it is prose
    /// of unpredictable length, and clamping it to one line silently threw
    /// away most of the response.
    var bodyLineCount: Int = 1

    /// Search results can include user-provided script metadata and bounded
    /// picker values, so not every stored SF Symbol name is guaranteed to be
    /// available on the host OS. Resolve those names at render time instead of
    /// allowing SwiftUI's Image(systemName:) to produce an empty tile.
    var resolvedIconName: String {
        let candidate = icon.trimmingCharacters(in: .whitespacesAndNewlines)
        if !candidate.isEmpty,
           NSImage(systemSymbolName: candidate, accessibilityDescription: nil) != nil {
            return candidate
        }

        let fallback: String
        switch kind {
        case .app: fallback = "app"
        case .script: fallback = "terminal"
        case .action: fallback = "bolt"
        case .calculation: fallback = "function"
        case .clipboard: fallback = "doc.text"
        case .keybind: fallback = "keyboard"
        case .emoji: fallback = "face.smiling"
        case .symbol: fallback = "square.grid.3x3"
        case .window: fallback = "macwindow"
        }
        return NSImage(systemSymbolName: fallback, accessibilityDescription: nil) != nil
            ? fallback
            : "circle.fill"
    }

    /// Width available to the title inside a row, after the launcher's own
    /// horizontal padding (26 each side), the row padding (10 each side), the
    /// 32pt icon and its 12pt gap.
    static let bodyTextWidth: CGFloat = 680 - 52 - 20 - 32 - 12

    /// Row height for this item. The base 44 matches every ordinary row;
    /// additional lines add one line height each.
    var rowHeight: CGFloat { 44 + CGFloat(max(0, bodyLineCount - 1)) * 17 }

    /// Rough line count for a body of prose at the row's title size. Deliberate
    /// over-estimate on the average character width so a wrap is more likely to
    /// be predicted than missed -- under-estimating would clip again, which is
    /// the bug being fixed.
    static func estimatedLines(for text: String, limit: Int = 8) -> Int {
        guard !text.isEmpty else { return 1 }
        let charactersPerLine = max(1, Int(bodyTextWidth / 7.0))
        let wrapped = Int(ceil(Double(text.count) / Double(charactersPerLine)))
        let explicit = text.components(separatedBy: "\n").count
        return min(limit, max(1, max(wrapped, explicit)))
    }
}

struct ScriptCommand: Hashable {
    let path: String
    let title: String
    let description: String
    let icon: String
    let argumentPlaceholder: String?
    let argumentOptional: Bool
}

private struct MacPlusPlusSearchScreensaverChoice: Identifiable {
    let selection: String
    let title: String
    let subtitle: String
    let symbol: String
    let aliases: [String]

    var id: String { selection }
}

private let macppSearchScreensaverChoices: [MacPlusPlusSearchScreensaverChoice] = [
    MacPlusPlusSearchScreensaverChoice(
        selection: "cmatrix",
        title: "CMatrix",
        subtitle: "Classic terminal matrix for the next idle launch",
        symbol: "terminal.fill",
        aliases: ["cmatrix", "matrix", "classic"]
    )
] + [
    "constellation", "orrery", "starfield", "bonsai",
    "aurora", "warp", "skyline", "aquarium", "fireflies", "terrain", "netpulse",
    "kaleidoscope", "solar", "observatory", "campfire", "synthwave", "music", "voidstorm", "orbitalforge", "abyssalrelay", "datacathedral", "signalcollapse", "eventhorizon", "velvetvortex", "odyssey", "crimsonorbit", "glassreef", "clockwork"
].map { scene in
    let isVoidstorm = scene == "voidstorm"
    let isOrbitalForge = scene == "orbitalforge"
    let isAbyssalRelay = scene == "abyssalrelay"
    let isDataCathedral = scene == "datacathedral"
    let isSignalCollapse = scene == "signalcollapse"
    let title = scene == "glassreef" ? "Glass Reef" : scene == "clockwork" ? "Clockwork Bloom" : scene == "crimsonorbit" ? "Crimson Orbit" : scene == "odyssey" ? "Odyssey" : scene == "velvetvortex" ? "Velvet Vortex" : scene == "eventhorizon" ? "Event Horizon" : isVoidstorm
        ? "Void Engine"
        : (isOrbitalForge
            ? "Orbital Forge"
            : (isAbyssalRelay
                ? "Abyssal Relay"
                : (isDataCathedral ? "Data Cathedral" : (isSignalCollapse ? "Signal Collapse" : "Preview / \(scene)"))))
    let subtitle = scene == "glassreef" ? "A 3D glide through branching coral, fish schools, and bioluminescent water" : scene == "clockwork" ? "A rotating 3D flower built from gold gears and luminous enamel petals" : scene == "crimsonorbit" ? "A spiraling flight through a fractured crimson reactor" : scene == "odyssey" ? "Cinematic flight through a fractured citadel and a living core" : scene == "velvetvortex" ? "Flight through a luminous braided 3D tunnel" : scene == "eventhorizon" ? "A 3D terminal singularity with orbital rings and streaming particles" : isVoidstorm
        ? "Dense recursive terminal animation with a live reactor core"
        : (isOrbitalForge
            ? "Projected 3-D orbital computer with solar wings, star streaks, and a docking grid"
            : (isAbyssalRelay
                ? "Deep-sea relay station with scanning sonar, a moving drone, and living kelp"
                : (isDataCathedral
                    ? "Architectural terminal nave with a rotating data rose"
                    : (isSignalCollapse
                        ? "Full-bleed chaotic terminal field with edge-to-edge motion"
                        : "Terminal preview scene for the next idle launch"))))
    let symbol = scene == "glassreef"
        ? "water.waves"
        : (scene == "clockwork" ? "gearshape.2" : (isVoidstorm
        ? "circle.dotted"
        : (isOrbitalForge ? "gyroscope" : (isAbyssalRelay ? "water.waves" : (isDataCathedral ? "building.columns" : "waveform")))))
    let aliases = scene == "glassreef"
        ? ["glass reef", "underwater", "coral", "ocean", "3d"]
        : (scene == "clockwork"
        ? ["clockwork bloom", "gears", "mechanical flower", "3d"]
        : (isVoidstorm
        ? ["void engine", "terminal storm", "heavy", "goal piece"]
        : (isOrbitalForge
            ? ["orbital forge", "3d", "three dimensional", "space", "satellite", "computer", "wireframe", "heavy"]
            : (isAbyssalRelay
                ? ["abyssal relay", "deep sea", "sonar", "submarine", "ocean", "themed", "heavy"]
                : (isDataCathedral
                    ? ["data cathedral", "cathedral", "archive", "heavy", "themed"]
                    : (isSignalCollapse
                        ? ["signal collapse", "chaos", "full bleed", "full screen", "heavy"]
                        : []))))))
    return MacPlusPlusSearchScreensaverChoice(
        selection: "macpp-preview:\(scene)",
        title: title,
        subtitle: subtitle,
        symbol: symbol,
        aliases: ["preview", scene] + aliases
    )
}

private func macppSearchScreensaverSelection() -> String {
    let configHome = ProcessInfo.processInfo.environment["XDG_CONFIG_HOME"]
        .flatMap { $0.isEmpty ? nil : $0 }
        ?? (NSHomeDirectory() + "/.config")
    let path = URL(fileURLWithPath: configHome, isDirectory: true)
        .appendingPathComponent("macpp", isDirectory: true)
        .appendingPathComponent("screensaver")
    let raw = (try? String(contentsOf: path, encoding: .utf8))?
        .trimmingCharacters(in: .whitespacesAndNewlines)
        .lowercased() ?? "cmatrix"
    return macppSearchScreensaverChoices.contains(where: { $0.selection == raw }) ? raw : "cmatrix"
}

/// MacPlusPlusCast accepts Raycast script metadata, but Raycast scripts commonly use
/// emoji for their icons. Emoji have their own colour, weight, and apparent
/// size (the old Screensaver command was literally a large blue square), so
/// they do not belong beside the launcher's thin native command glyphs.
/// Translate the MacPlusPlus script set to monochrome SF Symbols without changing the
/// scripts themselves or their appearance in Raycast.
private enum ScriptIconStyle {
    static func symbol(for rawIcon: String?, title: String) -> String {
        let raw = (rawIcon ?? "")
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .replacingOccurrences(of: "️", with: "")

        let knownEmoji: [String: String] = [
            "🔁": "arrow.clockwise",
            "🎮": "gamecontroller",
            "🎵": "music.note",
            "🎞": "film",
            "🟦": "display",
            "💼": "briefcase",
            "🖼": "photo.on.rectangle",
            "👁": "eye"
        ]
        if let symbol = knownEmoji[raw] { return symbol }

        // Preserve an explicitly supplied SF Symbol name. Emoji and file-name
        // metadata fall through to a semantic symbol inferred from the title.
        if !raw.isEmpty,
           raw.unicodeScalars.allSatisfy(\.isASCII),
           !raw.contains(where: \.isWhitespace),
           !raw.contains("/") {
            return raw
        }

        let name = title.lowercased()
        if name.contains("game") { return "gamecontroller" }
        if name.contains("work") { return "briefcase" }
        if name.contains("restart") { return "arrow.clockwise" }
        if name.contains("screensaver") || name.contains("screen saver") { return "display" }
        if name.contains("screenshot") || name.contains("image") { return "photo.on.rectangle" }
        if name.contains("audio") || name.contains("music") { return "music.note" }
        if name.contains("video") || name.contains("film") { return "film" }
        if name.contains("peek") || name.contains("preview") { return "eye" }
        if name.contains("download") { return "arrow.down.circle" }
        return "bolt"
    }
}

private enum CalculatorEngine {
    static func evaluate(_ expression: String) -> String? {
        var parser = Parser(expression)
        guard let value = parser.parse(), value.isFinite else { return nil }
        let clean = abs(value) < 1e-13 ? 0 : value
        return String(format: "%.12g", locale: Locale(identifier: "en_US_POSIX"), clean)
    }

    static func looksLikeExpression(_ expression: String) -> Bool {
        let compact = normalized(expression).replacingOccurrences(of: " ", with: "")
        guard !compact.isEmpty else { return false }
        if compact == "pi" || compact == "e" { return true }
        let functions = ["sqrt(", "abs(", "sin(", "cos(", "tan(", "asin(", "acos(", "atan(", "ln(", "log(", "floor(", "ceil(", "round(", "min(", "max(", "pow("]
        if functions.contains(where: { compact.lowercased().hasPrefix($0) }) { return true }
        guard compact.contains(where: { $0.isNumber }) else { return false }
        return compact.dropFirst().contains(where: { "+-*/^%!".contains($0) })
            || compact.contains("(")
            || compact.lowercased().contains("mod")
    }

    private static func normalized(_ expression: String) -> String {
        expression
            .replacingOccurrences(of: "×", with: "*")
            .replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-")
            .replacingOccurrences(of: "π", with: "pi")
    }

    private struct Parser {
        private let characters: [Character]
        private var index = 0
        private var failed = false

        init(_ source: String) {
            characters = Array(CalculatorEngine.normalized(source))
        }

        mutating func parse() -> Double? {
            guard let result = parseAdditive() else { return nil }
            skipSpaces()
            return !failed && index == characters.count ? result : nil
        }

        private mutating func parseAdditive() -> Double? {
            guard var value = parseMultiplicative() else { return nil }
            while true {
                if consume("+") { guard let rhs = parseMultiplicative() else { return nil }; value += rhs }
                else if consume("-") { guard let rhs = parseMultiplicative() else { return nil }; value -= rhs }
                else { return value }
            }
        }

        private mutating func parseMultiplicative() -> Double? {
            guard var value = parseUnary() else { return nil }
            while true {
                if consume("*") {
                    guard let rhs = parseUnary() else { return nil }
                    value *= rhs
                } else if consume("/") {
                    guard let rhs = parseUnary(), rhs != 0 else { failed = true; return nil }
                    value /= rhs
                } else if consumeWord("mod") {
                    guard let rhs = parseUnary(), rhs != 0 else { failed = true; return nil }
                    value.formTruncatingRemainder(dividingBy: rhs)
                } else { return value }
            }
        }

        private mutating func parseUnary() -> Double? {
            if consume("+") { return parseUnary() }
            if consume("-") { return parseUnary().map(-) }
            return parsePower()
        }

        private mutating func parsePower() -> Double? {
            guard let base = parsePostfix() else { return nil }
            if consume("^") {
                guard let exponent = parseUnary() else { return nil }
                return Darwin.pow(base, exponent)
            }
            return base
        }

        private mutating func parsePostfix() -> Double? {
            guard var value = parsePrimary() else { return nil }
            while true {
                if consume("%") {
                    value /= 100
                } else if consume("!") {
                    guard value >= 0, value <= 170, value.rounded() == value else { failed = true; return nil }
                    if value < 2 { value = 1 }
                    else { value = (2...Int(value)).reduce(1.0) { $0 * Double($1) } }
                } else { return value }
            }
        }

        private mutating func parsePrimary() -> Double? {
            skipSpaces()
            if consume("(") {
                guard let value = parseAdditive(), consume(")") else { failed = true; return nil }
                return value
            }
            if let number = parseNumber() { return number }
            guard let identifier = parseIdentifier() else { return nil }
            switch identifier {
            case "pi": return Double.pi
            case "e": return M_E
            default: break
            }
            guard consume("(") else { failed = true; return nil }
            var arguments: [Double] = []
            if !peek(")") {
                while true {
                    guard let value = parseAdditive() else { return nil }
                    arguments.append(value)
                    if consume(",") { continue }
                    break
                }
            }
            guard consume(")"), let result = apply(identifier, arguments) else { failed = true; return nil }
            return result
        }

        private func apply(_ name: String, _ values: [Double]) -> Double? {
            switch (name, values.count) {
            case ("sqrt", 1): return values[0] >= 0 ? Darwin.sqrt(values[0]) : nil
            case ("abs", 1): return Swift.abs(values[0])
            case ("sin", 1): return Darwin.sin(values[0])
            case ("cos", 1): return Darwin.cos(values[0])
            case ("tan", 1): return Darwin.tan(values[0])
            case ("asin", 1): return Darwin.asin(values[0])
            case ("acos", 1): return Darwin.acos(values[0])
            case ("atan", 1): return Darwin.atan(values[0])
            case ("ln", 1): return values[0] > 0 ? Darwin.log(values[0]) : nil
            case ("log", 1): return values[0] > 0 ? Darwin.log10(values[0]) : nil
            case ("floor", 1): return Darwin.floor(values[0])
            case ("ceil", 1): return Darwin.ceil(values[0])
            case ("round", 1): return values[0].rounded()
            case ("min", 2): return Swift.min(values[0], values[1])
            case ("max", 2): return Swift.max(values[0], values[1])
            case ("pow", 2): return Darwin.pow(values[0], values[1])
            default: return nil
            }
        }

        private mutating func parseNumber() -> Double? {
            skipSpaces()
            let start = index
            var sawDigit = false
            while index < characters.count, characters[index].isNumber { sawDigit = true; index += 1 }
            if index < characters.count, characters[index] == "." {
                index += 1
                while index < characters.count, characters[index].isNumber { sawDigit = true; index += 1 }
            }
            guard sawDigit else { index = start; return nil }
            if index < characters.count, characters[index] == "e" || characters[index] == "E" {
                let exponentStart = index
                index += 1
                if index < characters.count, characters[index] == "+" || characters[index] == "-" { index += 1 }
                let digitsStart = index
                while index < characters.count, characters[index].isNumber { index += 1 }
                if digitsStart == index { index = exponentStart }
            }
            return Double(String(characters[start..<index]))
        }

        private mutating func parseIdentifier() -> String? {
            skipSpaces()
            let start = index
            while index < characters.count, characters[index].isLetter { index += 1 }
            guard start != index else { return nil }
            return String(characters[start..<index]).lowercased()
        }

        private mutating func consume(_ character: Character) -> Bool {
            skipSpaces()
            guard index < characters.count, characters[index] == character else { return false }
            index += 1
            return true
        }

        private mutating func consumeWord(_ word: String) -> Bool {
            skipSpaces()
            let target = Array(word)
            guard index + target.count <= characters.count else { return false }
            let candidate = String(characters[index..<(index + target.count)]).lowercased()
            guard candidate == word else { return false }
            index += target.count
            return true
        }

        private mutating func peek(_ character: Character) -> Bool {
            skipSpaces()
            return index < characters.count && characters[index] == character
        }

        private mutating func skipSpaces() {
            while index < characters.count, characters[index].isWhitespace { index += 1 }
        }
    }
}

@MainActor final class LauncherModel: ObservableObject {
    // Match Nexus's width while keeping this selector deliberately shallow.
    // The extra room accommodates the larger preview cards and the always
    // visible Add action without turning the picker into a tall dashboard.
    static let wallpaperCarouselHeight: CGFloat = 248
    // Screensavers use the same shallow, static-card treatment as the
    // visualizer carousel. They are previews only; selecting one still uses
    // the existing terminal saver command when the idle saver is launched.
    static let screensaverCarouselHeight: CGFloat = wallpaperCarouselHeight
    static let wallpaperEditorHeight: CGFloat = 448

    @Published var query = "" {
        didSet {
            // TextField's two-way binding writes this property back on
            // essentially every re-render, not only on an actual keystroke
            // -- didSet fires on every assignment regardless of whether the
            // value changed, so without this guard, every one of those
            // no-op writebacks silently reset the arrow-selected row back
            // to the top a moment before Return read it. That, not the
            // arrow keys or Return handling themselves, was the confirmed
            // cause of Return running the topmost result.
            //
            // SwiftUI's onChange callback runs after the model's didSet. If a
            // fast keystroke replaces a previously selected result, Return
            // could therefore read the old index before the view reset it.
            // Keep selection validity in the model so keyboard dispatch and
            // the embedded Shell follow the same synchronous rule.
            guard query != oldValue else { return }
            selected = 0
            rebuildDisplayedItems()
        }
    }
    @Published private(set) var pendingArgumentItem: CommandItem?
    @Published private(set) var focusRequest = 0
    @Published var selected = 0
    @Published var status = "READY"
    @Published var isRunning = false
    @Published private(set) var nexusPresented = false
    @Published private(set) var wallpapersPresented = false
    @Published private(set) var wallpaperEditorPresented = false
    @Published private(set) var desktopPresented = false
    @Published private(set) var screensaversPresented = false
    @Published private(set) var nexusTransitioning = false
    @Published private(set) var nexusMorphProgress: CGFloat = 0
#if MACPP_CAELESTIA_SHELL
    /// The desktop envelope is the authored baseline.  A display-local scale
    /// is published only when the current screen cannot contain that baseline;
    /// every launcher state then uses the same scale so the morph never mixes
    /// a compact host with a full-size child.
    @Published private(set) var displayMetrics = CaelestiaParityGeometry.DisplayMetrics.authored
#endif
    @Published private(set) var displayedItems: [CommandItem] = [] {
        didSet {
            guard !nexusPresented, !wallpapersPresented, !desktopPresented,
                  !screensaversPresented, !nexusTransitioning else { return }
            let baseNext: CGFloat = pendingArgumentItem != nil
                ? 136
                : (query.isEmpty ? 390 : min(390, max(136, 76 + measuredResultsHeight)))
            schedulePanelHeight(responsiveHeight(baseNext))
        }
    }
    @Published private(set) var panelHeight: CGFloat = 390
    // Palette.pale / .muted / .cyan are plain statics that read the host
    // shell's live theme at render time -- they are not observable, so
    // SwiftUI has no dependency on them. LauncherView gets refreshed anyway
    // because it observes this model, but ResultRow is an extracted child
    // whose inputs (item, active, namespace) do not change when the palette
    // does, so structural diffing skipped it and each row kept the colours it
    // had captured on its last render. Hovering flipped its @State and forced
    // a re-render, which is exactly why rows only corrected themselves once
    // the pointer touched them. Passing this counter in as a real stored
    // value gives the row an input that genuinely changes.
    @Published var paletteRevision = 0
    /// Bumped every time the launcher is presented, so the result list can
    /// return to the top.
    ///
    /// Scrolling was previously only reset by `onChange(of: selected)`, which
    /// cannot cover presentation: showing the launcher sets `selected` to 0,
    /// and it is almost always 0 already, so the change never fires. The
    /// launcher window and its hosting view are reused between openings, so
    /// the ScrollView simply kept whatever offset it had when it was last
    /// dismissed -- reopening could land you halfway down the list.
    @Published private(set) var listResetToken = 0

    func resetListPosition() { listResetToken &+= 1 }

    /// Publishes an arrow press for an embedded carousel. The shell owns the
    /// launcher window, while the carousel owns its local loop-padded index;
    /// a revision lets the child consume repeated presses even when the
    /// direction is the same as the previous one.
    func publishOverlayArrow(_ delta: Int) {
        guard delta != 0 else { return }
        overlayArrowDelta = delta
        overlayArrowRevision &+= 1
    }
    /// Publishes a confirm press for an embedded carousel. The carousel owns
    /// the highlighted item, while the shared launcher focus target owns the
    /// actual key event, so a revision lets the child consume repeated
    /// confirmations without moving focus into a card.
    func publishOverlayConfirm() {
        overlayConfirmRevision &+= 1
    }
    var onHeightChange: ((CGFloat) -> Void)?
    // Embedded Shell owns both axes of the attached launcher frame. Keeping a
    // single size callback prevents a Nexus handoff from issuing a height
    // animation and a width animation in separate transactions.
    var onGeometryChange: ((CGFloat, CGFloat) -> Void)?
    var onOpenNexus: (() -> Void)?
    var onOpenNexusPage: ((MacPlusPlusNexusDestination) -> Void)?
    var onPerformQuickAction: ((MacPlusPlusLauncherQuickAction, Int?) -> Void)?
    // Arrow keys mean "move the selection in the result list" only while the
    // list is the thing on screen. Once Nexus (or the wallpaper carousel) has
    // taken over the surface, the list is hidden but still populated, so the
    // same keys would otherwise be quietly moving an invisible selection.
    // The host owns those overlays' state, so it gets told the direction and
    // decides what moving means there.
    var onOverlayArrow: ((Int) -> Void)?
    @Published private(set) var overlayArrowRevision = 0
    private(set) var overlayArrowDelta = 0
    @Published private(set) var overlayConfirmRevision = 0
    var overlayPresented: Bool {
        nexusPresented || wallpapersPresented || desktopPresented || screensaversPresented || nexusTransitioning
    }
    private var panelHeightTask: Task<Void, Never>?
    private var nexusTransitionTask: Task<Void, Never>?
    private(set) var baseItems: [CommandItem] = []
    /// `game` selects the deliberately small standalone Game catalog. Work
    /// and Performance retain the normal catalog contract.
    private var catalogMode: String?
    private var aiResponseQuery = ""
    private var aiResponseText = ""
    private let usageDefaultsKey = "macpp-cast.commandUsage"
    private let clipboardHistory: MacPlusPlusClipboardHistoryController?
    private let pickerCatalog: MacPlusPlusPickerCatalog?
    private var clipboardSearchTask: Task<Void, Never>?
    private var clipboardSearchGeneration = MacPlusPlusClipboardSearchGeneration()
    private var clipboardRenderedEntries: [MacPlusPlusClipboardEntry] = []
    private var windowSearchTask: Task<Void, Never>?
    private var windowSearchGeneration = 0

    private var requestedSurfaceWidth: CGFloat {
#if MACPPCAST_EMBEDDED
        #if MACPP_CAELESTIA_SHELL
        (nexusPresented || wallpapersPresented || desktopPresented || screensaversPresented)
            ? displayMetrics.launcherNexusWidth
            : displayMetrics.launcherSearchWidth
        #else
        (nexusPresented || wallpapersPresented || desktopPresented || screensaversPresented) ? nexusWidth : launcherWidth
        #endif
#else
        launcherWidth
#endif
    }

    private func responsiveHeight(_ authoredHeight: CGFloat) -> CGFloat {
#if MACPP_CAELESTIA_SHELL
        authoredHeight * displayMetrics.scale
#else
        authoredHeight
#endif
    }

#if MACPP_CAELESTIA_SHELL
    /// Refresh the launcher geometry for the display that owns its AppKit
    /// window.  Wide displays resolve to `DisplayMetrics.authored`, so this is
    /// intentionally a no-op for the existing desktop layout.
    func configureResponsiveLayout(for screenSize: CGSize) {
        let next = CaelestiaParityGeometry.DisplayMetrics(screenSize: screenSize)
        guard next != displayMetrics else { return }
        displayMetrics = next
        let baseHeight: CGFloat
        if nexusPresented {
            baseHeight = nexusHeight
        } else if wallpapersPresented {
            baseHeight = wallpaperEditorPresented
                ? Self.wallpaperEditorHeight
                : Self.wallpaperCarouselHeight
        } else if desktopPresented {
            baseHeight = Self.wallpaperCarouselHeight
        } else if screensaversPresented {
            baseHeight = Self.screensaverCarouselHeight
        } else {
            baseHeight = pendingArgumentItem != nil
                ? 136
                : (query.isEmpty ? 390 : min(390, max(136, 76 + measuredResultsHeight)))
        }
        panelHeight = responsiveHeight(baseHeight)
        notifyGeometryChange()
    }
#endif

    private func notifyGeometryChange() {
        if let onGeometryChange {
            onGeometryChange(panelHeight, requestedSurfaceWidth)
        } else {
            onHeightChange?(panelHeight)
        }
    }

    /// Script names are commonly written with hyphens or underscores while
    /// their visible catalog titles use spaces. Keep filtering and activation
    /// on one key so `game-mode`, `game_mode`, and `Game Mode` cannot resolve
    /// to different result states.
    private func searchKey(_ value: String) -> String {
        MacPlusPlusSearchText.normalize(value)
    }

    init() {
        do {
            pickerCatalog = try MacPlusPlusPickerCatalog.loadProduction()
        } catch {
            pickerCatalog = nil
        }
        let history: MacPlusPlusClipboardHistoryController? = nil
        clipboardHistory = history
        history?.start { [weak self] in
            guard let self, let searchTerm = self.clipboardQueryTerm else { return }
            let selectedID = self.displayedItems.indices.contains(self.selected)
                ? self.displayedItems[self.selected].clipboardEntryID
                : nil
            self.scheduleClipboardSearch(searchTerm, showLoading: false, preserving: selectedID)
        }
    }

    func stop() {
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()
        nexusTransitionTask = nil
        clipboardSearchTask?.cancel()
        clipboardSearchTask = nil
        windowSearchTask?.cancel()
        windowSearchTask = nil
        _ = clipboardSearchGeneration.advance()
        windowSearchGeneration &+= 1
        clipboardHistory?.stop()
    }

    var items: [CommandItem] { displayedItems }
    var isEnteringArgument: Bool { pendingArgumentItem != nil }
    var inputPlaceholder: String { pendingArgumentItem?.script?.argumentPlaceholder ?? "Search" }
    var pendingCommandTitle: String? { pendingArgumentItem?.title }

    /// Total height of the result rows, honouring any row that needs more than
    /// one line. This used to be `count * 47`, which assumed every row was the
    /// same fixed height -- so a multi-line AI answer was allotted the space of
    /// a single-line app name and the rest was simply clipped away.
    /// 47 = the 44pt row plus the LazyVStack's 3pt spacing.
    private var measuredResultsHeight: CGFloat {
        displayedItems.reduce(0) { $0 + $1.rowHeight + 3 }
    }

    private func schedulePanelHeight(_ next: CGFloat) {
        guard panelHeight != next else {
            panelHeightTask?.cancel()
            panelHeightTask = nil
            return
        }
#if MACPPCAST_EMBEDDED
        // A search can change the result count on every keystroke. Coalesce
        // those bursts so the AppKit window and the shell contour perform one
        // continuous resize instead of repeatedly restarting their curves.
        //
        // A single symmetric 55ms debounce wasn't enough on its own: mid-word
        // states routinely collapse to one row (a lone "Search the web for
        // ..." fallback) and then jump straight back to a full list on the
        // very next keystroke, so the panel visibly snapped shut and reopened
        // between characters. Growing is what the user is actually waiting to
        // see, so it stays quick; shrinking is the direction that produces
        // the flicker, so it waits long enough that a transient dip is
        // overtaken -- and cancelled -- by the next keystroke rather than
        // being played out as a full collapse.
        // 45ms was shorter than the gap between keystrokes for anyone typing
        // at speed, so nearly every character produced its own resize: the
        // window animation was restarted before the previous one had travelled
        // far, and the panel appeared to lurch rather than move. 110ms sits
        // just past a fast typing cadence, so a burst of keystrokes coalesces
        // into one resize while a single deliberate keystroke still feels
        // immediate. Shrinking stays much longer -- see below.
        let shrinking = next < panelHeight
        let delay: UInt64 = shrinking ? 260_000_000 : 110_000_000
        panelHeightTask?.cancel()
        panelHeightTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.panelHeight != next else { return }
            self.panelHeight = next
            self.notifyGeometryChange()
            self.panelHeightTask = nil
        }
#else
        panelHeight = next
        notifyGeometryChange()
#endif
    }

    /// Build the current catalog once. Spotlight is queried only during this
    /// rebuild, not while the launcher is idle. Game intentionally omits
    /// wallpaper, capture, AI, and other Work-only controls.
    private func catalogItems(includeSpotlight: Bool) -> [CommandItem] {
        let nativeItems = nativeCommands()
        // Observatory is a diagnostic escape hatch, not a launch-critical
        // control. Keep it in the catalog for search and troubleshooting, but
        // place it after the normal scripts instead of recommending it beside
        // Nexus on every empty launcher.
        let observatoryItems = nativeItems.filter { $0.id == "native:observatory" }
        let standardNativeItems = nativeItems.filter { $0.id != "native:observatory" }
        let apps = discoverApps(includeSpotlight: includeSpotlight)
            .sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }

        let nativeScreensaverTitles: Set<String> = [
            "list screen savers", "set screen saver", "screensaver"
        ]
        let otherScripts = discoverScripts()
            .filter {
                let title = $0.title.lowercased()
                return !["work mode", "game mode", "performance mode"].contains(title) &&
                    !nativeScreensaverTitles.contains(title)
            }
            .map { script in
                CommandItem(
                    id: "script:\(script.path)",
                    title: script.title,
                    subtitle: "",
                    kind: .script,
                    icon: script.icon,
                    script: script
                )
            }
        return standardNativeItems
            + apps
            + otherScripts.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }
            + observatoryItems
    }

    /// Build the current catalog once. Spotlight is queried only during this
    /// rebuild, not while the launcher is idle.
    func loadCatalog() {
        // The catalog watcher calls this on any filesystem touch inside
        // /Applications, not only a genuine install/removal -- Spotlight
        // metadata and LaunchServices bookkeeping alone are enough. That can
        // land mid-interaction, and unconditionally snapping back to row 0
        // silently discarded whatever the user had just arrowed to a moment
        // before Return: the topmost result would fire instead. Re-find the
        // same item by id in the rebuilt list instead, so a background
        // refresh cannot outrun deliberate keyboard navigation.
        let previousSelectedID = items.indices.contains(selected) ? items[selected].id : nil
        baseItems = catalogItems(includeSpotlight: true)
        refreshMode()
        rebuildDisplayedItems()
        selected = previousSelectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
    }

    func requestSearchFocus() { focusRequest &+= 1 }

    func presentNexus(immediate: Bool = false) {
        guard !nexusPresented, !wallpapersPresented, !desktopPresented,
              !screensaversPresented, !nexusTransitioning else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()

        if immediate {
            // A direct Nexus entry point already knows the destination. Insert
            // the final Nexus surface before the outer reveal so it never
            // visits the 390pt search height on the way there. The delayed
            // path below remains the intentional search -> Nexus morph.
            nexusPresented = true
            nexusTransitioning = false
            nexusMorphProgress = 1
            panelHeight = responsiveHeight(nexusHeight)
            notifyGeometryChange()
            return
        }

        // Nexus is a second state of the existing MacPlusPlusCast surface. Insert it
        // invisibly first, then drive the host resize and both content layers
        // from one shared Caelestia spatial phase. This removes the old
        // resize-then-replace beat and keeps the physical contour, launcher,
        // and Nexus moving as one continuous object.
        nexusTransitioning = true
        nexusPresented = true
        nexusMorphProgress = 0

        // Give SwiftUI one complete display frame to insert and lay out the
        // hidden Nexus layer before the shared resize begins. Starting both
        // in the insertion transaction lets the host stretch around an
        // unpainted child, which produces a blank replacement-style frame.
        nexusTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: displayCommitDelayNanoseconds())
            guard !Task.isCancelled, let self,
                  self.nexusPresented, self.nexusTransitioning else { return }
            self.panelHeight = self.responsiveHeight(nexusHeight)
            self.notifyGeometryChange()
            let nanoseconds = UInt64(CastMotion.resize.duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.nexusPresented else { return }
            self.finishOverlayTransition()
        }
    }

    func presentWallpapers() {
        // A wallpaper request can arrive through more than one notification
        // bridge. Once this transition has started, a duplicate must be a
        // no-op: resetting the phase to zero mid-morph makes the launcher snap
        // back to MacPlusPlusCast and visibly restart before the carousel appears.
        guard !wallpapersPresented else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()
        nexusPresented = false
        wallpaperEditorPresented = false
        desktopPresented = false
        screensaversPresented = false
        nexusTransitioning = true
        wallpapersPresented = true
        nexusMorphProgress = 0

        // Match the Nexus handoff: insert and lay out the hidden destination
        // for one complete display frame before resizing the AppKit host. The
        // carousel resolves its cached posters in onAppear; beginning the host
        // resize in that same transaction exposed a blank/half-painted frame.
        nexusTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: displayCommitDelayNanoseconds())
            guard !Task.isCancelled, let self,
                  self.wallpapersPresented, self.nexusTransitioning else { return }
            self.panelHeight = self.responsiveHeight(Self.wallpaperCarouselHeight)
            self.notifyGeometryChange()
            let nanoseconds = UInt64(CastMotion.resize.duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.wallpapersPresented else { return }
            self.finishOverlayTransition()
        }
    }

    func presentWallpaperEditor() {
        guard wallpapersPresented, !wallpaperEditorPresented else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        withAnimation(CastMotion.resize.animation) {
            wallpaperEditorPresented = true
        }
        panelHeight = responsiveHeight(Self.wallpaperEditorHeight)
        notifyGeometryChange()
    }

    func dismissWallpaperEditor() {
        guard wallpaperEditorPresented else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        withAnimation(CastMotion.resize.animation) {
            wallpaperEditorPresented = false
        }
        panelHeight = responsiveHeight(Self.wallpaperCarouselHeight)
        notifyGeometryChange()
    }

    func presentDesktop() {
        // Desktop scenes share the wallpaper switcher's compact morph, but
        // keep their own presentation state so Nexus and Wallpapers can never
        // accidentally paint underneath the scene carousel.
        guard !desktopPresented else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()
        nexusPresented = false
        wallpapersPresented = false
        wallpaperEditorPresented = false
        screensaversPresented = false
        nexusTransitioning = true
        desktopPresented = true
        nexusMorphProgress = 0

        nexusTransitionTask = Task { @MainActor [weak self] in
            // macpp:silent-ok cancellation is the normal transition debounce path
            try? await Task.sleep(nanoseconds: displayCommitDelayNanoseconds())
            guard !Task.isCancelled, let self,
                  self.desktopPresented, self.nexusTransitioning else { return }
            self.panelHeight = self.responsiveHeight(Self.wallpaperCarouselHeight)
            self.notifyGeometryChange()
            let nanoseconds = UInt64(CastMotion.resize.duration * 1_000_000_000)
            // macpp:silent-ok cancellation is the normal transition debounce path
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.desktopPresented else { return }
            self.finishOverlayTransition()
        }
    }

    func presentScreensavers() {
        // Screensavers are a third carousel state, not another terminal
        // launch path. Insert the static preview surface first, then use the
        // same shared resize/morph clock as Wallpapers and Desktop.
        guard !screensaversPresented else { return }
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()
        nexusPresented = false
        wallpapersPresented = false
        wallpaperEditorPresented = false
        desktopPresented = false
        nexusTransitioning = true
        screensaversPresented = true
        nexusMorphProgress = 0

        nexusTransitionTask = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: displayCommitDelayNanoseconds())
            guard !Task.isCancelled, let self,
                  self.screensaversPresented, self.nexusTransitioning else { return }
            self.panelHeight = self.responsiveHeight(Self.screensaverCarouselHeight)
            self.notifyGeometryChange()
            let nanoseconds = UInt64(CastMotion.resize.duration * 1_000_000_000)
            try? await Task.sleep(nanoseconds: nanoseconds)
            guard !Task.isCancelled, self.screensaversPresented else { return }
            self.finishOverlayTransition()
        }
    }

    func resetNexus() {
        nexusTransitionTask?.cancel()
        nexusTransitionTask = nil
        nexusPresented = false
        wallpapersPresented = false
        wallpaperEditorPresented = false
        desktopPresented = false
        screensaversPresented = false
        nexusTransitioning = false
        nexusMorphProgress = 0
        let next: CGFloat = query.isEmpty ? 390 : min(390, max(136, 76 + measuredResultsHeight))
        panelHeight = responsiveHeight(next)
        notifyGeometryChange()
    }

    /// Freeze the currently visible launcher state before its host begins the
    /// shared shell dismissal. A Nexus resize task or a live search-height
    /// correction landing during that close changes the panel's geometry
    /// underneath the contour and reads as a laggy outside-click teardown.
    func cancelTransitionsForDismissal() {
        panelHeightTask?.cancel()
        panelHeightTask = nil
        nexusTransitionTask?.cancel()
        nexusTransitionTask = nil
        nexusTransitioning = false
    }

    /// The embedded shell's AppKit frame animator is the authoritative clock
    /// for an auxiliary surface morph. Publishing this value once per display
    /// sample keeps the incoming/outgoing bodies and the host window on the
    /// same curve instead of layering a SwiftUI implicit animation over it.
    func setOverlayMorphProgress(_ value: CGFloat) {
        guard nexusTransitioning else { return }
        nexusMorphProgress = min(1, max(0, value))
    }

    /// Finish a morph from the same callback that paints the terminal AppKit
    /// frame. The delayed task remains only as a watchdog for a display-link
    /// interruption; it must not be the normal visual completion path.
    func finishOverlayTransition() {
        guard nexusTransitioning else { return }
        nexusMorphProgress = 1
        query = ""
        selected = 0
        nexusTransitioning = false
        nexusTransitionTask?.cancel()
        nexusTransitionTask = nil
    }

    private func rebuildDisplayedItems() {
        if let pendingArgumentItem {
            displayedItems = [pendingArgumentItem]
            selected = 0
            return
        }
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        let normalized = searchKey(trimmed)
        if let pickerQuery = MacPlusPlusPickerQuery.parse(trimmed) {
            cancelClipboardSearch()
            cancelWindowSearch()
            renderPickerResults(pickerQuery)
            return
        }
        if let windowQuery = MacPlusPlusWindowQuery.parse(trimmed) {
            cancelClipboardSearch()
            scheduleWindowSearch(windowQuery)
            return
        }
        if [
            "screensaver", "screen saver", "screen savers",
            "list screen savers", "list screensavers", "screen saver carousel"
        ].contains(normalized) {
            cancelClipboardSearch()
            cancelWindowSearch()
            // The picker is the direct result for the short Search forms. The
            // individual scene names remain searchable below this path (for
            // example, `preview rain` selects one saver without opening the
            // carousel).
            displayedItems = Array(screensaverCommands().prefix(1))
            selected = 0
            return
        }
        cancelClipboardSearch()
        cancelWindowSearch()
#if MACPPCAST_EMBEDDED
        if let nexusQuery = MacPlusPlusNexusQuery.parse(trimmed) {
            displayedItems = [nexusItem(destination: nexusQuery.destination)]
            selected = 0
            return
        }
        if !normalized.isEmpty, "nexus".hasPrefix(normalized) || normalized == "control center" {
            displayedItems = [nexusItem(destination: .overview)]
            selected = 0
            return
        }
#endif
        if trimmed.hasPrefix(">") {
            let value = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            displayedItems = [CommandItem(id: "shell", title: value.isEmpty ? "Run shell command" : value,
                subtitle: "Execute with /bin/zsh -lc", kind: .action, icon: "terminal")]
            return
        }
        let explicitCalculation = trimmed.hasPrefix("=")
        let expression = calculatorExpression(from: trimmed)
        if explicitCalculation || CalculatorEngine.looksLikeExpression(expression) {
            if let result = CalculatorEngine.evaluate(expression) {
                displayedItems = [CommandItem(id: "calc", title: result,
                    subtitle: expression.isEmpty ? "Calculator" : "\(expression)  •  Return to copy",
                    kind: .calculation, icon: "function")]
                return
            } else if explicitCalculation {
                displayedItems = [CommandItem(id: "calc", title: "Enter an expression",
                    subtitle: "Arithmetic, parentheses, percentages, and functions",
                    kind: .calculation, icon: "function")]
                return
            }
        }
        if trimmed.isEmpty {
            var visible = baseItems.sorted { lhs, rhs in
                let leftUses = commandUsage(lhs.id)
                let rightUses = commandUsage(rhs.id)
                if leftUses != rightUses { return leftUses > rightUses }
                if lhs.kind != rhs.kind { return lhs.kind == .app }
                return lhs.title.localizedCaseInsensitiveCompare(rhs.title) == .orderedAscending
            }
            // Keep the launch-critical MacPlusPlus controls at the top of the empty
            // launcher in a stable order. Usage sorting is useful for the rest
            // of the catalog, but it made mode commands drift around depending
            // on what had been run most recently. Game/Performance are direct
            // script commands, so they still use the same execution path and
            // transition safety as every other MacPlusPlus command.
            var pinned: [CommandItem] = []
#if MACPPCAST_EMBEDDED
            pinned.append(nexusItem)
#endif
            // Both isolated modes must expose the escape hatch first. Game
            // uses its reduced catalog, while Performance keeps the full
            // catalog but still pins Work Mode ahead of every other action.
            // Work itself keeps the normal wallpaper/mode ordering.
            let launchCommandIDs: [String]
            launchCommandIDs = [
                "native:wallpapers",
                "native:desktop",
                "native:screensaver:list"
            ]
            for id in launchCommandIDs {
                guard let item = visible.first(where: { $0.id == id }) else { continue }
                visible.removeAll(where: { $0.id == id })
                pinned.append(item)
            }
            visible.insert(contentsOf: pinned, at: 0)
            displayedItems = visible
            return
        }
        // Once a Script Command has been selected, everything after its
        // complete title is its argument rather than another search token.
        // Without this fast path, pasting a URL after "Download Audio"
        // removed the command from the results and replaced it with Web
        // Search immediately before Return was pressed.
        let loweredQuery = normalized
        if let commandWithArgument = baseItems.first(where: { item in
            guard item.kind == .script, item.script?.argumentPlaceholder != nil else { return false }
            return loweredQuery.hasPrefix(searchKey(item.title) + " ")
        }) {
            displayedItems = [commandWithArgument]
            selected = 0
            return
        }
        let strippedSearchQuery = MacPlusPlusSearchText.removingLeadingNavigationWords(trimmed)
        let searchQuery = strippedSearchQuery.isEmpty ? trimmed : strippedSearchQuery
        let matches = baseItems.compactMap { item -> (CommandItem, Double)? in
            // Script descriptions remain searchable metadata even though the
            // result row intentionally no longer renders them as explanatory
            // subtitles.
            let haystack = searchKey("\(item.title) \(item.subtitle) \(item.script?.description ?? "")")
            let titleScore = MacPlusPlusSearchText.score(
                query: searchQuery,
                candidate: item.title,
                aliases: item.aliases
            )
            let metadataScore = MacPlusPlusSearchText.score(
                query: searchQuery,
                candidate: haystack
            )
            guard let score = titleScore ?? metadataScore.map({ 48 + $0 }) else { return nil }
            // A pure text-match tier ignored how often you actually use
            // something, so a short or habitual query (typing "s", or typing
            // "settings" instead of "system settings" out of habit) always
            // sorted by string closeness alone. Blend in usage frequency so
            // something you reach for constantly can outrank a nominally
            // closer match on an app you've never opened -- capped so it can
            // shift at most about two tiers, not bury exact matches entirely.
            let usage = commandUsage(item.id)
            let frequencyBonus = min(3.0, log2(Double(usage) + 1) * 0.70)
            return (item, Double(score) - frequencyBonus)
        }.sorted { $0.1 == $1.1 ? $0.0.title < $1.0.title : $0.1 < $1.1 }.map(\.0)
        if matches.isEmpty {
            displayedItems = [CommandItem(id: "web", title: "Search the web for “\(trimmed)”",
                subtitle: "", kind: .action, icon: "globe")]
            return
        }
        displayedItems = matches
    }

    func reload() {
        // See the matching comment in loadCatalog(): the embedded Shell's
        // ApplicationCatalogWatcher calls this on any filesystem touch
        // inside /Applications, including ones that have nothing to do with
        // an actual install or removal. Firing mid-interaction and always
        // resetting to row 0 was the confirmed cause of Return running the
        // topmost result instead of whatever the arrow keys had just
        // selected -- the background refresh silently discarded the
        // selection a moment before Return read it. Re-find the same item
        // by id instead, so a spurious refresh cannot outrun the user.
        let previousSelectedID = items.indices.contains(selected) ? items[selected].id : nil
        baseItems = catalogItems(includeSpotlight: false)
        rebuildDisplayedItems()
        selected = previousSelectedID.flatMap { id in items.firstIndex(where: { $0.id == id }) } ?? 0
        refreshMode()
    }

    func refreshMode() {
        guard !isRunning else { return }
        paletteRevision &+= 1
#if !MACPPCAST_EMBEDDED
#endif
        status = "WORK MODE  •  READY"
    }

    func move(_ delta: Int) {
        let count = items.count
        guard count > 0 else { return }
        selected = (selected + delta + count) % count
    }

    /// Single entry point for every arrow key, so the decision about which
    /// surface the keys currently belong to lives in exactly one place.
    func arrow(_ delta: Int) {
        if overlayPresented {
            onOverlayArrow?(delta)
        } else {
            move(delta)
        }
    }

    func executeSelected(hide: @escaping () -> Void, pullToCurrentSpace: Bool = false) {
        guard !isRunning else {
            status = "DOWNLOAD ALREADY RUNNING"
            return
        }
        if let item = pendingArgumentItem, let script = item.script {
            let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let argument = scriptArgument(for: script, query: trimmed) else {
                status = "PASTE A VALID LINK"
                requestSearchFocus()
                return
            }
            runProcess(script.path, [argument]) { [weak self] succeeded in
                guard let self else { return }
                if succeeded {
                    self.pendingArgumentItem = nil
                    self.query = ""
                    hide()
                } else {
                    self.requestSearchFocus()
                }
            }
            return
        }
        guard let item = selectedItemForExecution() else { return }
        execute(item, hide: hide, pullToCurrentSpace: pullToCurrentSpace)
    }

    /// Return must act on the result the user can actually see. Async window,
    /// clipboard, and AI searches replace the list while the text field keeps
    /// focus; during that handoff the old selected index can briefly be past
    /// the new array. The previous bounds-check silently discarded Return,
    /// which made an exact result look intermittently unclickable. Prefer the
    /// live selected row, then an exact title match from either the live or
    /// base catalog, and only then the first real row. Never execute a
    /// loading/empty placeholder. The base-catalog fallback closes the small
    /// synchronous window where query text has changed but SwiftUI is still
    /// diffing the filtered rows; typing an exact script name must not turn
    /// Return into a no-op during that handoff.
    private func selectedItemForExecution() -> CommandItem? {
        let current = items
        let normalizedQuery = searchKey(query.trimmingCharacters(in: .whitespacesAndNewlines))
        let key = searchKey
        let exactTitle: (CommandItem) -> Bool = {
            key($0.title) == normalizedQuery
        }
        let candidate: CommandItem?
        // A valid, real (non-transient) arrow-selected row is the explicit
        // keyboard intent and always wins first: an exact title match must
        // never pre-empt it, or Return would fire the topmost/exact result
        // no matter which row the arrow keys had highlighted -- the moment a
        // typed query exactly names an app that also has related scripts in
        // the results (e.g. "spotify" alongside a "Spotify ..." script), the
        // app would run even after arrowing down to the script. Only when
        // the selected row is transient (a stale/placeholder row, where the
        // previous logic already deferred to the catalog) or the index is
        // out of bounds -- both signs the visible selection isn't a real,
        // deliberate choice -- do we fall back to an exact-title match, and
        // only then to it closing the small synchronous window where query
        // text has changed but SwiftUI is still diffing the filtered rows.
        if current.indices.contains(selected) {
            let selectedItem = current[selected]
            let selectedIsTransient = selectedItem.id == "web" ||
                selectedItem.id == "windows:searching" ||
                selectedItem.id == "clipboard:searching" ||
                selectedItem.id == "ai-thinking"
            candidate = selectedIsTransient
                ? (current.first(where: exactTitle) ?? baseItems.first(where: exactTitle) ?? selectedItem)
                : selectedItem
        } else if !normalizedQuery.isEmpty,
                  let exact = current.first(where: exactTitle) ?? baseItems.first(where: exactTitle) {
            candidate = exact
        } else {
            candidate = current.first(where: exactTitle) ?? baseItems.first(where: exactTitle) ?? current.first
        }

        guard let item = candidate else {
            status = "NO RESULT  •  TYPE TO SEARCH"
            requestSearchFocus()
            return nil
        }
        if item.id == "windows:searching" || item.id == "clipboard:searching" || item.id == "ai-thinking" {
            status = "SEARCH STILL RUNNING  •  TRY RETURN AGAIN"
            requestSearchFocus()
            return nil
        }
        if item.id == "windows:empty" || item.id == "clipboard:empty" ||
            item.id.hasPrefix("picker:empty") || item.id.hasPrefix("picker:unavailable") {
            status = "NO MATCHING RESULT"
            requestSearchFocus()
            return nil
        }
        return item
    }

    /// Dispatch the row that was actually clicked. A result list can be
    /// rebuilt between SwiftUI rendering a row and delivering its click (for
    /// example when a catalog watcher finishes). Re-reading `selected` in
    /// that window can execute a different row or fail its bounds check.
    func executeSelected(
        item: CommandItem,
        hide: @escaping () -> Void,
        pullToCurrentSpace: Bool = false
    ) {
        guard !isRunning else {
            status = "DOWNLOAD ALREADY RUNNING"
            return
        }
        if pendingArgumentItem != nil {
            executeSelected(hide: hide, pullToCurrentSpace: pullToCurrentSpace)
            return
        }
        // The row passed into this closure is the row the user clicked. Do not
        // re-resolve it through `selected` or the live filtered array: a
        // catalog refresh can change that index between SwiftUI painting the
        // row and delivering the click, which used to turn a filtered toggle
        // into a no-op (or activate a different command). Only reject the
        // transient placeholders that are never actionable themselves.
        let isTransient = item.id == "web" ||
            item.id == "windows:searching" ||
            item.id == "clipboard:searching" ||
            item.id == "ai-thinking"
        if isTransient {
            guard let resolved = selectedItemForExecution() else { return }
            execute(resolved, hide: hide, pullToCurrentSpace: pullToCurrentSpace)
        } else {
            execute(item, hide: hide, pullToCurrentSpace: pullToCurrentSpace)
        }
    }

    private func execute(_ item: CommandItem, hide: @escaping () -> Void, pullToCurrentSpace: Bool = false) {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        if item.id == "clipboard:resume" || item.id == "clipboard:pause" {
            guard let clipboardHistory, clipboardQueryTerm != nil else { return }
            let enabled = item.id == "clipboard:resume"
            clipboardHistory.setCaptureEnabled(enabled)
            status = enabled ? "CLIPBOARD  •  CAPTURE ON" : "CLIPBOARD  •  PAUSED"
            renderClipboardResults(
                clipboardRenderedEntries,
                loading: false,
                preserving: nil
            )
            requestSearchFocus()
            return
        }
        if item.id == "clipboard:clear" {
            guard let clipboardHistory, let searchTerm = clipboardQueryTerm else { return }
            status = "CLEARING  •  CLIPBOARD"
            cancelClipboardSearch()
            clipboardHistory.clearAll { [weak self] succeeded in
                Task { @MainActor [weak self] in
                    guard let self, self.clipboardQueryTerm == searchTerm else { return }
                    self.clipboardRenderedEntries = []
                    self.status = succeeded ? "CLEARED  •  CLIPBOARD" : "CLIPBOARD CLEAR FAILED"
                    self.renderClipboardResults([], loading: false, preserving: nil)
                    self.requestSearchFocus()
                }
            }
            return
        }
        if let clipboardEntryID = item.clipboardEntryID {
            if clipboardHistory?.copyEntry(id: clipboardEntryID) == true {
                status = "COPIED  •  CLIPBOARD HISTORY"
                hide()
            } else {
                status = "CLIPBOARD COPY FAILED"
                requestSearchFocus()
            }
            return
        }
        if item.id == "clipboard:empty" || item.id == "clipboard:searching" ||
            item.id == "windows:empty" || item.id == "windows:searching" ||
            item.id == "ai-thinking" { return }
        if item.windowID != nil {
            guard item.windowPullable else {
                status = "WINDOW FOCUS UNAVAILABLE"
                requestSearchFocus()
                return
            }
            guard dispatchQuickAction(
                pullToCurrentSpace ? .pullWindow : .focusWindow,
                for: item,
                hide: hide
            ) else { return }
            return
        }
        if let copyValue = item.copyValue {
            NSPasteboard.general.clearContents()
            guard NSPasteboard.general.setString(copyValue, forType: .string) else {
                status = "COPY FAILED"
                requestSearchFocus()
                return
            }
            switch item.kind {
            case .emoji: status = "COPIED  •  EMOJI"
            case .symbol: status = "COPIED  •  SF SYMBOL"
            case .keybind: status = "COPIED  •  KEYBIND"
            default: status = "COPIED"
            }
            hide()
            return
        }
        if item.id.hasPrefix("picker:empty") || item.id.hasPrefix("picker:unavailable") { return }
#if MACPPCAST_EMBEDDED
        if item.id == "nexus" {
            recordUse(item.id)
            onOpenNexus?()
            return
        }
        if let rawDestination = item.id.split(separator: ":", maxSplits: 1).last,
           item.id.hasPrefix("nexus:"),
           let destination = MacPlusPlusNexusDestination(rawValue: String(rawDestination)) {
            recordUse(item.id)
            onOpenNexusPage?(destination)
            return
        }
        if item.id == "native:observatory" {
            recordUse(item.id)
            DistributedNotificationCenter.default().postNotificationName(
                Notification.Name("org.macplusplus.shell.show-observatory"),
                object: nil,
                userInfo: nil,
                deliverImmediately: true
            )
            return
        }
        if item.id == "native:wallpapers" {
            recordUse(item.id)
            presentWallpapers()
            return
        }
        if item.id == "native:desktop" {
            recordUse(item.id)
            presentDesktop()
            return
        }
#endif
        if item.id.hasPrefix("native:") { recordUse(item.id) }
        if item.id == "shell" {
            let command = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces)
            guard !command.isEmpty else { return }
            hide(); runProcess("/bin/zsh", ["-lc", command]); return
        }
        if item.id == "calc" {
            if let value = CalculatorEngine.evaluate(calculatorExpression(from: trimmed)) {
                NSPasteboard.general.clearContents(); NSPasteboard.general.setString(value, forType: .string)
                status = "COPIED  •  \(value)"; hide()
            }
            return
        }
        if item.id == "web" {
            var components = URLComponents(string: "https://www.google.com/search")!
            components.queryItems = [URLQueryItem(name: "q", value: trimmed)]
            if let url = components.url { NSWorkspace.shared.open(url) }
            hide(); return
        }
        switch item.id {
        case "native:clipboard-history":
            query = "clipboard "
            selected = 0
            status = clipboardHistory?.isCaptureEnabled == true
                ? "CLIPBOARD  •  CAPTURE ON"
                : "CLIPBOARD  •  PAUSED"
            requestSearchFocus()
            return
        case "native:keybind-cheatsheet":
            query = "keys "
            selected = 0
            status = "KEYBINDS  •  LIVE CONFIG"
            requestSearchFocus()
            return
        case "native:emoji-picker":
            query = "emoji "
            selected = 0
            status = "EMOJI  •  RETURN TO COPY"
            requestSearchFocus()
            return
        case "native:symbol-picker":
            query = "symbol "
            selected = 0
            status = "SF SYMBOLS  •  RETURN TO COPY"
            requestSearchFocus()
            return
        case "native:window-pull":
            query = "windows "
            selected = 0
            status = "WINDOWS  •  RETURN TO FOCUS  •  ⇧RETURN TO PULL"
            requestSearchFocus()
            return
        case "native:media-playpause", "native:media-previous", "native:media-next",
             "native:media-forward", "native:media-backward":
            let action = String(item.id.dropFirst("native:media-".count))
            hide()
            _ = MacPlusPlusMediaControl.launch(action)
            return
        case "native:volume-up", "native:volume-down":
            let delta = item.id == "native:volume-up" ? 6 : -6
            let script = """
            set currentVolume to output volume of (get volume settings)
            set nextVolume to currentVolume + (\(delta))
            if nextVolume < 0 then set nextVolume to 0
            if nextVolume > 100 then set nextVolume to 100
            set volume output volume nextVolume
            """
            hide()
            runProcess("/usr/bin/osascript", ["-e", script])
            return
        case "native:volume-mute":
            if dispatchQuickAction(.toggleOutputMute, for: item, hide: hide) {
                return
            }
            let script = "set volume output muted not (output muted of (get volume settings))"
            hide()
            runProcess("/usr/bin/osascript", ["-e", script])
            return
        case "native:focus-toggle":
            if dispatchQuickAction(.toggleFocus, for: item, hide: hide) {
                return
            }
            status = "FOCUS TOGGLE IS AVAILABLE FROM THE MAC++ SHELL"
            requestSearchFocus()
            return
        case "native:display-settings":
            hide()
            runProcess("/usr/bin/open", ["x-apple.systempreferences:com.apple.Displays-Settings.extension"])
            return
        case let id where id.hasPrefix("native:quick-"):
            let rawAction = String(id.dropFirst("native:quick-".count))
            guard let action = MacPlusPlusLauncherQuickAction(launcherIdentifier: rawAction) else {
                status = "ACTION UNAVAILABLE"
                requestSearchFocus()
                return
            }
            // Search and the matching Nexus control must cross one action
            // boundary. Dispatch before dismissing Search so the toggle cannot
            // be lost in a concurrent panel teardown, and make a missing host
            // callback visible instead of silently doing nothing.
            guard dispatchQuickAction(action, for: item, hide: hide) else { return }
            return
        case "native:screensaver:list":
            recordUse(item.id)
#if MACPPCAST_EMBEDDED
            presentScreensavers()
#else
            query = "list screen savers"
            selected = 0
            rebuildDisplayedItems()
            requestSearchFocus()
#endif
            return
        case "native:dropdown-terminal":
            let terminal = URL(fileURLWithPath: "/System/Applications/Utilities/Terminal.app")
            NSWorkspace.shared.openApplication(at: terminal, configuration: .init())
            hide()
            return
        case "native:color-picker":
            guard UserDefaults.standard.bool(forKey: "org.macplusplus.setup.screen-capture") else {
                status = "ENABLE SCREEN CAPTURE IN SETUP MANAGER"
                requestSearchFocus()
                return
            }
            hide()
            guard let helper = macppColorPickerURL() else {
                status = "COLOR PICKER HELPER IS NOT BUILT"
                requestSearchFocus()
                return
            }
            runProcess(helper.path, ["--apply"])
            return
        case "native:capture-area":
            guard UserDefaults.standard.bool(forKey: "org.macplusplus.setup.screen-capture") else {
                status = "ENABLE SCREEN CAPTURE IN SETUP MANAGER"
                requestSearchFocus()
                return
            }
            hide()
            runProcess("/usr/sbin/screencapture", ["-i"])
            return
        case "native:capture-window":
            guard UserDefaults.standard.bool(forKey: "org.macplusplus.setup.screen-capture") else {
                status = "ENABLE SCREEN CAPTURE IN SETUP MANAGER"
                requestSearchFocus()
                return
            }
            hide()
            runProcess("/usr/sbin/screencapture", ["-i", "-W"])
            return
        case "native:capture-tools":
            guard UserDefaults.standard.bool(forKey: "org.macplusplus.setup.screen-capture") else {
                status = "ENABLE SCREEN CAPTURE IN SETUP MANAGER"
                requestSearchFocus()
                return
            }
            let screenshotApp = URL(fileURLWithPath: "/System/Applications/Utilities/Screenshot.app")
            NSWorkspace.shared.openApplication(at: screenshotApp, configuration: .init())
            hide()
            return
        case "native:lock-screen":
            guard dispatchQuickAction(.lockScreen, for: item, hide: hide) else { return }
            return
        case "native:open-downloads":
            NSWorkspace.shared.open(FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Downloads", isDirectory: true))
            hide()
            return
        case "native:open-screenshots":
            let pictures = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Pictures", isDirectory: true)
                .appendingPathComponent("Screenshots", isDirectory: true)
            NSWorkspace.shared.open(pictures)
            hide()
            return
        case "native:wallpapers":
            let apps = [
                FileManager.default.homeDirectoryForCurrentUser
                    .appendingPathComponent("Applications/Mac++ Wallpaper.app", isDirectory: true),
                URL(fileURLWithPath: "/Applications/Mac++ Wallpaper.app", isDirectory: true)
            ]
            if let app = apps.first(where: { FileManager.default.fileExists(atPath: $0.path) }) {
                let configuration = NSWorkspace.OpenConfiguration()
                configuration.activates = true
                NSWorkspace.shared.openApplication(at: app, configuration: configuration) { _, _ in
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        DistributedNotificationCenter.default().postNotificationName(
                            Notification.Name("org.macplusplus.macpp-wallpaper.settings"),
                            object: nil,
                            userInfo: nil,
                            deliverImmediately: true
                        )
                    }
                }
            }
            hide()
            return
        default:
            break
        }
        if let url = item.url {
            recordUse(item.id)
            NSWorkspace.shared.openApplication(at: url, configuration: .init())
            hide()
            return
        }
        if let script = item.script {
            let argument = scriptArgument(for: script, query: trimmed)
            if script.argumentPlaceholder != nil && argument == nil && !script.argumentOptional {
                pendingArgumentItem = item
                query = ""
                selected = 0
                status = "PASTE LINK  •  RETURN TO START"
                requestSearchFocus()
                return
            }
            recordUse(item.id)
            hide()
            runProcess(script.path, argument.map { [$0] } ?? [])
            return
        }
    }

    @discardableResult
    private func dispatchQuickAction(
        _ action: MacPlusPlusLauncherQuickAction,
        for item: CommandItem,
        hide: @escaping () -> Void
    ) -> Bool {
        guard let handler = onPerformQuickAction else {
            status = "ACTION UNAVAILABLE  •  OPEN FROM MAC++ SHELL"
            requestSearchFocus()
            return false
        }
        recordUse(item.id)
        handler(action, item.windowID)
        hide()
        return true
    }

    private func macppColorPickerURL() -> URL? {
        let bundled = Bundle.main.resourceURL?.appendingPathComponent("macpp-color-picker")
        if let bundled, FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }
        let checkoutBuild = URL(fileURLWithPath: macppPath("build/macpp-color-picker"))
        return FileManager.default.isExecutableFile(atPath: checkoutBuild.path) ? checkoutBuild : nil
    }

    private func screensaverCommands() -> [CommandItem] {
        [CommandItem(
            id: "native:screensaver:list",
            title: "Screen Savers",
            subtitle: "Open the Shell’s local preview page",
            kind: .action,
            icon: "display",
            aliases: ["list screensavers", "list screen savers", "screen saver", "screensaver"]
        )]
    }

    private func nativeCommands() -> [CommandItem] {
        var commands = mediaControlCommands() + screensaverCommands() + embeddedQuickToggleCommands()
        commands += [
            CommandItem(
                id: "native:keybind-cheatsheet",
                title: "Keybind Cheatsheet",
                subtitle: "Search Mac++ shortcuts",
                kind: .action,
                icon: "keyboard"
            ),
            CommandItem(
                id: "native:emoji-picker",
                title: "Emoji Picker",
                subtitle: "Search emoji and copy with Return",
                kind: .action,
                icon: "face.smiling"
            ),
            CommandItem(
                id: "native:symbol-picker",
                title: "SF Symbol Picker",
                subtitle: "Search SF Symbols",
                kind: .action,
                icon: "square.grid.3x3"
            ),
            CommandItem(
                id: "native:window-pull",
                title: "Window Pull",
                subtitle: "Search open windows  •  ⇧RETURN pulls to this space",
                kind: .action,
                icon: "macwindow.on.rectangle"
            ),
            CommandItem(
                id: "native:dropdown-terminal",
                title: "Drop-down Terminal",
                subtitle: "",
                kind: .action,
                icon: "rectangle.topthird.inset.filled"
            ),
            CommandItem(
                id: "native:color-picker",
                title: "Pick Colour",
                subtitle: "Freeze the display and add a pixel to the palette",
                kind: .action,
                icon: "eyedropper"
            ),
            CommandItem(
                id: "native:capture-area",
                title: "Capture Area",
                subtitle: "Select an area to capture  •  ⇧⌘4",
                kind: .action,
                icon: "viewfinder"
            ),
            CommandItem(
                id: "native:capture-window",
                title: "Capture Window",
                subtitle: "",
                kind: .action,
                icon: "macwindow"
            ),
            CommandItem(
                id: "native:capture-tools",
                title: "Screenshot & Recording",
                subtitle: "Open the macOS capture toolbar  •  ⇧⌘5",
                kind: .action,
                icon: "camera.viewfinder"
            ),
            CommandItem(
                id: "native:lock-screen",
                title: "Lock Screen",
                subtitle: "",
                kind: .action,
                icon: "lock"
            ),
            CommandItem(
                id: "native:open-downloads",
                title: "Open Downloads",
                subtitle: "",
                kind: .action,
                icon: "arrow.down.circle"
            ),
            CommandItem(
                id: "native:open-screenshots",
                title: "Open Screenshots",
                subtitle: "",
                kind: .action,
                icon: "photo.on.rectangle"
            ),
            CommandItem(
                id: "native:wallpapers",
                title: "Wallpapers",
                subtitle: "",
                kind: .action,
                icon: "photo.stack"
            ),
            CommandItem(
                id: "native:desktop",
                title: "Visualiser",
                subtitle: "",
                kind: .action,
                icon: "waveform.path"
            ),
        ]
        return commands
    }

    private func embeddedQuickToggleCommands() -> [CommandItem] {
#if MACPPCAST_EMBEDDED
        // Both shells expose the same action slot. The parity shell presents
        // it as a transient app shelf; the original shell keeps its legacy
        // dock wording and behavior.
#if MACPP_CAELESTIA_SHELL
        let customDockCommand: CommandItem? = CommandItem(
            id: "native:quick-toggle-app-dock",
            title: "Toggle App Shelf",
            subtitle: "Show running apps at the bottom edge",
            kind: .action,
            icon: "rectangle.stack",
            aliases: [
                "app shelf", "active apps", "running apps", "open apps", "app dock",
                "show app shelf", "hide app shelf", "toggle app shelf"
            ]
        )
#else
        let customDockCommand: CommandItem? = CommandItem(
            id: "native:quick-toggle-app-dock",
            title: "Toggle Custom Dock",
            subtitle: "",
            kind: .action,
            icon: "rectangle.stack",
            aliases: [
                "custom dock", "app dock", "shell dock", "dock icons", "running apps", "open apps",
                "hide custom dock", "show custom dock", "hide app dock", "show app dock"
            ]
        )
#endif
        var commands = [
            CommandItem(
                id: "native:quick-toggle-microphone",
                title: "Toggle Microphone",
                subtitle: "",
                kind: .action,
                icon: "mic.fill",
                aliases: ["mic", "microphone", "mute mic", "unmute mic", "input mute"]
            ),
            CommandItem(
                id: "native:quick-toggle-wifi",
                title: "Toggle Wi-Fi",
                subtitle: "",
                kind: .action,
                icon: "wifi",
                aliases: ["wifi", "wireless", "internet", "network"]
            ),
            CommandItem(
                id: "native:quick-toggle-vpn",
                title: "Toggle VPN",
                subtitle: "",
                kind: .action,
                icon: "lock.shield",
                aliases: ["vpn", "private network", "tunnel"]
            ),
            CommandItem(
                id: "native:quick-toggle-desktop-layer",
                title: "Toggle Wallpaper Layer",
                subtitle: "Clock + visualizer layer",
                kind: .action,
                icon: "square.3.layers.3d",
                aliases: ["wallpaper layer", "desktop layer", "hud layer"]
            ),
            CommandItem(
                id: "native:quick-toggle-center-clock",
                title: "Toggle Center Clock",
                subtitle: "",
                kind: .action,
                icon: "clock",
                aliases: ["clock", "desktop clock", "center time"]
            ),
            CommandItem(
                id: "native:quick-toggle-visualizer",
                title: "Toggle Visualizer",
                subtitle: "Audio-reactive",
                kind: .action,
                icon: "waveform.path.ecg",
                aliases: ["visualizer", "audio visualizer", "spectrum", "audio bars"]
            )
        ]
        commands += [
            CommandItem(
                id: "native:quick-toggle-shell-border",
                title: "Toggle Shell Border",
                subtitle: "",
                kind: .action,
                icon: "rectangle.inset.filled",
                aliases: ["border", "frame border", "shell frame"]
            ),
            CommandItem(
                id: "native:quick-toggle-menu-mask",
                title: "Toggle Menu + Dock",
                subtitle: "",
                kind: .action,
                icon: "menubar.rectangle",
                aliases: ["menu bar", "menubar", "dock", "system chrome", "notch mask", "menu mask"]
            )
        ]
        return commands + (customDockCommand.map { [$0] } ?? [])
#else
        return []
#endif
    }

    private func mediaControlCommands() -> [CommandItem] {
        [
            CommandItem(
                id: "native:media-playpause",
                title: "Play / Pause Media",
                subtitle: "",
                kind: .action,
                icon: "playpause.fill",
                aliases: ["play", "pause", "toggle media", "now playing"]
            ),
            CommandItem(
                id: "native:media-previous",
                title: "Previous Track",
                subtitle: "",
                kind: .action,
                icon: "backward.end.fill",
                aliases: ["previous", "back", "skip back"]
            ),
            CommandItem(
                id: "native:media-next",
                title: "Next Track",
                subtitle: "",
                kind: .action,
                icon: "forward.end.fill",
                aliases: ["next", "skip", "skip forward"]
            ),
            CommandItem(
                id: "native:media-backward",
                title: "Seek Back 15 Seconds",
                subtitle: "",
                kind: .action,
                icon: "gobackward.15",
                aliases: ["rewind", "back 15", "seek backward"]
            ),
            CommandItem(
                id: "native:media-forward",
                title: "Seek Forward 15 Seconds",
                subtitle: "",
                kind: .action,
                icon: "goforward.15",
                aliases: ["fast forward", "forward 15", "seek forward"]
            ),
            CommandItem(
                id: "native:volume-up",
                title: "Volume Up",
                subtitle: "Raise output volume by 6 percent",
                kind: .action,
                icon: "speaker.plus",
                aliases: ["louder", "increase volume"]
            ),
            CommandItem(
                id: "native:volume-down",
                title: "Volume Down",
                subtitle: "Lower output volume by 6 percent",
                kind: .action,
                icon: "speaker.minus",
                aliases: ["quieter", "decrease volume"]
            ),
            CommandItem(
                id: "native:volume-mute",
                title: "Mute Output",
                subtitle: "",
                kind: .action,
                icon: "speaker.slash",
                aliases: ["mute", "unmute", "sound off"]
            ),
            CommandItem(
                id: "native:focus-toggle",
                title: "Toggle Focus",
                subtitle: "Do Not Disturb via Focus",
                kind: .action,
                icon: "moon",
                aliases: ["do not disturb", "dnd", "focus mode"]
            ),
            CommandItem(
                id: "native:display-settings",
                title: "Display Settings",
                subtitle: "",
                kind: .action,
                icon: "display.2",
                aliases: ["monitors", "screens", "brightness", "display"]
            )
        ]
    }

    private func nexusItem(destination: MacPlusPlusNexusDestination) -> CommandItem {
        let title: String
        let subtitle: String
        let icon: String
        switch destination {
        case .overview:
            title = "Nexus"
            subtitle = ""
            icon = "square.grid.2x2"
        case .media:
            title = "Nexus Media"
            subtitle = ""
            icon = "quote.bubble"
        case .audio:
            title = "Nexus Audio Lab"
            subtitle = ""
            icon = "speaker.wave.2"
        case .system:
            title = "Nexus System"
            subtitle = ""
            icon = "gearshape.2"
        case .capture:
            title = "Nexus Tools"
            subtitle = ""
            icon = "record.circle"
        case .settings:
            title = "Nexus Settings"
            subtitle = ""
            icon = "slider.horizontal.3"
        case .observatory:
            title = "Nexus Observatory"
            subtitle = "Inspect runtime health and live transports"
            icon = "scope"
        }
        return CommandItem(
            id: destination == .overview ? "nexus" : "nexus:\(destination.rawValue)",
            title: title,
            subtitle: subtitle,
            kind: .action,
            icon: icon,
            aliases: ["control center", "nexus \(destination.rawValue)"]
        )
    }

    private var nexusItem: CommandItem { nexusItem(destination: .overview) }

    private var clipboardQueryTerm: String? {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.caseInsensitiveCompare("clipboard") == .orderedSame { return "" }
        guard trimmed.lowercased().hasPrefix("clipboard ") else { return nil }
        return String(trimmed.dropFirst("clipboard ".count))
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func renderPickerResults(_ pickerQuery: MacPlusPlusPickerQuery) {
        switch pickerQuery.namespace {
        case .keybinds:
            let root = URL(fileURLWithPath: macppRoot, isDirectory: true)
            let load = MacPlusPlusKeybindParser.load(sources: MacPlusPlusKeybindParser.productionSources(repositoryRoot: root))
            let matches = MacPlusPlusKeybindParser.search(load.keybinds, query: pickerQuery.term)
            if matches.isEmpty {
                displayedItems = []
            } else {
                displayedItems = matches.map { binding in
                    CommandItem(
                        id: "keybind:\(binding.id)",
                        title: binding.summary,
                        subtitle: "\(binding.displayChord)  •  \(binding.scope.rawValue)  •  \(binding.section.uppercased())  •  RETURN TO COPY",
                        kind: .keybind,
                        icon: "keyboard",
                        copyValue: binding.displayChord
                    )
                }
            }
        case .emoji:
            guard let pickerCatalog else {
                displayedItems = []
                selected = 0
                return
            }
            let matches = pickerCatalog.searchEmoji(pickerQuery.term)
            displayedItems = matches.map { entry in
                    CommandItem(
                        id: "emoji:\(entry.value)",
                        title: entry.name,
                        subtitle: "EMOJI  •  RETURN TO COPY",
                        kind: .emoji,
                        icon: "face.smiling",
                        copyValue: entry.value,
                        displayValue: entry.value
                    )
                }
        case .symbols:
            guard let pickerCatalog else {
                displayedItems = []
                selected = 0
                return
            }
            let matches = pickerCatalog.searchSymbols(pickerQuery.term)
            displayedItems = matches.map { entry in
                    CommandItem(
                        id: "symbol:\(entry.value)",
                        title: entry.value,
                        subtitle: "\(entry.name.uppercased())  •  RETURN TO COPY",
                        kind: .symbol,
                        icon: entry.value,
                        copyValue: entry.value
                    )
                }
        }
        selected = 0
    }

    private func scheduleClipboardSearch(
        _ searchTerm: String,
        showLoading: Bool,
        preserving selectedID: Int64? = nil
    ) {
        guard let clipboardHistory else { return }
        clipboardSearchTask?.cancel()
        let generation = clipboardSearchGeneration.advance()
        if showLoading {
            renderClipboardResults([], loading: true, preserving: selectedID)
        }
        clipboardSearchTask = Task { @MainActor [weak self, weak clipboardHistory] in
            // macpp:silent-ok cancellation is the normal debounce path
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard !Task.isCancelled, let self, let clipboardHistory,
                  self.clipboardSearchGeneration.accepts(generation),
                  self.clipboardQueryTerm == searchTerm else { return }
            clipboardHistory.search(searchTerm) { [weak self] entries in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.clipboardSearchGeneration.accepts(generation),
                          self.clipboardQueryTerm == searchTerm else { return }
                    self.clipboardRenderedEntries = entries
                    self.renderClipboardResults(
                        entries,
                        loading: false,
                        preserving: selectedID
                    )
                }
            }
            self.clipboardSearchTask = nil
        }
    }

    private func cancelClipboardSearch() {
        clipboardSearchTask?.cancel()
        clipboardSearchTask = nil
        _ = clipboardSearchGeneration.advance()
        clipboardRenderedEntries = []
    }

    private func scheduleWindowSearch(_ windowQuery: MacPlusPlusWindowQuery) {
        windowSearchTask?.cancel()
        windowSearchGeneration &+= 1
        let generation = windowSearchGeneration
        displayedItems = []
        selected = 0
        windowSearchTask = Task { @MainActor [weak self] in
            // A short debounce keeps a yabai query off the hot path while a
            // user types a window title. The query itself runs off-main so a
            // slow accessibility response cannot introduce scroll lag.
            // macpp:silent-ok cancellation is the normal debounce path
            try? await Task.sleep(nanoseconds: 110_000_000)
            guard !Task.isCancelled else { return }
            let values = await Task.detached(priority: .utility) {
                MacPlusPlusWindowCatalog.search(windowQuery)
            }.value
            guard !Task.isCancelled,
                  let self, self.windowSearchGeneration == generation,
                  MacPlusPlusWindowQuery.parse(self.query)?.term == windowQuery.term else { return }
            if values.isEmpty {
                self.displayedItems = []
            } else {
                self.displayedItems = values.map { window in
                    CommandItem(
                        id: "window:\(window.id)",
                        title: window.title.isEmpty ? window.app : window.title,
                        subtitle: "\(window.app)  •  SPACE \(window.space)  •  \(window.canMove ? "RETURN FOCUS  •  ⇧RETURN PULL" : "FOCUS UNAVAILABLE")",
                        kind: .window,
                        icon: "macwindow.on.rectangle",
                        windowID: window.id,
                        windowPullable: window.canMove
                    )
                }
            }
            self.selected = 0
            self.windowSearchTask = nil
        }
    }

    private func cancelWindowSearch() {
        windowSearchTask?.cancel()
        windowSearchTask = nil
        windowSearchGeneration &+= 1
    }

    private func renderClipboardResults(
        _ entries: [MacPlusPlusClipboardEntry],
        loading: Bool,
        preserving selectedID: Int64?
    ) {
        guard let clipboardHistory else { return }
        var results = clipboardControlItems(captureEnabled: clipboardHistory.isCaptureEnabled)
        if !loading && !entries.isEmpty {
            results.append(contentsOf: entries.map(clipboardItem))
        }
        displayedItems = results
        if let selectedID,
           let index = results.firstIndex(where: { $0.clipboardEntryID == selectedID }) {
            selected = index
        } else {
            selected = 0
        }
    }

    private func clipboardControlItems(captureEnabled: Bool) -> [CommandItem] {
        [
            CommandItem(
                id: captureEnabled ? "clipboard:pause" : "clipboard:resume",
                title: captureEnabled ? "Pause Capture" : "Resume Capture",
                subtitle: captureEnabled
                    ? "Saving new clips"
                    : "Ordinary clipboard text may be saved for 30 days",
                kind: .action,
                icon: captureEnabled ? "pause" : "play"
            ),
            CommandItem(
                id: "clipboard:clear",
                title: "Clear History",
                subtitle: "Remove saved clips and pause",
                kind: .action,
                icon: "trash"
            )
        ]
    }

    private func clipboardItem(_ entry: MacPlusPlusClipboardEntry) -> CommandItem {
        let age = Self.clipboardAge(entry.createdAt)
        let size = ByteCountFormatter.string(fromByteCount: Int64(entry.byteCount), countStyle: .file)
        let pinAction = entry.isPinned ? "⌘P TO UNPIN" : "⌘P TO PIN"
        let subtitle = [entry.isPinned ? "PINNED" : nil, age, size, pinAction]
            .compactMap { $0 }
            .joined(separator: "  •  ")
        return CommandItem(
            id: "clipboard:\(entry.id)",
            title: entry.summary,
            subtitle: subtitle,
            kind: .clipboard,
            icon: entry.kind == .image ? "photo" : "doc.text",
            clipboardEntryID: entry.id,
            clipboardPinned: entry.isPinned,
            clipboardThumbnail: entry.thumbnail
        )
    }

    private static func clipboardAge(_ date: Date, now: Date = Date()) -> String {
        let seconds = max(0, Int(now.timeIntervalSince(date)))
        if seconds < 60 { return "NOW" }
        if seconds < 3_600 { return "\(seconds / 60)M AGO" }
        if seconds < 86_400 { return "\(seconds / 3_600)H AGO" }
        return "\(seconds / 86_400)D AGO"
    }

    @discardableResult
    func toggleSelectedClipboardPin() -> Bool {
        guard items.indices.contains(selected),
              let id = items[selected].clipboardEntryID else { return false }
        let wasPinned = items[selected].clipboardPinned
        guard clipboardHistory?.setPinned(!wasPinned, id: id) == true else {
            status = "CLIPBOARD PIN LIMIT REACHED"
            return true
        }
        status = wasPinned ? "UNPINNED  •  CLIPBOARD" : "PINNED  •  CLIPBOARD"
        if let searchTerm = clipboardQueryTerm {
            scheduleClipboardSearch(searchTerm, showLoading: false, preserving: id)
        }
        return true
    }

    private func commandUsage(_ id: String) -> Int {
        let values = UserDefaults.standard.dictionary(forKey: usageDefaultsKey) ?? [:]
        return (values[id] as? NSNumber)?.intValue ?? 0
    }

    private func recordUse(_ id: String) {
        var values = UserDefaults.standard.dictionary(forKey: usageDefaultsKey) ?? [:]
        let count = (values[id] as? NSNumber)?.intValue ?? 0
        values[id] = NSNumber(value: min(1_000_000, count + 1))
        UserDefaults.standard.set(values, forKey: usageDefaultsKey)
    }

    func cancelArgumentEntry() {
        guard pendingArgumentItem != nil else { return }
        pendingArgumentItem = nil
        query = ""
        selected = 0
        status = "WORK MODE  •  READY"
        requestSearchFocus()
    }

    func pasteArgument() {
        guard pendingArgumentItem != nil,
              let value = NSPasteboard.general.string(forType: .string) else { return }
        query = value.trimmingCharacters(in: .whitespacesAndNewlines)
        requestSearchFocus()
    }

    /// Raycast removes a Script Command's title before passing its argument.
    /// MacPlusPlusCast searches title, description, and arguments in one field, so do
    /// the equivalent split here. Prefer an embedded URL for URL-based commands
    /// so aliases such as `yt dlp https://…` also produce a clean argument.
    private func scriptArgument(for script: ScriptCommand, query: String) -> String? {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !value.isEmpty else { return nil }

        if script.argumentPlaceholder?.localizedCaseInsensitiveContains("url") == true {
            guard let match = value.range(
                of: #"https?://\S+"#,
                options: [.regularExpression, .caseInsensitive]
            ) else { return nil }
            return String(value[match])
        }

        if value.caseInsensitiveCompare(script.title) == .orderedSame { return nil }
        if value.lowercased().hasPrefix(script.title.lowercased()) {
            let end = value.index(value.startIndex, offsetBy: script.title.count)
            let remainder = value[end...].trimmingCharacters(in: .whitespacesAndNewlines)
            return remainder.isEmpty ? nil : remainder
        }
        return value
    }

    private func runProcess(
        _ path: String,
        _ arguments: [String],
        completion: ((Bool) -> Void)? = nil
    ) {
        isRunning = true; status = "RUNNING  •  \((path as NSString).lastPathComponent.uppercased())"
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process(); process.executableURL = URL(fileURLWithPath: path); process.arguments = arguments
            let output = Pipe()
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            var launchError: Error?
            do { try process.run() } catch { launchError = error }
            let outputData: Data
            if launchError == nil {
                // Drain while the command runs so verbose Script Commands can
                // never fill the pipe and stall MacPlusPlusCast.
                outputData = output.fileHandleForReading.readDataToEndOfFile()
                process.waitUntilExit()
            } else {
                outputData = Data()
            }
            let processOutput = String(data: outputData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            DispatchQueue.main.async {
                self.isRunning = false
                if launchError == nil, process.terminationStatus == 0 {
                    self.refreshMode()
                    // Reconcile the palette/mode first, then keep the outcome
                    // visible. refreshMode() also publishes a generic READY
                    // label, which used to erase DONE before SwiftUI could
                    // render a single frame of it.
                    self.status = "DONE  •  \((path as NSString).lastPathComponent.uppercased())"
                    completion?(true)
                } else {
                    let detail = launchError?.localizedDescription
                        ?? processOutput.split(separator: "\n").last.map(String.init)
                        ?? "EXIT \(process.terminationStatus)"
                    // The persisted mode state remains authoritative if a
                    // transition completes before all follow-up actions report
                    // success. Reconcile before publishing the final status.
                    self.refreshMode()
                    // Publish the actionable failure after reconciliation so
                    // it remains on screen instead of flashing back to READY.
                    self.status = "FAILED  •  \(detail.prefix(72))"
                    completion?(false)
                }
            }
        }
    }

    private func runCapturedProcess(
        _ path: String,
        _ arguments: [String],
        completion: @escaping (String, Bool) -> Void
    ) {
        DispatchQueue.global(qos: .userInitiated).async {
            let process = Process()
            let output = Pipe()
            process.executableURL = URL(fileURLWithPath: path)
            process.arguments = arguments
            process.standardOutput = output
            process.standardError = output
            var environment = ProcessInfo.processInfo.environment
            environment["PATH"] = "\(NSHomeDirectory())/.local/bin:/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
            process.environment = environment
            var launchError: Error?
            do { try process.run() } catch { launchError = error }
            let data = launchError == nil ? output.fileHandleForReading.readDataToEndOfFile() : Data()
            if launchError == nil { process.waitUntilExit() }
            let text = launchError?.localizedDescription
                ?? String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? ""
            DispatchQueue.main.async {
                completion(text, launchError == nil && process.terminationStatus == 0)
            }
        }
    }

    private func calculatorExpression(from query: String) -> String {
        let value = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return value.hasPrefix("=")
            ? String(value.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
            : value
    }

    private func discoverApps(includeSpotlight: Bool = true) -> [CommandItem] {
        let roots = [
            "/Applications", "/System/Applications", "/System/Library/CoreServices",
            "/System/Cryptexes/App/System/Applications", NSHomeDirectory() + "/Applications"
        ]
        var found: [String: URL] = [:]
        let legacyAppleApps: Set<String> = [
            "Boot Camp Assistant", "Expansion Slot Utility", "Memory Slot Utility"
        ]
        func isUserFacingAndCompatible(_ url: URL) -> Bool {
            let path = url.standardizedFileURL.path
            let resolvedURL = url.resolvingSymlinksInPath()
            let home = NSHomeDirectory()
            let allowedLocation = path.hasPrefix("/Applications/")
                || path.hasPrefix(home + "/Applications/")
                || path.hasPrefix("/System/Applications/")
                || path.hasPrefix("/System/Library/CoreServices/Applications/")
                || path == "/System/Library/CoreServices/Finder.app"
                || path.hasPrefix("/Volumes/")
            guard allowedLocation,
                  let bundle = Bundle(url: resolvedURL),
                  let info = bundle.infoDictionary,
                  info["LSBackgroundOnly"] as? Bool != true,
                  info["CFBundlePackageType"] as? String != "BNDL",
                  !legacyAppleApps.contains(url.deletingPathExtension().lastPathComponent) else { return false }

            let bundleID = (info["CFBundleIdentifier"] as? String)?.lowercased() ?? ""
            let parent = url.deletingLastPathComponent().standardizedFileURL.path
            let isUserCuratedMenuUtility = parent == "/Applications"
                || path.hasPrefix("/Applications/")
                || parent == home + "/Applications"
            let isLaunchableMenuUtility = bundleID != "org.macplusplus.search"
                && isUserCuratedMenuUtility
            if info["LSUIElement"] as? Bool == true && !isLaunchableMenuUtility { return false }

            if let architectures = bundle.executableArchitectures, !architectures.isEmpty,
               !architectures.contains(NSNumber(value: NSBundleExecutableArchitectureARM64)),
               !architectures.contains(NSNumber(value: NSBundleExecutableArchitectureX86_64)) { return false }

            let hasIconMetadata = info["CFBundleIconFile"] != nil
                || info["CFBundleIconName"] != nil
                || info["CFBundleIcons"] != nil
                || ((try? FileManager.default.contentsOfDirectory(atPath: resolvedURL.appendingPathComponent("Contents/Resources").path))?
                    .contains(where: { $0.lowercased().hasSuffix(".icns") }) ?? false)
            return hasIconMetadata
        }
        func include(_ url: URL) {
            guard url.pathExtension.lowercased() == "app",
                  FileManager.default.fileExists(atPath: url.path),
                  !url.path.contains(".app/Contents/"),
                  isUserFacingAndCompatible(url) else { return }
            let name = url.deletingPathExtension().lastPathComponent
            let key = name.lowercased()
            if found[key] == nil || url.path.hasPrefix("/Applications/") { found[key] = url }
        }
        func scan(_ directory: URL) {
            guard let children = try? FileManager.default.contentsOfDirectory(
                at: directory,
                includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                // Safari is installed through the system Cryptex and appears
                // at /Applications/Safari.app as a symlink carrying the
                // hidden filesystem flag.  Do not let that implementation
                // detail remove a user-facing application from Search.  Skip
                // hidden folders explicitly so this does not turn the walk
                // into a traversal of unrelated dot-directories.
                options: []
            ) else { return }
            for child in children {
                if child.lastPathComponent.hasPrefix("."), child.pathExtension.lowercased() != "app" {
                    continue
                }
                if child.pathExtension.lowercased() == "app" {
                    include(child)
                    continue // Never descend into an application bundle.
                }
                if (try? child.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true {
                    scan(child) // Ordinary folders inside Applications are intentional collections.
                }
            }
        }
        for root in roots {
            scan(URL(fileURLWithPath: root))
        }
        // Spotlight supplies registered apps outside the standard roots (Caskroom,
        // game launchers, development builds, and other user-selected locations).
        if includeSpotlight {
            let spotlight = Process()
            let pipe = Pipe()
            spotlight.executableURL = URL(fileURLWithPath: "/usr/bin/mdfind")
            spotlight.arguments = ["kMDItemContentType == 'com.apple.application-bundle'"]
            spotlight.standardOutput = pipe
            spotlight.standardError = FileHandle.nullDevice
            if (try? spotlight.run()) != nil {
                spotlight.waitUntilExit()
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let paths = String(data: data, encoding: .utf8) {
                    for path in paths.split(separator: "\n") { include(URL(fileURLWithPath: String(path))) }
                }
            }
        }
        return found.map { _, url in
            let name = url.deletingPathExtension().lastPathComponent
            return CommandItem(
                id: "app:\(url.path)",
                title: name,
                subtitle: "Launch application",
                kind: .app,
                icon: "app.dashed",
                url: url,
                aliases: appAliases(for: name)
            )
        }
    }

    private func appAliases(for name: String) -> [String] {
        switch searchKey(name) {
        case "spotify": return ["music", "player", "media", "audio"]
        case "safari": return ["browser", "web", "internet"]
        case "discord": return ["chat", "voice", "community"]
        case "finder": return ["files", "documents"]
        case "system settings": return ["settings", "preferences", "system"]
        default: return []
        }
    }

    private func discoverScripts() -> [ScriptCommand] {
        []
    }
}

private struct LauncherResultsList: View {
    @ObservedObject var model: LauncherModel
    let hide: () -> Void
    let selectionNamespace: Namespace.ID
    private let listTopID = "launcher-results-top"

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView(.vertical) {
                LazyVStack(spacing: 4) {
                    Color.clear
                        .frame(height: 1)
                        .id(listTopID)
                    ForEach(model.items.indices, id: \.self) { index in
                        resultButton(index: index, item: model.items[index])
                    }
                }
                .padding(.horizontal, 22)
                .padding(.vertical, 10)
            }
            .scrollIndicators(.hidden)
            .onChange(of: model.query) { _, _ in scrollToTop(proxy) }
            .onChange(of: model.selected) { _, index in
                guard model.items.indices.contains(index) else { return }
                withAnimation(.easeOut(duration: 0.12)) {
                    proxy.scrollTo(model.items[index].id, anchor: .center)
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func resultButton(index: Int, item: CommandItem) -> some View {
        Button {
            model.selected = index
            model.executeSelected(item: item, hide: hide)
        } label: {
            ResultRow(
                item: item,
                active: index == model.selected,
                selectionNamespace: selectionNamespace,
                paletteRevision: model.paletteRevision
            )
        }
        .buttonStyle(CastButtonStyle())
        // Make replacement rows disappear atomically. Otherwise a one-result
        // query can remain composited over the newly restored catalog while
        // the panel is resizing.
        .transition(.identity)
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(item.title)
        .accessibilityHint(item.subtitle.isEmpty ? "Activate" : item.subtitle)
        // Button supplies the native macOS button role; retain it explicitly
        // after collapsing the visual children into one accessible element.
        .accessibilityAddTraits(.isButton)
        .id(item.id)
        // The panel/window still supplies the spatial motion for the resize;
        // rows themselves are deliberately not animated through the swap.
    }

    private func scrollToTop(_ proxy: ScrollViewProxy) {
        guard !model.items.isEmpty else { return }
        var transaction = Transaction()
        transaction.disablesAnimations = true
        withTransaction(transaction) { proxy.scrollTo(listTopID, anchor: .top) }
    }
}

#if MACPPCAST_EMBEDDED
// Keep the three optional, type-erased auxiliary surfaces out of LauncherView's
// already large result-builder expression. Besides making the layout easier to
// reason about, this gives Swift's type checker a small, stable subtree for the
// Nexus transition instead of asking it to infer the entire launcher at once.
private struct LauncherEmbeddedAuxiliarySurfaces: View {
    @ObservedObject var model: LauncherModel
    let nexusContent: (() -> AnyView)?
    let wallpaperContent: (() -> AnyView)?
    let desktopContent: (() -> AnyView)?
    let screensaverContent: (() -> AnyView)?
    let phase: CGFloat
    let opacity: Double

    var body: some View {
        ZStack(alignment: .bottom) {
            if model.nexusPresented, let provider = nexusContent {
                provider()
                    .frame(width: nexusWidth, height: nexusHeight, alignment: .topLeading)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(opacity)
                    .scaleEffect(0.984 + (0.016 * phase), anchor: .bottom)
                    .offset(y: 8 * (1 - phase))
                    .allowsHitTesting(phase >= 0.98 && !model.nexusTransitioning)
            }
            if model.wallpapersPresented, let provider = wallpaperContent {
                provider()
                    .frame(
                        width: wallpaperWidth,
                        height: model.wallpaperEditorPresented
                            ? LauncherModel.wallpaperEditorHeight
                            : LauncherModel.wallpaperCarouselHeight,
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(opacity)
                    .scaleEffect(0.984 + (0.016 * phase), anchor: .bottom)
                    .offset(y: 8 * (1 - phase))
                    .allowsHitTesting(phase >= 0.98 && !model.nexusTransitioning)
            }
            if model.desktopPresented, let provider = desktopContent {
                provider()
                    .frame(
                        width: wallpaperWidth,
                        height: LauncherModel.wallpaperCarouselHeight,
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(opacity)
                    .scaleEffect(0.984 + (0.016 * phase), anchor: .bottom)
                    .offset(y: 8 * (1 - phase))
                    .allowsHitTesting(phase >= 0.98 && !model.nexusTransitioning)
            }
            if model.screensaversPresented, let provider = screensaverContent {
                provider()
                    .frame(
                        width: wallpaperWidth,
                        height: LauncherModel.screensaverCarouselHeight,
                        alignment: .topLeading
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
                    .opacity(opacity)
                    .scaleEffect(0.984 + (0.016 * phase), anchor: .bottom)
                    .offset(y: 8 * (1 - phase))
                    .allowsHitTesting(phase >= 0.98 && !model.nexusTransitioning)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
    }
}
#endif

struct LauncherView: View {
    private enum FocusTarget: Hashable {
        case search
        case overlay
    }

    @ObservedObject var model: LauncherModel
    @ObservedObject var motion: LauncherMotionState
    let hide: () -> Void
#if MACPPCAST_EMBEDDED
    @ObservedObject var shellBorderPresentation: ShellBorderPresentation
#endif
    // With more than one physical display the launcher owns its surface.
    // Rendering that surface in Mac++ Shell's all-Spaces frame window makes
    // WindowServer project an empty copy onto Sidecar, even though the real
    // launcher window is correctly placed on the built-in display.
    var paintsEmbeddedSurface = false
    var nexusContent: (() -> AnyView)? = nil
    var wallpaperContent: (() -> AnyView)? = nil
    var desktopContent: (() -> AnyView)? = nil
    var screensaverContent: (() -> AnyView)? = nil
    @FocusState private var focusTarget: FocusTarget?
    @Namespace private var selectionHighlight

    private var surfaceContentOpacity: Double {
#if MACPPCAST_EMBEDDED
#if MACPP_CAELESTIA_SHELL
        // The contour owns the reveal. During dismissal, fade the local
        // launcher host out before its contracting path reaches a subpixel
        // terminal cap; the shared shell rim is already visible underneath.
        guard !motion.presented else { return 1 }
        let progress = presentationProgress
        guard progress > 0.08 else { return 0 }
        return Double(min(1, max(0, (progress - 0.08) / 0.16)))
#else
        min(1, max(0, (motion.progress - 0.56) / 0.30))
#endif
#else
        1
#endif
    }

    private var nexusPhase: CGFloat {
        min(1, max(0, model.nexusMorphProgress))
    }

    private var presentationProgress: CGFloat {
#if MACPPCAST_EMBEDDED
#if MACPP_CAELESTIA_SHELL
        min(1, max(0, motion.contourProgress))
#else
        min(1, max(0, motion.progress))
#endif
#else
        min(1, max(0, motion.progress))
#endif
    }

    private var surfaceWidth: CGFloat {
#if MACPPCAST_EMBEDDED
        // Search starts at the 600pt shell launcher width. Nexus owns a wider
        // destination surface, and the wallpaper strip uses that same broad
        // envelope while retaining its shallow content height. Both follow
        // the same display-linked morph phase as the AppKit host so the right
        // edge never snaps ahead of the shell contour.
        let phase = (model.nexusPresented || model.wallpapersPresented || model.desktopPresented || model.screensaversPresented) ? nexusPhase : 0
#if MACPP_CAELESTIA_SHELL
        let metrics = model.displayMetrics
        return metrics.launcherSearchWidth
            + (metrics.launcherNexusWidth - metrics.launcherSearchWidth) * phase
#else
        return launcherWidth + (nexusWidth - launcherWidth) * phase
#endif
#else
        launcherWidth
#endif
    }

    /// The SwiftUI tree stays authored-size while it is laid out, then is
    /// reduced as one unit inside the display-local AppKit frame. This keeps
    /// Nexus' internal columns, hit targets, and typography in proportion on
    /// a short display without changing any wide-display measurement.
    private var responsiveScale: CGFloat {
#if MACPP_CAELESTIA_SHELL
        model.displayMetrics.scale
#else
        1
#endif
    }

    private var authoredSurfaceWidth: CGFloat {
#if MACPPCAST_EMBEDDED
        let phase = (model.nexusPresented || model.wallpapersPresented || model.desktopPresented || model.screensaversPresented) ? nexusPhase : 0
        return launcherWidth + (nexusWidth - launcherWidth) * phase
#else
        launcherWidth
#endif
    }

    private var authoredPanelHeight: CGFloat {
        model.panelHeight / max(0.01, responsiveScale)
    }

    private var launcherMorphOpacity: Double {
        let fade = min(1, max(0, (nexusPhase - 0.10) / 0.68))
        return Double(1 - fade)
    }

    private var nexusMorphOpacity: Double {
        // Begin painting the prepared layer near the start of the resize.
        // The old timings left a perceptible interval where neither surface
        // supplied enough content, especially on high-refresh displays.
        let fade = min(1, max(0, (nexusPhase - 0.06) / 0.68))
        return Double(fade)
    }

    private var auxiliaryPresented: Bool { model.overlayPresented }

    /// Search is the plain launcher state; Nexus is its only bottom-surface
    /// expansion. Wallpaper and desktop retain their established launcher
    /// contour branch so this repair cannot alter their curves.
    private var searchNexusSurface: Bool {
#if MACPP_CAELESTIA_SHELL
        !model.wallpapersPresented && !model.desktopPresented && !model.screensaversPresented
#else
        // The legacy embedded shell keeps its existing launcher contour.
        false
#endif
    }

    private func searchField() -> some View {
        TextField("", text: $model.query)
            .textFieldStyle(.plain)
            .font(.system(size: CastTypography.query, weight: .medium, design: .rounded))
            .foregroundColor(Palette.pale)
            .focused($focusTarget, equals: .search)
            .accessibilityLabel("Search")
            .accessibilityHint("Search apps, commands, windows, and pickers")
            .accessibilityAddTraits(.isSearchField)
            // TextField's submit action is not delivered consistently by the
            // borderless accessory window after the result array is replaced.
            // Consume Return at the field itself so filtered commands use the
            // same selection path as a click. Shift+Return remains available
            // to LauncherView for Window Pull.
            .onKeyPress(phases: .down) { press in
                guard (press.characters == "\r" || press.characters == "\n"),
                      !press.modifiers.contains(.shift) else { return .ignored }
                model.executeSelected(hide: hide)
                return .handled
            }
            .onChange(of: model.query) { _, _ in model.selected = 0 }
    }

    private func commandBar() -> some View {
        HStack(spacing: 11) {
            Image(systemName: model.isEnteringArgument ? "link" : "magnifyingglass")
                .font(.system(size: CastTypography.icon, weight: .semibold, design: .rounded))
                .foregroundStyle(Palette.cyan)
            if let title = model.pendingCommandTitle {
                Text(title.uppercased())
                    .font(.system(size: CastTypography.chip, weight: .bold, design: .rounded))
                    .foregroundStyle(Palette.pale)
                    .lineLimit(1)
                    .padding(.horizontal, 10)
                    .frame(height: 28)
                    .background(Palette.cyan.opacity(0.12), in: Capsule())
            }
            ZStack(alignment: .leading) {
                if model.query.isEmpty {
                    Text(model.inputPlaceholder)
                        .font(.system(size: CastTypography.query, weight: .medium, design: .rounded))
                        .foregroundStyle(Palette.muted)
                        .allowsHitTesting(false)
                }
                searchField()
            }
            .layoutPriority(1)
            if model.isEnteringArgument && model.query.isEmpty {
                Button { model.pasteArgument() } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "doc.on.clipboard")
                        Text("PASTE")
                    }
                    .font(.system(size: CastTypography.chip, weight: .bold, design: .rounded))
                    .padding(.horizontal, 9)
                    .frame(height: 28)
                    .background(Palette.pale.opacity(0.06), in: Capsule())
                }
                .buttonStyle(CastButtonStyle())
                .foregroundStyle(Palette.pale)
                .accessibilityLabel("Paste command argument")
            }
            if !model.query.isEmpty {
                Button {
                    if model.isEnteringArgument { model.cancelArgumentEntry() }
                    else { model.query = "" }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: CastTypography.chip, weight: .bold, design: .rounded))
                }
                .buttonStyle(CastButtonStyle())
                .foregroundStyle(Palette.muted)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 32)
        .frame(height: 58)
    }

    private var launcherStack: some View {
        // MacPlusPlusCast is attached to the shell's bottom rim.  Keep the overlay
        // stack bottom-aligned at the container itself, not only at each
        // child's inner frame.  With the default centre alignment, the
        // 460-point Nexus child is briefly centred in the launcher's old
        // 390-point host while AppKit is growing the window; the next arrow
        // key then becomes the first layout pass and the whole surface drops
        // a few pixels.  A single bottom anchor makes the initial and settled
        // geometry identical while leaving the existing morph transforms and
        // timing untouched.
        ZStack(alignment: .bottom) {
            VStack(spacing: 0) {
            LauncherResultsList(model: model, hide: hide, selectionNamespace: selectionHighlight)
#if MACPP_CAELESTIA_SHELL
            // Embedded Nexus owns the continuous shell surface. Keep the
            // launcher's one-point result/search divider out of that layer;
            // otherwise it can remain visible through the incoming Nexus
            // body as a second horizontal seam.
            Color.clear.frame(height: 1)
#else
            Capsule(style: .continuous).fill(Palette.cyan.opacity(0.12)).frame(height: 1)
                // Clear the 22pt shoulder and its antialiasing entirely so
                // this content divider never forms a T-junction with the
                // outer physical contour.
                .padding(.horizontal, 32)
#if MACPPCAST_EMBEDDED
                .opacity(motion.presented ? 1 : 0)
#else
                .opacity(motion.presented ? 1 : 0)
                .animation(CastMotion.content.animation, value: motion.presented)
#endif
#endif
            commandBar()
            }
#if MACPPCAST_EMBEDDED
            // MacPlusPlusCast is attached to the shell's lower rim. Keep the
            // launcher stack in that same coordinate system even while the
            // host window is catching up with a resize. Without an explicit
            // fill/alignment frame SwiftUI can use the stack's first measured
            // (shorter) ideal height, centre it in the host, and then move it
            // on the first selection change -- the arrow key was accidentally
            // acting as the missing layout pass.
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottom)
#endif
            .opacity(launcherMorphOpacity)
            .scaleEffect(1 - (0.016 * nexusPhase), anchor: .bottom)
            .offset(y: -8 * nexusPhase)
            .allowsHitTesting(!auxiliaryPresented && !model.nexusTransitioning)

#if MACPPCAST_EMBEDDED
            // Pinned to the bottom rim, not centred.
            //
            // `presentNexus` sets `panelHeight` to its full value immediately
            // while the host NSPanel resizes separately and slightly later.
            // The explicit bottom alignment above keeps this full-height
            // destination pinned to the same rim even while that resize is in
            // flight. Without it, a short first proposal centred the child
            // and the first arrow keypress became the re-layout that appeared
            // to shift everything down.
            //
            // Every other transform on this surface is already bottom-anchored
            // (the scale below, and BottomMorphShape). Matching that here makes
            // the content's position independent of when the window catches up.
            LauncherEmbeddedAuxiliarySurfaces(
                model: model,
                nexusContent: nexusContent,
                wallpaperContent: wallpaperContent,
                desktopContent: desktopContent,
                screensaverContent: screensaverContent,
                phase: nexusPhase,
                opacity: nexusMorphOpacity
            )
#endif
            // Nexus is intentionally not a text field, but the command
            // surface still needs a real first responder for its shared
            // arrow/escape key handlers. Keep keyboard ownership on a tiny
            // hidden focus target instead of putting a caret in the search
            // field or relying on a click inside a card.
            if model.overlayPresented {
                Color.clear
                    .frame(width: 1, height: 1)
                    .focusable()
                    // This target exists only to receive the shared keyboard
                    // events. SwiftUI's default macOS focus effect paints a
                    // small accent cap at the bottom-center of the attached
                    // launcher, which becomes visible again when the Nexus
                    // transition reasserts focus. Keep the target focusable
                    // without rendering a focus decoration.
                    .focusEffectDisabled()
                    .focused($focusTarget, equals: .overlay)
                    .opacity(0.001)
                    .allowsHitTesting(false)
                    .accessibilityHidden(true)
            }
        }
    }

    var body: some View {
        launcherStack
#if MACPP_CAELESTIA_SHELL
        // `launcherStack` keeps its authored 600/960pt layout proposal so the
        // nested Nexus view remains internally consistent. The outer frame is
        // the only compact-display change and is exactly identity at scale 1.
        .frame(width: authoredSurfaceWidth, height: authoredPanelHeight, alignment: .bottom)
        .scaleEffect(responsiveScale, anchor: .bottom)
#endif
        .frame(width: surfaceWidth, height: model.panelHeight, alignment: .bottom)
#if MACPPCAST_EMBEDDED
#if MACPP_CAELESTIA_SHELL
        // The single-display shell owns the animation clock and can briefly
        // leave the dock's old backing tile below this transparent host.
        // Paint the same shell-aware silhouette here as well, so no dock or
        // running indicator can show through the embedded Nexus envelope.
        .background(Palette.frame)
#else
        .background(paintsEmbeddedSurface ? Palette.frame : Color.clear)
#endif
#if MACPP_CAELESTIA_SHELL
        .clipShape(LauncherSurfaceContourShape(
            useSearchNexusContour: searchNexusSurface,
            progress: presentationProgress,
            contracting: !motion.presented
        ))
#else
        .clipShape(BottomMorphShape(
            topRadius: 20,
            shoulder: 22,
            progress: presentationProgress,
            contracting: !motion.presented
        ))
#endif
        .overlay(alignment: .bottom) {
            if paintsEmbeddedSurface && !searchNexusSurface {
                // In the multi-display self-painted path, cover the resting
                // shell contour under MacPlusPlusCast from inside the existing
                // silhouette. The mask preserves every current shoulder and
                // attachment coordinate; this is only a two-point paint fix.
                GeometryReader { geometry in
                    Rectangle()
                        .fill(Palette.frame)
                        .frame(width: geometry.size.width, height: 2)
                        .position(x: geometry.size.width / 2, y: geometry.size.height - 1)
                }
                .mask(BottomMorphShape(
                    topRadius: 20,
                    shoulder: 22,
                    progress: presentationProgress,
                    contracting: !motion.presented
                ))
            }
        }
#else
        .background(Palette.frame)
        .clipShape(RoundedRectangle(cornerRadius: CastRounding.surface, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: CastRounding.surface, style: .continuous)
                .stroke(
                    Palette.seam,
                    style: StrokeStyle(
                        lineWidth: Palette.seamWidth,
                        lineCap: .round,
                        lineJoin: .round
                    )
                )
        }
#endif
        // The shared frame paints the opaque attached surface first. Delay
        // launcher information until that surface has enough area to contain
        // it, avoiding labels and icons floating beside a narrow opening.
        .opacity(surfaceContentOpacity)
        // LivingSurface uses one native contour clip. Search/Nexus follow that
        // rule so their reverse attachment curves are not clipped a second
        // time by a rectangular mask. Wallpaper and desktop keep the exact
        // existing raster mask through the modifier's fallback branch.
#if MACPP_CAELESTIA_SHELL
        .modifier(LauncherSearchNexusRevealModifier(
            useNativeContour: searchNexusSurface,
            progress: presentationProgress,
            contracting: !motion.presented
        ))
#else
        // MacPlusPlusCast remains at its final bottom-attached position. The mask
        // rolls upward from the physical rim, revealing the final curve from
        // the first frame instead of raising an older rectangular surface.
        .mask {
            GeometryReader { geometry in
#if MACPPCAST_EMBEDDED
                // Keep the launcher reveal/dismissal on the same sampled
                // contour phase as the shell border. A SwiftUI animation of
                // `motion.progress` can land between two AppKit frames and
                // leave the Nexus surface visibly one frame behind.
                let progress = presentationProgress
                // Use the same curved, bottom-attached silhouette for the
                // mask as for the fill and border. A rectangular crop made
                // the first and last samples visibly square and exposed the
                // resting shell line before the reverse shoulders arrived.
                BottomMorphShape(
                    topRadius: 20,
                    shoulder: 22,
                    progress: progress,
                    contracting: !motion.presented
                )
                .fill(Color.white)
#else
                // A standalone launcher is a floating palette, not a shell
                // extrusion. It must remain drawable even if motion is cut off.
                Color.white
#endif
            }
        }
#endif
#if !MACPPCAST_EMBEDDED
        .animation(motion.presented ? CastMotion.surface.animation : CastMotion.dismiss.animation, value: motion.presented)
        .animation(CastMotion.resize.animation, value: model.panelHeight)
        .animation(CastMotion.resize.animation, value: model.nexusMorphProgress)
#endif
        .onAppear {
            focusTarget = model.overlayPresented ? .overlay : .search
            model.refreshMode()
        }
        .onChange(of: motion.presented) { _, presented in
            if presented {
                focusTarget = nil
                DispatchQueue.main.async {
                    focusTarget = model.overlayPresented ? .overlay : .search
                }
            }
        }
        .onChange(of: model.focusRequest) { _, _ in
            // AppKit can finish making the borderless launcher key one run-loop
            // after SwiftUI's initial focus transaction. Resetting and
            // reasserting focus makes every keyboard/shortcut presentation
            // deterministic without requiring a click.
            focusTarget = nil
            DispatchQueue.main.async {
                focusTarget = model.overlayPresented ? .overlay : .search
            }
        }
        .onChange(of: model.overlayPresented) { _, presented in
            guard motion.presented else { return }
            DispatchQueue.main.async {
                focusTarget = presented ? .overlay : .search
            }
        }
        .onKeyPress(.upArrow) { model.arrow(-1); return .handled }
        .onKeyPress(.downArrow) { model.arrow(1); return .handled }
        // Nexus' menu is a vertical column, so up/down is its natural axis,
        // but left/right are the equally obvious guess for "move between the
        // different menus" and nothing on these overlays consumes them --
        // so both work. They stay inert for the plain result list, which has
        // only one axis.
        .onKeyPress(.leftArrow) {
            guard model.overlayPresented else { return .ignored }
            model.arrow(-1)
            return .handled
        }
        .onKeyPress(.rightArrow) {
            guard model.overlayPresented else { return .ignored }
            model.arrow(1)
            return .handled
        }
        // Enter/Return and Space confirm the highlighted item in the
        // screensaver carousel. The carousel is intentionally not focusable;
        // the shared hidden overlay target keeps arrow and confirm handling
        // stable while the cards remain ordinary buttons for mouse users.
        .onKeyPress(phases: .down) { press in
            guard model.screensaversPresented,
                  press.modifiers.isEmpty,
                  press.characters == "\r" || press.characters == "\n" || press.characters == " "
            else { return .ignored }
            model.publishOverlayConfirm()
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard (press.characters == "\r" || press.characters == "\n"),
                  press.modifiers.contains(.shift),
                  MacPlusPlusWindowQuery.parse(model.query) != nil else { return .ignored }
            model.executeSelected(hide: hide, pullToCurrentSpace: true)
            return .handled
        }
        .onKeyPress(phases: .down) { press in
            guard press.characters.lowercased() == "p",
                  press.modifiers.contains(.command) else { return .ignored }
            return model.toggleSelectedClipboardPin() ? .handled : .ignored
        }
        .onKeyPress(.escape) {
            if model.nexusPresented || model.wallpapersPresented || model.desktopPresented
                || model.screensaversPresented || model.nexusTransitioning { hide() }
            else if model.isEnteringArgument { model.cancelArgumentEntry() }
            else { hide() }
            return .handled
        }
        // MacPlusPlusCast is the shell's command surface in both embedded and
        // standalone builds. Apply the same rounded SF Pro design at the
        // root so any system control without an explicit font stays in the
        // same typographic family as Nexus and the rail.
        .fontDesign(.rounded)
    }
}

struct ResultRow: View {
    let item: CommandItem; let active: Bool
    let selectionNamespace: Namespace.ID
    // Not read anywhere in the body -- it exists purely so that a palette
    // change alters this view's inputs and forces a re-render of the
    // non-observable Palette.* colours below. See LauncherModel.paletteRevision.
    let paletteRevision: Int
    @State private var hovered = false
    var body: some View {
        // A single-line row centres its icon against the text, as before. A
        // wrapped answer aligns to the top instead -- an icon floating in the
        // vertical middle of a paragraph reads as unanchored.
        HStack(alignment: item.bodyLineCount > 1 ? .top : .center, spacing: 12) {
            ResultIcon(item: item, active: active, paletteRevision: paletteRevision)
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .font(.system(size: CastTypography.resultTitle, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.pale.opacity(active ? 1 : 0.90))
                    // 1 for every ordinary result, so app and command names
                    // still truncate rather than reflowing. Only the AI answer
                    // raises this, and it also has to be left-aligned: a
                    // wrapped paragraph centred in the row reads as ragged.
                    .lineLimit(item.bodyLineCount)
                    .multilineTextAlignment(.leading)
                    .fixedSize(horizontal: false, vertical: true)
                    // Keep named MacPlusPlus surfaces readable on the compact
                    // launcher.  In particular, "MacPlusPlus Observatory" must
                    // remain a complete label instead of being clipped beside
                    // its icon when the embedded surface is narrow.
                    .minimumScaleFactor(item.bodyLineCount == 1 ? 0.72 : 0.86)
                // Keep descriptions searchable and available to accessibility,
                // but keep the visible launcher row title-only. New features
                // should not make every Search result grow another line.
            }
            Spacer()
            if item.clipboardPinned {
                Image(systemName: "pin.fill")
                    .font(.system(size: 9, weight: .semibold, design: .rounded))
                    .foregroundStyle(Palette.cyan.opacity(active ? 0.92 : 0.70))
            }
        // minHeight rather than a fixed height: a single-line row is still
        // exactly 44 as before, but a wrapped answer is allowed to grow to the
        // height the model already budgeted for it in measuredResultsHeight.
        }.padding(.horizontal, 10).padding(.vertical, item.bodyLineCount > 1 ? 8 : 0).frame(minHeight: 44)
        .background {
            if active {
                RoundedRectangle(cornerRadius: CastRounding.row, style: .continuous)
                    .fill(Palette.cyan.opacity(0.105))
                    .matchedGeometryEffect(id: "macpp-cast-selection", in: selectionNamespace)
            } else if hovered {
                RoundedRectangle(cornerRadius: CastRounding.row, style: .continuous).fill(Palette.pale.opacity(0.025))
            }
        }
        .scaleEffect(hovered && !active ? 1.008 : 1)
        .onHover { hovered = $0 }
        .animation(CastMotion.hover.animation, value: hovered)
        .animation(CastMotion.selection.animation, value: active)
    }
}

private struct ResultIcon: View {
    let item: CommandItem
    let active: Bool
    // Palette.* is a plain static read, so this real input keeps the icon
    // subtree in step with the row when a wallpaper-derived palette changes.
    let paletteRevision: Int

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Palette.pale.opacity(active ? 0.060 : 0.025))
                .overlay {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(Palette.pale.opacity(active ? 0.085 : 0.045), lineWidth: 0.5)
                }
            content
        }
        .frame(width: 32, height: 32)
    }

    @ViewBuilder
    private var content: some View {
        // Every result gets a real SF Symbol first. App icons, clipboard
        // thumbnails, and emoji are useful context, but they are optional
        // previews and must not replace the guaranteed symbol.
        ZStack(alignment: .bottomTrailing) {
            Image(systemName: item.resolvedIconName)
                .symbolRenderingMode(.monochrome)
                .font(.system(size: CastTypography.icon, weight: .medium, design: .rounded))
                .foregroundStyle(active ? Palette.pale.opacity(0.95) : Palette.cyan.opacity(0.78))

            if item.kind == .app, let url = item.url {
                Image(nsImage: AppIconCache.shared.icon(for: url))
                    .resizable()
                    .scaledToFit()
                    .padding(2)
                    .frame(width: 16, height: 16)
                    .background(Palette.ink.opacity(0.88), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Palette.pale.opacity(0.25), lineWidth: 0.5)
                    }
            } else if item.kind == .clipboard,
                      let id = item.clipboardEntryID,
                      let data = item.clipboardThumbnail,
                      let image = ClipboardThumbnailCache.shared.image(for: id, data: data) {
                Image(nsImage: image)
                    .resizable()
                    .scaledToFill()
                    .frame(width: 16, height: 16)
                    .clipShape(RoundedRectangle(cornerRadius: 4, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .stroke(Palette.pale.opacity(0.25), lineWidth: 0.5)
                    }
            } else if item.kind == .emoji,
                      let value = item.displayValue,
                      !value.isEmpty {
                Text(value)
                    .font(.system(size: 12))
                    .frame(width: 16, height: 16)
                    .background(Palette.ink.opacity(0.88), in: RoundedRectangle(cornerRadius: 4, style: .continuous))
            }
        }
    }
}

#if !MACPPCAST_EMBEDDED
final class LauncherPanel: NSPanel {
    init(content: NSView) {
        super.init(contentRect: NSRect(x: 0, y: 0, width: launcherWidth, height: 390), styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView], backing: .buffered, defer: false)
        self.contentView = content; isOpaque = false; backgroundColor = .clear; hasShadow = true
        level = .screenSaver; collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
        isMovableByWindowBackground = false; hidesOnDeactivate = false
    }
    override var canBecomeKey: Bool { true }
}

@MainActor final class AppDelegate: NSObject, NSApplicationDelegate {
    let model = LauncherModel()
    let motion = LauncherMotionState()
    var panel: LauncherPanel!
    var hotKey: EventHotKeyRef?
    var fallbackHotKey: EventHotKeyRef?
    private var catalogWatcher: ApplicationCatalogWatcher?
    var outsideClickMonitor: Any?
    var isTransitioning = false
    var pendingHeight: CGFloat?
    private var transitionGeneration = 0
    private var signalToggleSource: DispatchSourceSignal?
    func applicationDidFinishLaunching(_ notification: Notification) {
        if let flag = CommandLine.arguments.firstIndex(of: "--window-search") {
            let term = CommandLine.arguments.indices.contains(flag + 1)
                ? CommandLine.arguments[(flag + 1)...].joined(separator: " ")
                : ""
            let values = MacPlusPlusWindowCatalog.search(MacPlusPlusWindowQuery(term: term))
            let rows = values.map { window in
                [
                    "id": String(window.id),
                    "kind": ItemKind.window.rawValue,
                    "title": window.title.isEmpty ? window.app : window.title,
                    "subtitle": "\(window.app)  •  SPACE \(window.space)",
                    "can_move": window.canMove ? "true" : "false"
                ]
            }
            // macpp:silent-ok picker output is diagnostic-only and may be omitted if serialization fails
            if let data = try? JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys]) {
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            Darwin.exit(values.isEmpty ? 1 : 0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--picker-search"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let namespace = CommandLine.arguments[flag + 1]
            let term = CommandLine.arguments.indices.contains(flag + 2)
                ? CommandLine.arguments[(flag + 2)...].joined(separator: " ")
                : ""
            guard MacPlusPlusPickerQuery.parse(namespace) != nil else {
                FileHandle.standardError.write(Data("unknown picker namespace: \(namespace)\n".utf8))
                Darwin.exit(2)
            }
            model.query = term.isEmpty ? namespace : "\(namespace) \(term)"
            let rows: [[String: String]] = model.items.map { item in
                [
                    "id": item.id,
                    "kind": item.kind.rawValue,
                    "title": item.title,
                    "subtitle": item.subtitle,
                    "copy_value": item.copyValue ?? ""
                ]
            }
            let data: Data
            do {
                data = try JSONSerialization.data(withJSONObject: rows, options: [.sortedKeys])
            } catch {
                FileHandle.standardError.write(Data("could not encode picker results: \(error)\n".utf8))
                Darwin.exit(1)
            }
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
            Darwin.exit(rows.isEmpty ? 1 : 0)
        }
        if let flag = CommandLine.arguments.firstIndex(of: "--calculate"),
           CommandLine.arguments.indices.contains(flag + 1) {
            let result = CalculatorEngine.evaluate(CommandLine.arguments[flag + 1]) ?? "ERROR"
            FileHandle.standardOutput.write(Data((result + "\n").utf8))
            Darwin.exit(result == "ERROR" ? 1 : 0)
        }
        if CommandLine.arguments.contains("--catalog") {
            model.reload()
            for item in model.baseItems where item.kind == .app {
                print("\(item.title)\t\(item.url?.path ?? "")")
            }
            NSApp.terminate(nil)
            return
        }
        model.loadCatalog()
        catalogWatcher = ApplicationCatalogWatcher()
        catalogWatcher?.start { [weak self] in
            Task { @MainActor [weak self] in self?.model.loadCatalog() }
        }
        panel = LauncherPanel(content: NSHostingView(rootView: LauncherView(model: model, motion: motion, hide: { [weak self] in self?.hide() })))
        model.onHeightChange = { [weak self] height in self?.resizePanel(to: height) }
        installSignalToggle()
        registerHotKey(); installEventHandler()
        outsideClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            Task { @MainActor in
                if self?.panel?.isVisible == true { self?.hide() }
            }
        }
        DistributedNotificationCenter.default().addObserver(
            self, selector: #selector(showFromNotification(_:)),
            name: NSNotification.Name("org.macplusplus.search.show"), object: nil,
            suspensionBehavior: .deliverImmediately
        )
        if ProcessInfo.processInfo.environment["MACPPCAST_SHOW_ON_LAUNCH"] == "1" {
            show()
            if let initial = ProcessInfo.processInfo.environment["MACPPCAST_INITIAL_QUERY"] { model.query = initial }
        }
    }
    @objc nonisolated private func showFromNotification(_ notification: Notification) {
        Task { @MainActor [weak self] in self?.show() }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        show(); return true
    }
    func applicationWillTerminate(_ notification: Notification) {
        model.stop()
    }
    func toggle() { panel.isVisible ? hide() : show() }
    private func installSignalToggle() {
        signal(SIGUSR1, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: SIGUSR1, queue: .main)
        source.setEventHandler { [weak self] in self?.toggle() }
        source.resume()
        signalToggleSource = source
    }
    func resizePanel(to height: CGFloat) {
        guard panel != nil else { return }
        if isTransitioning { pendingHeight = height; return }
        let old = panel.frame
        // Keep the launcher centred while its filtered result count changes.
        // Pinning the visible panel to minY made the first keystroke appear to
        // throw an otherwise centred launcher down to the bottom edge.
        let y: CGFloat
        if panel.isVisible, let screen = panel.screen ?? NSScreen.main ?? NSScreen.screens.first {
            y = screen.frame.midY - height / 2
        } else {
            y = old.minY
        }
        let frame = NSRect(x: old.minX, y: y, width: old.width, height: height)
        guard panel.isVisible else { panel.setFrame(frame, display: false); return }
        NSAnimationContext.runAnimationGroup { context in
            context.duration = CastMotion.resize.duration
            context.timingFunction = CastMotion.resize.appKitTiming
            panel.animator().setFrame(frame, display: true)
        }
    }
    func show() {
        transitionGeneration += 1
        let generation = transitionGeneration
        isTransitioning = true
        model.query = ""; model.selected = 0; model.refreshMode()
        guard let screen = NSScreen.main ?? NSScreen.screens.first else {
            isTransitioning = false
            return
        }
        DistributedNotificationCenter.default().postNotificationName(
            NSNotification.Name("org.macplusplus.shell.dismiss-surfaces"), object: nil, userInfo: nil, deliverImmediately: true
        )
        NSApp.activate(ignoringOtherApps: true)
        let size = NSSize(width: launcherWidth, height: model.panelHeight)
        let target = NSRect(
            x: screen.frame.midX - size.width / 2,
            y: screen.frame.midY - size.height / 2,
            width: size.width,
            height: size.height
        )
        panel.alphaValue = 1
        panel.setFrame(target, display: true)
        motion.presented = false
        panel.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            withAnimation(CastMotion.surface.animation) { self.motion.presented = true }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + CastMotion.surface.duration) { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            self.isTransitioning = false
            if let height = self.pendingHeight { self.pendingHeight = nil; self.resizePanel(to: height) }
        }
    }
    func hide() {
        guard panel?.isVisible == true else { return }
        transitionGeneration += 1
        let generation = transitionGeneration
        isTransitioning = true; pendingHeight = nil
        withAnimation(CastMotion.dismiss.animation) { motion.presented = false }
        DispatchQueue.main.asyncAfter(deadline: .now() + CastMotion.dismiss.duration) { [weak self] in
            guard let self, generation == self.transitionGeneration else { return }
            self.panel.orderOut(nil)
            self.panel.alphaValue = 1
            self.isTransitioning = false
            DistributedNotificationCenter.default().postNotificationName(
                NSNotification.Name("org.macplusplus.shell.resume-edges"), object: nil, userInfo: nil, deliverImmediately: true
            )
        }
    }
    func registerHotKey() {
        // Presentation is supplied by the shell's notification bridge.
    }
    func installEventHandler() {
        // Presentation arrives through org.macplusplus.search.show.
    }
}

@main struct MacPlusPlusCastApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var delegate
    var body: some Scene { Settings { EmptyView() } }
}
#endif
