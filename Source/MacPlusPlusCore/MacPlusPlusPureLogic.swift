// Pure, deterministic logic shared by MacPlusPlus surfaces.
//
// Keep this file free of AppKit/SwiftUI and side effects.  It is compiled into
// the shell, and the focused test runner compiles this exact production source
// again rather than maintaining a second copy of the algorithms.

enum MacPlusPlusPureLogic {
    // MARK: Carousel

    /// A modulo operation whose result is always in `0..<count`.
    static func wrappedIndex(_ value: Int, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let remainder = value % count
        return remainder >= 0 ? remainder : remainder + count
    }

    /// Advances a logical carousel index without allowing a negative result.
    static func advancedCarouselIndex(current: Int, step: Int, itemCount: Int) -> Int? {
        guard let normalizedCurrent = wrappedIndex(current, count: itemCount),
              let normalizedStep = wrappedIndex(step, count: itemCount) else { return nil }
        guard normalizedStep != 0 else { return normalizedCurrent }

        // Both operands are below itemCount.  Subtracting at the boundary
        // avoids the otherwise unnecessary `current + step` overflow case.
        let distanceToEnd = itemCount - normalizedStep
        return normalizedCurrent >= distanceToEnd
            ? normalizedCurrent - distanceToEnd
            : normalizedCurrent + normalizedStep
    }

    /// Builds the duplicate end caps used by an infinitely wrapping carousel.
    static func loopPaddedCarousel<Item>(_ items: [Item], padding: Int) -> [Item] {
        guard !items.isEmpty, padding > 0 else { return items }
        let leading = (0..<padding).compactMap { offset -> Item? in
            guard let index = wrappedIndex(items.count - padding + offset, count: items.count) else {
                return nil
            }
            return items[index]
        }
        let trailing = (0..<padding).compactMap { offset -> Item? in
            guard let index = wrappedIndex(offset, count: items.count) else { return nil }
            return items[index]
        }
        return leading + items + trailing
    }

    /// Re-homes a duplicate end-cap slot onto the equivalent real card.
    static func normalizedCarouselVisualIndex(
        _ visualIndex: Int,
        itemCount: Int,
        padding: Int
    ) -> Int? {
        guard itemCount > 0, padding >= 0,
              let logical = wrappedIndex(visualIndex - padding, count: itemCount) else { return nil }
        return logical + padding
    }

    // MARK: Media ownership

    private struct MediaProfile {
        let applicationAliases: Set<String>
        let ownerAliases: Set<String>
        let helperPrefixes: Set<String>
    }

    /// Known cases where the visible application, bundle identifier and audio
    /// helper genuinely have different names.  Prefix matching is intentionally
    /// limited to this table: unrestricted `contains`/`hasPrefix` made apps such
    /// as Music match unrelated names such as MusicBox.
    private static let mediaProfiles: [MediaProfile] = [
        MediaProfile(
            applicationAliases: ["safari"],
            ownerAliases: ["safari", "comapplesafari"],
            helperPrefixes: ["safarigraphicsandmedia", "safariwebcontent"]
        ),
        MediaProfile(
            applicationAliases: ["browser", "macbrowser", "macplusplusbrowser", "macppbrowser"],
            ownerAliases: [
                "browser", "macbrowser", "macppbrowser", "macplusplusbrowser",
                "orgmacplusplusbrowser", "orgmacplusplusbrowser", "orgmacplusplusbrowser"
            ],
            helperPrefixes: ["macplusplusbrowserhelper", "vela"]
        ),
        MediaProfile(
            applicationAliases: ["googlechrome", "chrome"],
            ownerAliases: ["googlechrome", "chrome", "comgooglechrome"],
            helperPrefixes: ["googlechromehelper"]
        ),
        MediaProfile(
            applicationAliases: ["discord"],
            ownerAliases: ["discord", "comhncdiscord"],
            helperPrefixes: ["discordhelper"]
        ),
        MediaProfile(
            applicationAliases: ["arc"],
            ownerAliases: ["arc", "companythebrowserbrowser"],
            helperPrefixes: ["archelper"]
        ),
        MediaProfile(
            applicationAliases: ["firefox"],
            ownerAliases: ["firefox", "orgmozillafirefox"],
            helperPrefixes: ["firefoxcph"]
        ),
        MediaProfile(
            applicationAliases: ["bravebrowser", "brave"],
            ownerAliases: ["bravebrowser", "brave", "combravesoftwarebrowser"],
            helperPrefixes: ["bravebrowserhelper"]
        ),
        MediaProfile(
            applicationAliases: ["spotify"],
            ownerAliases: ["spotify", "spotifyplayer", "comspotifyclient"],
            helperPrefixes: ["spotifyhelper"]
        ),
        MediaProfile(
            applicationAliases: ["music"],
            ownerAliases: ["music", "comapplemusic"],
            helperPrefixes: []
        ),
        MediaProfile(
            applicationAliases: ["vlc"],
            ownerAliases: ["vlc", "orgvideolanvlc"],
            helperPrefixes: []
        ),
        MediaProfile(
            applicationAliases: ["iina"],
            ownerAliases: ["iina", "comcolliderliiina"],
            helperPrefixes: []
        ),
    ]

    private static let genericMediaOwnerTokens: Set<String> = [
        "", "active", "media", "none", "system", "unknown"
    ]

    static func mediaToken(_ value: String) -> String {
        value.lowercased().filter { $0.isLetter || $0.isNumber }
    }

    private static func mediaProfile(forApplicationToken token: String) -> MediaProfile? {
        mediaProfiles.first { $0.applicationAliases.contains(token) }
    }

    private static func specificOwnerTokens(source: String, device: String) -> [String] {
        [device, source]
            .map(mediaToken)
            .filter { !genericMediaOwnerTokens.contains($0) }
    }

    static func hasSpecificMediaOwner(source: String, device: String) -> Bool {
        !specificOwnerTokens(source: source, device: device).isEmpty
    }

    static func mediaOwnerDescription(source: String, device: String) -> String {
        specificOwnerTokens(source: source, device: device).joined(separator: " | ")
    }

    /// Matches a visible application to a source/bundle identity reported by
    /// the media producer.  Unknown apps still work when their normalized name
    /// is an exact identity; only known, explicit aliases broaden that match.
    static func mediaOwnerMatches(
        application: String,
        source: String,
        device: String
    ) -> Bool {
        let applicationToken = mediaToken(application)
        guard !applicationToken.isEmpty else { return false }
        let owners = specificOwnerTokens(source: source, device: device)
        guard !owners.isEmpty else { return false }

        if owners.contains(applicationToken) { return true }
        guard let profile = mediaProfile(forApplicationToken: applicationToken) else { return false }
        return owners.contains { profile.ownerAliases.contains($0) }
    }

    /// Matches a visible application to a CoreAudio process.  Browser/Electron
    /// helpers are allowed only through the explicit prefixes above.
    static func audioProcessMatches(application: String, process: String) -> Bool {
        let applicationToken = mediaToken(application)
        let processToken = mediaToken(process)
        guard !applicationToken.isEmpty, !processToken.isEmpty else { return false }
        if processToken == applicationToken { return true }
        guard let profile = mediaProfile(forApplicationToken: applicationToken) else { return false }
        if profile.ownerAliases.contains(processToken) { return true }
        return profile.helperPrefixes.contains { prefix in
            processToken == prefix || processToken.hasPrefix(prefix)
        }
    }

    // MARK: EQ preset data

    static let eqPresetNames = ["flat", "warm", "clarity", "bass", "hardcore", "vocals", "night"]

    /// The shell UI calls this table directly when applying a preset.  Tests
    /// therefore validate the values that are actually sent to Mac++ EQ.
    static func eqPresetGains(named name: String) -> [Double]? {
        switch name {
        case "flat": return [0, 0, 0, 0, 0, 0, 0, 0, 0, 0]
        case "warm": return [2.3, 1.9, 1.1, 0.6, 0.0, -0.9, -0.5, -0.9, 0.1, 1.0]
        case "clarity": return [-1.6, -1.3, -0.6, 0.0, 0.6, 1.1, 2.1, 2.0, 0.3, -0.1]
        case "bass": return [4.7, 3.6, 2.6, 0.3, -1.2, -0.4, -0.9, 0.3, -0.2, 1.0]
        case "hardcore": return [0.8, 5.9, 2.3, -2.0, -3.4, -1.5, 0.7, 3.6, 0.2, -1.0]
        case "vocals": return [-4.4, -2.1, 0.1, 3.0, -3.6, -1.4, 2.4, 4.6, 0.8, -0.9]
        case "night": return [-4.9, -3.1, -1.0, 0.3, 0.5, 1.4, 1.6, 0.2, -0.8, -2.9]
        default: return nil
        }
    }

    // MARK: Power telemetry

    /// Chooses the live machine draw from AppleSmartBattery's telemetry.
    ///
    /// `SystemPowerIn` is the wall-input reading while an adapter is attached,
    /// but it is normally absent on battery. `SystemLoad` is the direct system
    /// draw in that state, with `BatteryPower` as the older-model fallback.
    static func batterySystemPowerMilliwatts(
        externalPower: Bool,
        wallInput: Int?,
        systemLoad: Int?,
        batteryPower: Int?
    ) -> Int? {
        let candidates = externalPower
            ? [wallInput, systemLoad]
            : [systemLoad, batteryPower]
        return candidates
            .compactMap { $0 }
            .map { $0 == Int.min ? Int.max : abs($0) }
            .first(where: { $0 > 0 })
    }
}
