import Foundation

/// One bounded failure log for MacPlusPlus process, persistence, and private-API
/// boundaries. Successful refreshes stay silent; repeated failures with the
/// same key are coalesced so a broken high-frequency probe cannot become its
/// own disk or CPU problem.
enum MacPlusPlusBoundaryLog {
    private static let queue = DispatchQueue(label: "org.macplusplus.macpp.boundary-log")
    private static var lastRecordByKey: [String: Date] = [:]
    private static let maximumBytes: UInt64 = 1_048_576

    static func record(
        _ message: String,
        key: String? = nil,
        minimumInterval: TimeInterval = 0
    ) {
        queue.async {
            let now = Date()
            if let key, minimumInterval > 0,
               let previous = lastRecordByKey[key],
               now.timeIntervalSince(previous) < minimumInterval {
                return
            }
            if let key { lastRecordByKey[key] = now }

            let manager = FileManager.default
            let directory = manager.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Logs/MacPlusPlus", isDirectory: true)
            let target = directory.appendingPathComponent("boundaries.log")
            let entry = "[\(ISO8601DateFormatter().string(from: now))] \(message)\n"
            guard let data = entry.data(using: .utf8) else { return }
            do {
                try manager.createDirectory(at: directory, withIntermediateDirectories: true)
                let size = (try? manager.attributesOfItem(atPath: target.path)[.size] as? NSNumber)?
                    .uint64Value ?? 0
                if size >= maximumBytes || !manager.fileExists(atPath: target.path) {
                    try data.write(to: target, options: .atomic)
                } else {
                    let handle = try FileHandle(forWritingTo: target)
                    try handle.seekToEnd()
                    try handle.write(contentsOf: data)
                    try handle.close()
                }
            } catch {
                // The diagnostic boundary is deliberately fail-open. A log
                // destination must never take the shell down with it.
                NSLog("MacPlusPlus boundary log unavailable: %@", String(describing: error))
            }
        }
    }
}

private final class MacPlusPlusCommandErrorBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var data = Data()

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        lock.lock()
        data.append(chunk)
        if data.count > 8_192 { data.removeFirst(data.count - 8_192) }
        lock.unlock()
    }

    func text() -> String {
        lock.lock(); defer { lock.unlock() }
        return String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
    }
}

/// Launches a user action without blocking SwiftUI, but still observes its
/// final exit status and a bounded stderr tail.
@discardableResult
func launchMacPlusPlusShellCommand(_ command: String, context: String) -> Bool {
    let process = Process()
    let errors = Pipe()
    let buffer = MacPlusPlusCommandErrorBuffer()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = ["-lc", command]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = errors
    errors.fileHandleForReading.readabilityHandler = { handle in
        buffer.append(handle.availableData)
    }
    process.terminationHandler = { finished in
        errors.fileHandleForReading.readabilityHandler = nil
        buffer.append(errors.fileHandleForReading.availableData)
        guard finished.terminationStatus != 0 else { return }
        let detail = buffer.text()
        MacPlusPlusBoundaryLog.record(
            "command failed context=\(context) status=\(finished.terminationStatus)"
                + (detail.isEmpty ? "" : " stderr=\(detail)"),
            key: "command:\(context)",
            minimumInterval: 30
        )
    }
    do {
        try process.run()
        return true
    } catch {
        errors.fileHandleForReading.readabilityHandler = nil
        MacPlusPlusBoundaryLog.record(
            "command could not launch context=\(context) error=\(error)",
            key: "command:\(context)",
            minimumInterval: 30
        )
        return false
    }
}
