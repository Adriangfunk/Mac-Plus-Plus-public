import Foundation
import Darwin

struct MacPlusPlusShellCommandResult {
    let status: Int32
    let output: String
    let timedOut: Bool
    var succeeded: Bool { status == 0 && !timedOut }
}

/// Drain output while the child runs, with a bounded memory tail and deadline.
/// Waiting for exit before reading a pipe deadlocks on a full pipe; waiting for
/// EOF after exit can also hang when a descendant inherited the write end.
func runBoundedShellCommand(
    _ executable: String, _ arguments: [String], timeout: TimeInterval = 3
) -> MacPlusPlusShellCommandResult {
    let process = Process()
    let pipe = Pipe()
    process.executableURL = URL(fileURLWithPath: executable)
    process.arguments = arguments
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    let handle = pipe.fileHandleForReading
    let descriptor = handle.fileDescriptor
    guard fcntl(descriptor, F_SETFL, O_NONBLOCK) != -1 else {
        return MacPlusPlusShellCommandResult(status: -1, output: "", timedOut: false)
    }
    do {
        try process.run()
    } catch {
        MacPlusPlusBoundaryLog.record("Command could not launch: \((executable as NSString).lastPathComponent): \(error)")
        return MacPlusPlusShellCommandResult(status: -1, output: "", timedOut: false)
    }
    var output = Data()
    var buffer = [UInt8](repeating: 0, count: 8192)
    func drain() {
        // Bound each pass too, so an endless writer cannot starve the deadline.
        for _ in 0..<32 {
            let count = read(descriptor, &buffer, buffer.count)
            guard count > 0 else { return }
            output.append(contentsOf: buffer.prefix(count))
            if output.count > 4_194_304 { output.removeFirst(output.count - 4_194_304) }
        }
    }
    let deadline = ProcessInfo.processInfo.systemUptime + max(0.1, timeout)
    while process.isRunning && ProcessInfo.processInfo.systemUptime < deadline {
        drain()
        Thread.sleep(forTimeInterval: 0.01)
    }
    let timedOut = process.isRunning
    if timedOut {
        process.terminate()
        let grace = ProcessInfo.processInfo.systemUptime + 0.2
        while process.isRunning && ProcessInfo.processInfo.systemUptime < grace {
            drain()
            Thread.sleep(forTimeInterval: 0.01)
        }
        if process.isRunning { kill(process.processIdentifier, SIGKILL) }
    }
    process.waitUntilExit()
    drain()
    return MacPlusPlusShellCommandResult(
        status: process.terminationStatus,
        output: String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines),
        timedOut: timedOut
    )
}
