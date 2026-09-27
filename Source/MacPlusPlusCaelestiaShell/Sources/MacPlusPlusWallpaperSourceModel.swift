import Combine
import Darwin
import Foundation

struct MacPlusPlusWallpaperSourceResult: Decodable, Identifiable, Equatable, Sendable {
    let id: String
    let pageURL: String
    let resolution: String
    let width: Int
    let height: Int
    let ratio: Double
    let fileSize: Int
    let fileType: String
    let mediaURL: String
    let thumbnailSmall: String
    let thumbnailLarge: String

    private enum CodingKeys: String, CodingKey {
        case id, resolution, width, height, ratio
        case pageURL = "page_url"
        case fileSize = "file_size"
        case fileType = "file_type"
        case mediaURL = "media_url"
        case thumbnailSmall = "thumbnail_small"
        case thumbnailLarge = "thumbnail_large"
    }
}

struct MacPlusPlusWallpaperSourceResponse: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let provider: String
    let query: String
    let page: Int
    let lastPage: Int
    let total: Int
    let results: [MacPlusPlusWallpaperSourceResult]

    private enum CodingKeys: String, CodingKey {
        case provider, query, page, total, results
        case schemaVersion = "schema_version"
        case lastPage = "last_page"
    }
}

struct MacPlusPlusWallpaperSourceImport: Decodable, Equatable, Sendable {
    let schemaVersion: Int
    let dryRun: Bool
    let id: String
    let path: String
    let width: Int
    let height: Int
    let sha256: String
    let alreadyPresent: Bool
    let warning: String?
    let catalogNotified: Bool?

    private enum CodingKeys: String, CodingKey {
        case id, path, width, height, sha256, warning
        case schemaVersion = "schema_version"
        case dryRun = "dry_run"
        case alreadyPresent = "already_present"
        case catalogNotified = "catalog_notified"
    }
}

enum MacPlusPlusWallpaperSourceDecode {
    static func search(_ data: Data) throws -> MacPlusPlusWallpaperSourceResponse {
        guard data.count <= 256 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let response = try JSONDecoder().decode(MacPlusPlusWallpaperSourceResponse.self, from: data)
        guard response.schemaVersion == 1,
              response.provider == "wallhaven",
              (1...100).contains(response.page),
              response.lastPage >= response.page,
              response.results.count <= 24 else { throw URLError(.cannotParseResponse) }
        return response
    }

    static func imported(_ data: Data) throws -> MacPlusPlusWallpaperSourceImport {
        guard data.count <= 64 * 1024 else { throw URLError(.dataLengthExceedsMaximum) }
        let result = try JSONDecoder().decode(MacPlusPlusWallpaperSourceImport.self, from: data)
        guard result.schemaVersion == 1,
              result.dryRun == false,
              !result.id.isEmpty,
              result.width >= 3440,
              result.height >= 1440,
              result.sha256.count == 64 else { throw URLError(.cannotParseResponse) }
        return result
    }
}

@MainActor
final class MacPlusPlusWallpaperSourceModel: ObservableObject {
    @Published var query = ""
    @Published private(set) var results: [MacPlusPlusWallpaperSourceResult] = []
    @Published private(set) var page = 1
    @Published private(set) var lastPage = 1
    @Published private(set) var total = 0
    @Published private(set) var isSearching = false
    @Published private(set) var importingID: String?
    @Published private(set) var status = "SEARCH WALLHAVEN'S ULTRAWIDE LIBRARY"
    @Published private(set) var errorMessage = ""

    private var searchGeneration = 0
    private var searchTask: Task<Void, Never>?
    private var importTask: Task<Void, Never>?
    private var importGeneration: UInt64 = 0
    private var cache: [String: MacPlusPlusWallpaperSourceResponse] = [:]

    private static var helperURL: URL {
        var candidates = [URL]()
        if let override = ProcessInfo.processInfo.environment["MACPP_WALLPAPER_SOURCE_HELPER"],
           !override.isEmpty {
            candidates.append(URL(fileURLWithPath: override))
        }
        if let resources = Bundle.main.resourceURL {
            candidates.append(resources.appendingPathComponent("macpp-wallpaper-source"))
        }
        if let root = ProcessInfo.processInfo.environment["MACPP_ROOT"], !root.isEmpty {
            candidates.append(URL(fileURLWithPath: root).appendingPathComponent("bin/macpp-wallpaper-source"))
        }
        candidates.append(
            URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
                .appendingPathComponent("bin/macpp-wallpaper-source")
        )
        return candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) })
            ?? URL(fileURLWithPath: "/usr/bin/false")
    }

    private final class ProcessTerminationBox: @unchecked Sendable {
        private let lock = NSLock()
        private var process: Process?
        private var cancelled = false

        func install(_ process: Process) -> Bool {
            lock.lock()
            if cancelled {
                lock.unlock()
                if process.isRunning { process.terminate() }
                return false
            }
            self.process = process
            lock.unlock()
            return true
        }

        func cancel() {
            lock.lock()
            cancelled = true
            let process = self.process
            lock.unlock()
            if let process, process.isRunning { process.terminate() }
        }

        var wasCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }

        func clear() {
            lock.lock()
            process = nil
            lock.unlock()
        }
    }

    func search(page requestedPage: Int = 1, force: Bool = false) {
        let normalizedQuery = query
            .split(whereSeparator: { $0.isWhitespace })
            .joined(separator: " ")
        let targetPage = min(100, max(1, requestedPage))
        let cacheKey = "\(normalizedQuery.lowercased())|\(targetPage)"
        searchTask?.cancel()
        searchGeneration &+= 1
        let generation = searchGeneration
        if !force, let cached = cache[cacheKey] {
            isSearching = false
            errorMessage = ""
            apply(cached)
            return
        }
        isSearching = true
        errorMessage = ""
        status = "SEARCHING WALLHAVEN…"
        let helper = Self.helperURL
        searchTask = Task { [weak self] in
            do {
                let data = try await Self.run(
                    helper: helper,
                    arguments: [
                        "search", normalizedQuery,
                        "--page", String(targetPage),
                        "--limit", "12",
                        "--json",
                    ],
                    timeout: 18,
                    outputLimit: 256 * 1024
                )
                let response = try MacPlusPlusWallpaperSourceDecode.search(data)
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                let currentQuery = self.query
                    .split(whereSeparator: { $0.isWhitespace })
                    .joined(separator: " ")
                guard currentQuery == normalizedQuery else {
                    self.status = "QUERY CHANGED • PRESS SEARCH"
                    self.isSearching = false
                    return
                }
                self.cache[cacheKey] = response
                self.apply(response)
            } catch {
                guard let self, !Task.isCancelled, self.searchGeneration == generation else { return }
                self.results = []
                self.errorMessage = Self.displayError(error)
                self.status = "SEARCH UNAVAILABLE"
            }
            guard let self, self.searchGeneration == generation else { return }
            self.isSearching = false
            self.searchTask = nil
        }
    }

    func previousPage() {
        guard page > 1 else { return }
        search(page: page - 1)
    }

    func nextPage() {
        guard page < lastPage else { return }
        search(page: page + 1)
    }

    func importAndUse(
        _ result: MacPlusPlusWallpaperSourceResult,
        crop: MacPlusPlusWallpaperCropSelection? = nil,
        completion: @escaping @MainActor (Result<URL, Error>) -> Void
    ) {
        guard importingID == nil, importTask == nil else { return }
        importGeneration &+= 1
        let generation = importGeneration
        importingID = result.id
        errorMessage = ""
        status = crop == nil ? "IMPORTING \(result.resolution)…" : "CROPPING \(result.resolution)…"
        let helper = Self.helperURL
        importTask = Task { [weak self] in
            defer {
                if let self, self.importGeneration == generation {
                    self.importingID = nil
                    self.importTask = nil
                }
            }
            do {
                var arguments = ["import", result.id, "--apply", "--json"]
                if let crop {
                    arguments += [
                        "--replace",
                        "--crop-x", crop.x.description,
                        "--crop-y", crop.y.description,
                    ]
                }
                let data = try await Self.run(
                    helper: helper,
                    arguments: arguments,
                    timeout: 150,
                    outputLimit: 64 * 1024
                )
                try Task.checkCancellation()
                let imported = try MacPlusPlusWallpaperSourceDecode.imported(data)
                let url = URL(fileURLWithPath: imported.path).standardizedFileURL
                guard FileManager.default.fileExists(atPath: url.path) else {
                    throw URLError(.fileDoesNotExist)
                }
                guard !Task.isCancelled,
                      let self,
                      self.importGeneration == generation else { return }
                self.status = imported.warning?.isEmpty == false
                    ? "IMPORTED • LOCK SCREEN NEEDS ATTENTION"
                    : "\(result.resolution) ADDED"
                completion(.success(url))
            } catch is CancellationError {
                return
            } catch {
                guard !Task.isCancelled,
                      let self,
                      self.importGeneration == generation else { return }
                self.errorMessage = Self.displayError(error)
                self.status = "IMPORT FAILED"
                completion(.failure(error))
            }
        }
    }

    func stop() {
        searchTask?.cancel()
        searchTask = nil
        searchGeneration &+= 1
        isSearching = false
        importTask?.cancel()
        importTask = nil
        importGeneration &+= 1
        importingID = nil
    }

    private func apply(_ response: MacPlusPlusWallpaperSourceResponse) {
        results = response.results
        page = response.page
        lastPage = response.lastPage
        total = response.total
        status = response.results.isEmpty
            ? "NO ELIGIBLE ULTRAWIDES"
            : "\(response.total) ELIGIBLE • PAGE \(response.page) OF \(response.lastPage)"
        errorMessage = ""
        isSearching = false
    }

    private nonisolated static func run(
        helper: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int
    ) async throws -> Data {
        let termination = ProcessTerminationBox()
        return try await withTaskCancellationHandler(operation: {
            let data = try await Task.detached(priority: .userInitiated) {
                try await runProcess(
                    helper: helper,
                    arguments: arguments,
                    timeout: timeout,
                    outputLimit: outputLimit,
                    termination: termination
                )
            }.value
            try Task.checkCancellation()
            return data
        }, onCancel: {
            termination.cancel()
        })
    }

    private nonisolated static func runProcess(
        helper: URL,
        arguments: [String],
        timeout: TimeInterval,
        outputLimit: Int,
        termination: ProcessTerminationBox
    ) async throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: helper.path) else {
            throw CocoaError(.fileNoSuchFile)
        }
        let process = Process()
        let output = Pipe()
        let diagnostics = Pipe()
        process.executableURL = helper
        process.arguments = arguments
        process.standardOutput = output
        process.standardError = diagnostics
        try process.run()
        guard termination.install(process) else {
            process.waitUntilExit()
            throw CancellationError()
        }
        // Drain both pipes while the helper is running. Waiting first can
        // deadlock if a future provider diagnostic fills either kernel
        // pipe, even though the decoded response is capped below.
        let outputReader = Task.detached(priority: .userInitiated) {
            output.fileHandleForReading.readDataToEndOfFile()
        }
        let diagnosticsReader = Task.detached(priority: .utility) {
            diagnostics.fileHandleForReading.readDataToEndOfFile()
        }
        let deadline = Date().addingTimeInterval(timeout)
        while process.isRunning && Date() < deadline && !termination.wasCancelled {
            try await Task.sleep(nanoseconds: 40_000_000)
        }
        if process.isRunning {
            process.terminate()
            // Cancellation and timeout both get a short grace period before
            // the helper is forcefully reaped, so a stuck provider cannot
            // leave its pipes and process behind.
            // macpp:silent-ok cancellation may interrupt the grace-period sleep.
            try? await Task.sleep(nanoseconds: 80_000_000)
            if process.isRunning { _ = Darwin.kill(process.processIdentifier, SIGKILL) }
        }
        process.waitUntilExit()
        termination.clear()
        let data = await outputReader.value
        let completeDiagnostics = await diagnosticsReader.value
        let errorData = completeDiagnostics.prefix(2_048)
        guard data.count <= outputLimit else { throw URLError(.dataLengthExceedsMaximum) }
        guard process.terminationStatus == 0 else {
            let detail = String(data: errorData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw NSError(
                domain: "MacPlusPlusWallpaperSource",
                code: Int(process.terminationStatus),
                userInfo: [NSLocalizedDescriptionKey: detail?.isEmpty == false ? detail! : "Wallpaper helper failed"]
            )
        }
        return data
    }

    private static func displayError(_ error: Error) -> String {
        let raw = (error as NSError).localizedDescription
            .replacingOccurrences(of: "macpp-wallpaper-source: ", with: "")
            .components(separatedBy: .newlines)
            .first ?? "Wallpaper source unavailable"
        return String(raw.prefix(140)).uppercased()
    }
}
