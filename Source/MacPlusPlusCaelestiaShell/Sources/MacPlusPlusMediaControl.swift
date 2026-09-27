import Foundation

/// Starts the public media-control helper without blocking the Shell's main
/// actor. The helper validates actions before they reach macOS.
enum MacPlusPlusMediaControl {
    static func launch(_ action: String, provider: String = "active") -> Bool {
        guard let helper = helperURL,
              ["playpause", "previous", "next", "forward", "backward", "play", "pause"].contains(action),
              ["active", "system", "spotify", "safari", "browser"].contains(provider) else {
            return false
        }

        let process = Process()
        process.executableURL = helper
        process.arguments = [action, provider]
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        process.terminationHandler = { process in
            guard process.terminationStatus != 0 else { return }
            NSLog("Mac++ media control failed (status %d)", process.terminationStatus)
        }
        do {
            try process.run()
            return true
        } catch {
            NSLog("Mac++ media control could not start: %@", String(describing: error))
            return false
        }
    }

    private static var helperURL: URL? {
        var candidates = [URL]()
        if let configured = ProcessInfo.processInfo.environment["MACPP_MEDIA_CONTROL_HELPER"],
           !configured.isEmpty {
            candidates.append(URL(fileURLWithPath: configured))
        }
        if let resourceURL = Bundle.main.resourceURL {
            candidates.append(resourceURL.appendingPathComponent("macpp-media-control"))
        }
        if let root = ProcessInfo.processInfo.environment["MACPP_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("bin/macpp-media-control"))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("bin/macpp-media-control")
        )
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
    }
}
