import Foundation
import CoreGraphics

/// The official Caelestia shell keeps its visual contract in a small set of
/// shared tokens. This namespace is the Mac++ parity copy of that contract;
/// app-specific values remain in `MacPlusPlusShell.swift`, but shell chrome
/// must derive its shared geometry and timing from here.
enum CaelestiaParityTokens {
    static let referenceRepository = "https://github.com/caelestia-dots/shell"
    static let referenceCommit = "750e67d93ac12b264cb8cbc3a1f2b8f429c923c2"

    enum Border {
        static let thickness: CGFloat = 10
        static let rounding: CGFloat = 25
        static let smoothing: CGFloat = 20
        static let minimumThickness: CGFloat = 2
    }

    enum Rounding {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let largeIncreased: CGFloat = 20
        static let extraLarge: CGFloat = 28
        static let extraLargeIncreased: CGFloat = 32
        static let extraExtraLarge: CGFloat = 48
        static let full: CGFloat = .greatestFiniteMagnitude
    }

    enum Spacing {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let largeIncreased: CGFloat = 20
        static let extraLarge: CGFloat = 28
        static let extraLargeIncreased: CGFloat = 32
        static let extraExtraLarge: CGFloat = 48
    }

    enum Padding {
        static let extraSmall: CGFloat = 4
        static let small: CGFloat = 8
        static let medium: CGFloat = 12
        static let large: CGFloat = 16
        static let largeIncreased: CGFloat = 20
        static let extraLarge: CGFloat = 28
        static let extraLargeIncreased: CGFloat = 32
        static let extraExtraLarge: CGFloat = 48
    }

    enum Font {
        static let small: CGFloat = 11
        static let smaller: CGFloat = 12
        static let normal: CGFloat = 13
        static let larger: CGFloat = 15
        static let large: CGFloat = 18
        static let extraLarge: CGFloat = 28
    }

    enum Sizes {
        static let barInnerWidth: CGFloat = 40
        static let barWindowPreview: CGFloat = 400
        static let barTrayMenuWidth: CGFloat = 300
        static let barBatteryWidth: CGFloat = 250
        static let barNetworkWidth: CGFloat = 320
        static let barKeyboardLayoutWidth: CGFloat = 320

        static let launcherItemWidth: CGFloat = 600
        // Search owns the 600pt command surface. Nexus follows the larger
        // control-centre envelope used by Caelestia: a broad page area with
        // enough height for the grouped navigation rows and page-local
        // content to breathe without collapsing into a card grid.
        static let launcherNexusWidth: CGFloat = 960
        static let launcherItemHeight: CGFloat = 57
        static let launcherWallpaperWidth: CGFloat = 280
        static let launcherWallpaperHeight: CGFloat = 200

        static let dashboardMediaWidth: CGFloat = 200
        static let dashboardWeatherWidth: CGFloat = 275
        static let dashboardMediaTabWidth: CGFloat = 1_000
        static let dashboardMediaTabHeight: CGFloat = 320

        static let notificationWidth: CGFloat = 430
        static let notificationImage: CGFloat = 42
        static let notificationBadge: CGFloat = 20
        static let osdSliderWidth: CGFloat = 30
        static let osdSliderHeight: CGFloat = 150
        static let sessionButton: CGFloat = 80
        static let sidebarWidth: CGFloat = 430
        static let utilityWidth: CGFloat = 430
        static let toastWidth: CGFloat = 430
        // Keep five stable spaces to match the upstream affordance count.
        // LAB is the Mac++ utility/experimentation space; it does not assume
        // any particular app assignment and stays unavailable until yabai
        // exposes a matching fifth space.
        static let workspaceCount = 5
    }

    /// Nexus is a shell surface, so its envelope and internal rhythm use the
    /// same spacing steps as the rail and attached popouts. Keeping these
    /// values together prevents the dashboard from accumulating one-off
    /// gutters as pages evolve.
    enum Nexus {
        // This is the authored desktop envelope. The display-local responsive
        // helper keeps it unchanged on wide displays and uniformly scales the
        // complete surface only when a smaller display cannot contain it.
        static let surfaceHeight: CGFloat = 640
        static let navigationWidth: CGFloat = 300
        static let dividerWidth: CGFloat = 0
        static let contentHorizontalGutter: CGFloat = Padding.extraLarge
        static let contentVerticalGutter: CGFloat = Padding.extraLarge
        static let navigationGutter: CGFloat = Padding.large
        static let navigationTopGutter: CGFloat = Padding.large
        static let navigationBottomGutter: CGFloat = Padding.medium
        static let cardPadding: CGFloat = Padding.medium
    }

    enum Interaction {
        static let barDragThreshold: CGFloat = 20
        static let dashboardDragThreshold: CGFloat = 50
        static let launcherDragThreshold: CGFloat = 50
        static let sessionDragThreshold: CGFloat = 30
        static let sidebarDragThreshold: CGFloat = 80
        static let sidebarHoverThreshold: CGFloat = 200
    }

    /// The live bar popout has one gutter contract. The attached side needs
    /// the smoothing band to disappear cleanly into the rail; the far side
    /// and both vertical edges only need the normal content breathing room.
    /// Keeping these values together prevents each component from inventing
    /// its own hidden envelope.
    enum Popout {
        static let attachedGutter: CGFloat = Border.smoothing
        static let contentGutter: CGFloat = Padding.medium
        static let verticalGutter: CGFloat = Padding.medium
        /// Once a left-rail surface is actually grounded on the lower rim,
        /// the reverse fillet owns the geometric shoulder. Keep only the
        /// optical content gutter below the last card; reserving that shoulder
        /// a second time made grounded popouts carry a dead 20pt tail.
        static let groundedBottomGutter: CGFloat = verticalGutter
        static let rowSpacing: CGFloat = Spacing.small
        /// Information cards stay in their frozen destination box from the
        /// first frame, but remain hidden until the attached surface is in its
        /// safe placement band. 0.78 gives the staged tree a useful reveal
        /// tail on the default 500 ms handoff without waiting for the final
        /// handful of display-link frames. The tree is already mounted in
        /// its frozen destination box, so this does not reintroduce the
        /// measure/paint race that the gate is meant to prevent.
        static let contentPlacementThreshold: CGFloat = 0.78
    }

    enum Motion {
        static let small: TimeInterval = 0.200
        static let normal: TimeInterval = 0.400
        static let large: TimeInterval = 0.600
        static let extraLarge: TimeInterval = 1.000
        static let fastSpatial: TimeInterval = 0.350
        static let defaultSpatial: TimeInterval = 0.500
        static let slowSpatial: TimeInterval = 0.650
        static let fastEffects: TimeInterval = 0.150
        static let defaultEffects: TimeInterval = 0.200
        static let slowEffects: TimeInterval = 0.300

        /// Cubic segments are stored as x1, y1, x2, y2, x3, y3. The first
        /// segment starts at (0, 0); subsequent segments start at the prior
        /// segment's endpoint, matching Caelestia's animation evaluator.
        static let curves: [String: [Double]] = [
            "emphasized": [0.05, 0, 2.0 / 15.0, 0.06, 1.0 / 6.0, 0.4,
                           5.0 / 24.0, 0.82, 0.25, 1, 1, 1],
            "emphasizedAccel": [0.3, 0, 0.8, 0.15, 1, 1],
            "emphasizedDecel": [0.05, 0.7, 0.1, 1, 1, 1],
            "standard": [0.2, 0, 0, 1, 1, 1],
            "standardAccel": [0.3, 0, 1, 1, 1, 1],
            "standardDecel": [0, 0, 0, 1, 1, 1],
            "expressiveFastSpatial": [0.42, 1.67, 0.21, 0.9, 1, 1],
            "expressiveDefaultSpatial": [0.38, 1.21, 0.22, 1, 1, 1],
            "expressiveSlowSpatial": [0.39, 1.29, 0.35, 0.98, 1, 1],
            "expressiveFastEffects": [0.31, 0.94, 0.34, 1, 1, 1],
            "expressiveDefaultEffects": [0.34, 0.8, 0.34, 1, 1, 1],
            "expressiveSlowEffects": [0.34, 0.88, 0.34, 1, 1, 1]
        ]
    }

    /// Caelestia's `BarWrapper` width is the 40pt inner rail plus 10pt
    /// padding on both sides. Mac++ uses that 60pt envelope for the visible
    /// rail, while the frame overlay owns the remaining screen-edge seams.
    static let barInnerWidth: CGFloat = Sizes.barInnerWidth
    static let barContentPadding: CGFloat = Border.thickness
    static let barOuterWidth: CGFloat = barInnerWidth + Border.thickness * 2
    static let sidebarWidth: CGFloat = Sizes.sidebarWidth
}
