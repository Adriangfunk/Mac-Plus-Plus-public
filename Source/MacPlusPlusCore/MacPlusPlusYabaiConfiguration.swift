import Foundation

enum MacPlusPlusYabaiConfiguration {
    static func executableURL() -> URL? {
        let selectedLevel = UserDefaults.standard.string(forKey: "org.macplusplus.setup.yabai") ?? "off"
        guard selectedLevel == "standard" || selectedLevel == "scriptingAddition" else { return nil }

        let environment = ProcessInfo.processInfo.environment
        var candidates: [String] = []
        if let configured = environment["MACPP_YABAI_PATH"], !configured.isEmpty {
            candidates.append(configured)
        }
        candidates.append(contentsOf: [
            "/opt/homebrew/bin/yabai",
            "/usr/local/bin/yabai",
            "/usr/bin/yabai",
        ])
        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/yabai" })
        }

        var seen = Set<String>()
        for candidate in candidates {
            guard !candidate.isEmpty, !seen.contains(candidate) else { continue }
            seen.insert(candidate)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }
        return nil
    }
}
