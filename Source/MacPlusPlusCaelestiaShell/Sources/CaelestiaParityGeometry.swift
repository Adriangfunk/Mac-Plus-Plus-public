import CoreGraphics
import SwiftUI

/// Pure geometry shared by the parity shell and its contract tests. These
/// helpers describe the attached envelopes; the SwiftUI/AppKit surface code
/// remains responsible for drawing the animated blob contour.
enum CaelestiaParityGeometry {
    enum AttachmentEdge {
        case leading
        case trailing
        case top
        case bottom
    }

    struct EdgeRegions: Equatable {
        let bar: CGRect
        let top: CGRect
        let right: CGRect
        let bottom: CGRect
    }

    static func barFrame(in screenFrame: CGRect) -> CGRect {
        CGRect(
            x: screenFrame.minX,
            y: screenFrame.minY,
            width: CaelestiaParityTokens.barOuterWidth,
            height: screenFrame.height
        )
    }

    /// The sidebar is attached to the right edge. Progress 0 is fully shown;
    /// progress 1 is hidden five points beyond the edge, matching the
    /// upstream wrapper's `(-width - 5) * offsetScale` margin.
    static func sidebarFrame(
        in screenFrame: CGRect,
        progress: CGFloat,
        topInset: CGFloat = 0,
        bottomInset: CGFloat = 0
    ) -> CGRect {
        let width = CaelestiaParityTokens.sidebarWidth
        let boundedProgress = min(1, max(0, progress))
        let x = screenFrame.maxX - width + (width + 5) * boundedProgress
        return CGRect(
            x: x,
            y: screenFrame.minY + bottomInset,
            width: width,
            height: max(0, screenFrame.height - topInset - bottomInset)
        )
    }

    static func edgeRegions(in screenFrame: CGRect) -> EdgeRegions {
        let thickness = CaelestiaParityTokens.Border.thickness
        return EdgeRegions(
            bar: barFrame(in: screenFrame),
            top: CGRect(
                x: screenFrame.minX + CaelestiaParityTokens.barOuterWidth,
                y: screenFrame.maxY - thickness,
                width: max(0, screenFrame.width - CaelestiaParityTokens.barOuterWidth - thickness),
                height: thickness
            ),
            right: CGRect(
                x: screenFrame.maxX - thickness,
                y: screenFrame.minY + thickness,
                width: thickness,
                height: max(0, screenFrame.height - thickness * 2)
            ),
            bottom: CGRect(
                x: screenFrame.minX + thickness,
                y: screenFrame.minY,
                width: max(0, screenFrame.width - thickness * 2),
                height: thickness
            )
        )
    }

    static func popoutEnvelope(
        content: CGSize,
        attached: AttachmentEdge
    ) -> CGSize {
        let attachedGutter = CaelestiaParityTokens.Popout.attachedGutter
        let contentGutter = CaelestiaParityTokens.Popout.contentGutter
        let verticalGutter = CaelestiaParityTokens.Popout.verticalGutter
        switch attached {
        case .leading, .trailing:
            return CGSize(
                width: content.width + attachedGutter + contentGutter,
                height: content.height + verticalGutter * 2
            )
        case .top, .bottom:
            return CGSize(
                width: content.width + verticalGutter * 2,
                height: content.height + attachedGutter + contentGutter
            )
        }
    }

    /// Derive the physical camera-housing opening from AppKit's two
    /// auxiliary top-area readings. A missing pair is not a 209-point notch:
    /// it means there is no reliable housing geometry to paint yet.
    ///
    /// Keep this calculation pure so a flat display and a transient
    /// WindowServer publication can be covered without starting AppKit.
    static func cameraHousingFrame(
        leftArea: CGRect?,
        rightArea: CGRect?,
        minimumGap: CGFloat = 40,
        minimumHeight: CGFloat = CaelestiaParityTokens.Border.thickness
    ) -> CGRect? {
        guard let leftArea, let rightArea else { return nil }
        let gap = rightArea.minX - leftArea.maxX
        let minY = min(leftArea.minY, rightArea.minY)
        let maxY = max(leftArea.maxY, rightArea.maxY)
        let height = maxY - minY
        guard gap > minimumGap, gap > 0, height > minimumHeight else { return nil }
        return CGRect(x: leftArea.maxX, y: minY, width: gap, height: height)
    }

    /// Normalize a measured housing to the physical top edge of its display.
    ///
    /// `auxiliaryTopLeftArea` and `auxiliaryTopRightArea` can briefly publish
    /// a stale vertical origin while WindowServer is changing menu-bar or
    /// display parameters. Their horizontal gap and height remain useful,
    /// but using that transient `y` directly paints a detached notch in the
    /// middle of the desktop. Keep the measured width/height and anchor the
    /// resulting frame to the current screen bounds instead.
    static func topCameraHousingFrame(
        leftArea: CGRect?,
        rightArea: CGRect?,
        screenBounds: CGRect,
        minimumGap: CGFloat = 40,
        minimumHeight: CGFloat = CaelestiaParityTokens.Border.thickness,
        tolerance: CGFloat = 2
    ) -> CGRect? {
        guard let measured = cameraHousingFrame(
            leftArea: leftArea,
            rightArea: rightArea,
            minimumGap: minimumGap,
            minimumHeight: minimumHeight
        ) else { return nil }
        guard measured.minX >= screenBounds.minX - tolerance,
              measured.maxX <= screenBounds.maxX + tolerance,
              measured.width <= screenBounds.width + tolerance else {
            return nil
        }

        let normalized = CGRect(
            x: measured.minX,
            y: screenBounds.maxY - measured.height,
            width: measured.width,
            height: measured.height
        )
        guard normalized.minY >= screenBounds.midY - tolerance,
              abs(normalized.maxY - screenBounds.maxY) <= tolerance else {
            return nil
        }
        return normalized
    }

    /// Display-local sizing for surfaces that have an authored desktop size.
    ///
    /// The parity copy is tuned in points, not pixels.  Keep that authored
    /// geometry verbatim whenever the display can contain it; only derive a
    /// scale below one when the display would otherwise clip the Nexus
    /// envelope.  This is deliberately a pure value type so the wide-display
    /// contract can be tested without starting AppKit or a shell process.
    struct DisplayMetrics: Equatable {
        static let authored = DisplayMetrics(scale: 1)

        let scale: CGFloat
        let launcherSearchWidth: CGFloat
        let launcherNexusWidth: CGFloat
        let nexusHeight: CGFloat
        let wallpaperCarouselHeight: CGFloat
        let wallpaperEditorHeight: CGFloat
        let topSurfaceWidth: CGFloat
        let edgeControlsWidth: CGFloat
        let edgeControlsHeight: CGFloat
        let sidebarWidth: CGFloat
        let shellStudioWidth: CGFloat

        init(screenSize: CGSize) {
            let widthBudget = max(
                0,
                screenSize.width - CaelestiaParityTokens.Border.thickness * 2
            )
            let heightBudget = max(
                0,
                screenSize.height - CaelestiaParityTokens.Border.thickness * 2
            )
            let authoredWidth = CaelestiaParityTokens.Sizes.launcherNexusWidth
            let authoredHeight = CaelestiaParityTokens.Nexus.surfaceHeight
            let displayScale = min(
                1,
                widthBudget / max(1, authoredWidth),
                heightBudget / max(1, authoredHeight)
            )
            self.init(scale: max(0.01, displayScale))
        }

        init(scale rawScale: CGFloat) {
            let scale = min(1, max(0.01, rawScale))
            self.scale = scale
            launcherSearchWidth = CaelestiaParityTokens.Sizes.launcherItemWidth * scale
            launcherNexusWidth = CaelestiaParityTokens.Sizes.launcherNexusWidth * scale
            nexusHeight = CaelestiaParityTokens.Nexus.surfaceHeight * scale
            wallpaperCarouselHeight = 248 * scale
            wallpaperEditorHeight = 448 * scale
            topSurfaceWidth = 700 * scale
            edgeControlsWidth = 65 * scale
            edgeControlsHeight = 316 * scale
            sidebarWidth = CaelestiaParityTokens.Sizes.sidebarWidth * scale
            shellStudioWidth = 720 * scale
        }

        /// The non-media rail modules have a fixed authored minimum.  The
        /// decorative ticker gives up its lane first; only when that is not
        /// enough does the complete rail stack get uniformly reduced.
        static let railMinimumContentHeight: CGFloat = 565

        static func railContentScale(for availableHeight: CGFloat) -> CGFloat {
            guard availableHeight > 0 else { return 0.01 }
            return min(1, max(0.01, availableHeight / railMinimumContentHeight))
        }

        static func mediaLaneHeight(for availableHeight: CGFloat) -> CGFloat {
            min(240, max(0, availableHeight - railMinimumContentHeight))
        }
    }
}
