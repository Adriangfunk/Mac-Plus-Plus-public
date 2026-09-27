import Foundation

/// Settings shared by the shell's Nexus controls and the standalone soft-lock
/// process. Keeping this separate from Nexus's larger configuration means the
/// overlay can reload these values without needing to launch the shell.
struct MacPlusPlusSoftLockConfiguration: Codable, Equatable, Sendable {
    var showWeather: Bool
    var showMedia: Bool
    var showPerformance: Bool
    var showNotifications: Bool

    init(
        showWeather: Bool = true,
        showMedia: Bool = true,
        showPerformance: Bool = true,
        showNotifications: Bool = true
    ) {
        self.showWeather = showWeather
        self.showMedia = showMedia
        self.showPerformance = showPerformance
        self.showNotifications = showNotifications
    }

    private enum CodingKeys: String, CodingKey {
        case showWeather
        case showMedia
        case showPerformance
        case showNotifications
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        showWeather = try container.decodeIfPresent(Bool.self, forKey: .showWeather) ?? true
        showMedia = try container.decodeIfPresent(Bool.self, forKey: .showMedia) ?? true
        showPerformance = try container.decodeIfPresent(Bool.self, forKey: .showPerformance) ?? true
        showNotifications = try container.decodeIfPresent(Bool.self, forKey: .showNotifications) ?? true
    }

    static let `default` = MacPlusPlusSoftLockConfiguration()
    static let didChangeNotification = Notification.Name("org.macplusplus.macpp.soft-lock.configuration")

    private static var configurationURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/MacPlusPlus", isDirectory: true)
            .appendingPathComponent("soft-lock.json")
    }

    static func load() -> MacPlusPlusSoftLockConfiguration {
        guard let data = try? Data(contentsOf: configurationURL),
              let configuration = try? JSONDecoder().decode(Self.self, from: data) else {
            return .default
        }
        return configuration
    }

    @discardableResult
    static func save(_ configuration: MacPlusPlusSoftLockConfiguration) -> Bool {
        do {
            try FileManager.default.createDirectory(
                at: configurationURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(configuration)
            try data.write(to: configurationURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }
}

/// Reset through the already-installed launcher so the standalone app remains
/// the only owner of its verifier and no password material crosses the shell.
enum MacPlusPlusSoftLockPasscodeBridge {
    private static var launcherCandidates: [URL] {
        []
    }

    static func reset() -> Bool {
        guard let launcher = launcherCandidates.first(where: {
            FileManager.default.isExecutableFile(atPath: $0.path)
        }) else {
            return false
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/zsh")
        process.arguments = [launcher.path, "--reset-passcode"]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
            process.waitUntilExit()
            return process.terminationStatus == 0
        } catch {
            return false
        }
    }
}
