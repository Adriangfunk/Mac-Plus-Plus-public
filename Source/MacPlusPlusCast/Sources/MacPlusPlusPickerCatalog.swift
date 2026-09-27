import Foundation

/// Shared text handling for every Search surface. Keeping punctuation and
/// separator handling in one place means `media/audio`, `media-audio`, and
/// `media audio` all express the same intent, while the launcher and its
/// namespaced pickers use the same fuzzy matching rules.
enum MacPlusPlusSearchText {
    static func normalize(_ raw: String) -> String {
        let folded = raw.folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        )
        return folded
            .lowercased()
            .map { character in
                character.isLetter || character.isNumber ? String(character) : " "
            }
            .joined()
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    static func tokens(_ raw: String) -> [String] {
        let normalized = normalize(raw)
        return normalized.split(separator: " ").map(String.init)
    }

    /// Remove only navigation verbs. Action verbs such as `play`, `mute`, and
    /// `toggle` remain part of a query because they select a specific control.
    static func removingLeadingNavigationWords(_ raw: String) -> String {
        let normalized = normalize(raw)
        let prefixes = ["navigate to", "take me to", "go to", "open", "launch", "show", "view"]
        for prefix in prefixes {
            if normalized == prefix { return "" }
            if normalized.hasPrefix(prefix + " ") {
                return String(normalized.dropFirst(prefix.count + 1))
            }
        }
        return normalized
    }

    /// Return a lower-is-better score, or nil when the query cannot match.
    /// Exact and prefix matches stay ahead of edit-distance matches so a
    /// short typo improves discovery without displacing an obvious result.
    static func score(query: String, candidate: String, aliases: [String] = []) -> Int? {
        let normalizedQuery = normalize(query)
        guard !normalizedQuery.isEmpty else { return 0 }
        return ([candidate] + aliases).compactMap { value in
            score(normalizedQuery: normalizedQuery, candidate: normalize(value))
        }.min()
    }

    private static func score(normalizedQuery: String, candidate: String) -> Int? {
        guard !candidate.isEmpty else { return nil }
        if candidate == normalizedQuery { return 0 }
        if candidate.hasPrefix(normalizedQuery) { return 8 }
        if candidate.contains(normalizedQuery) { return 16 }

        let queryTokens = normalizedQuery.split(separator: " ").map(String.init)
        let candidateTokens = candidate.split(separator: " ").map(String.init)
        guard !queryTokens.isEmpty, !candidateTokens.isEmpty else { return nil }

        let initials = candidateTokens.compactMap(\.first).map(String.init).joined()
        if initials == normalizedQuery { return 4 }
        if initials.hasPrefix(normalizedQuery) { return 12 }

        var total = 0
        for queryToken in queryTokens {
            if candidateTokens.contains(queryToken) {
                continue
            }
            if candidateTokens.contains(where: { $0.hasPrefix(queryToken) }) {
                total += 2
                continue
            }
            if candidateTokens.contains(where: { isSubsequence(queryToken, of: $0) }) {
                total += 4
                continue
            }
            guard let distance = candidateTokens
                .map({ editDistance(queryToken, $0) })
                .min(), distance <= editDistanceAllowance(for: queryToken) else {
                return nil
            }
            total += 6 + distance
        }
        return 24 + total + max(0, candidateTokens.count - queryTokens.count)
    }

    private static func editDistanceAllowance(for token: String) -> Int {
        token.count < 3 ? 0 : min(2, max(1, token.count / 4))
    }

    private static func isSubsequence(_ needle: String, of haystack: String) -> Bool {
        guard !needle.isEmpty else { return true }
        var haystackIndex = haystack.startIndex
        for character in needle {
            guard let match = haystack[haystackIndex...].firstIndex(of: character) else { return false }
            haystackIndex = haystack.index(after: match)
        }
        return true
    }

    private static func editDistance(_ lhs: String, _ rhs: String) -> Int {
        let right = Array(rhs)
        var previous = Array(0...right.count)
        for (row, leftCharacter) in Array(lhs).enumerated() {
            var current = [row + 1]
            for (column, rightCharacter) in right.enumerated() {
                let insertion = current[column] + 1
                let deletion = previous[column + 1] + 1
                let substitution = previous[column] + (leftCharacter == rightCharacter ? 0 : 1)
                current.append(min(insertion, deletion, substitution))
            }
            previous = current
        }
        return previous[right.count]
    }
}

enum MacPlusPlusNexusDestination: String, CaseIterable, Sendable {
    case overview
    case media
    case audio
    case system
    case capture
    case settings
    case observatory
}

struct MacPlusPlusNexusQuery: Equatable, Sendable {
    let destination: MacPlusPlusNexusDestination

    static func parse(_ raw: String) -> MacPlusPlusNexusQuery? {
        let normalized = MacPlusPlusSearchText.removingLeadingNavigationWords(raw)
        guard !normalized.isEmpty else { return nil }
        let aliases: [MacPlusPlusNexusDestination: Set<String>] = [
            .overview: ["nexus", "macpp nexus", "control center", "dashboard"],
            // Media is deliberately the advanced media page: it owns the
            // player, lyrics, and provider-aware controls. Keep audio-only
            // EQ aliases separate so `media/audio` remains unambiguous.
            .media: [
                "media", "media audio", "audio media", "media controls",
                "advanced media", "advanced media tab", "nexus media",
                "nexus media audio", "music", "now playing", "player", "lyrics"
            ],
            .audio: ["audio", "audio lab", "audio controls", "equalizer", "eq", "nexus audio"],
            .system: ["nexus system", "system controls"],
            .capture: ["nexus capture", "capture tools"],
            .settings: ["nexus settings", "shell settings"],
            .observatory: ["observatory", "runtime health", "nexus observatory"]
        ]
#if MACPP_PUBLIC_RELEASE
        if aliases[.observatory]?.contains(normalized) == true {
            return nil
        }
#endif
        for destination in MacPlusPlusNexusDestination.allCases {
            if aliases[destination]?.contains(normalized) == true {
                return MacPlusPlusNexusQuery(destination: destination)
            }
        }
        return nil
    }
}

enum MacPlusPlusPickerNamespace: String, Sendable {
    case keybinds
    case emoji
    case symbols
}

struct MacPlusPlusWindowQuery: Equatable, Sendable {
    let term: String

    static func parse(_ raw: String) -> MacPlusPlusWindowQuery? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let lowered = trimmed.lowercased()
        for alias in ["windows", "window", "win"] {
            if lowered == alias {
                return MacPlusPlusWindowQuery(term: "")
            }
            guard lowered.hasPrefix(alias + " ") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: alias.count)
            return MacPlusPlusWindowQuery(term: String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines))
        }
        return nil
    }
}

struct MacPlusPlusWindowEntry: Hashable, Sendable {
    let id: Int
    let app: String
    let title: String
    let space: String
    let display: String
    let focused: Bool
    let canMove: Bool

    var searchText: String { "\(app) \(title) \(space) \(display)" }
}

enum MacPlusPlusWindowCatalog {
    static let maximumWindows = 256
    static let maximumResults = 48

    static func load() -> [MacPlusPlusWindowEntry] {
        let data: Data
        if let raw = ProcessInfo.processInfo.environment["MACPP_YABAI_WINDOWS_JSON"],
           let fake = raw.data(using: .utf8) {
            data = fake
        } else {
            guard let executable = MacPlusPlusYabaiConfiguration.executableURL() else { return [] }
            let process = Process()
            let output = Pipe()
            process.executableURL = executable
            process.arguments = ["-m", "query", "--windows"]
            process.standardOutput = output
            process.standardError = FileHandle.nullDevice
            // macpp:silent-ok yabai may be unavailable while the catalog is being queried
            do { try process.run() } catch { return [] }
            data = output.fileHandleForReading.readDataToEndOfFile()
            process.waitUntilExit()
            guard process.terminationStatus == 0 else { return [] }
        }
        // macpp:silent-ok malformed yabai output is treated as an empty catalog
        guard let values = try? JSONSerialization.jsonObject(with: data) as? [[String: Any]] else { return [] }
        return values.prefix(maximumWindows).compactMap { value in
            guard let id = (value["id"] as? NSNumber)?.intValue else { return nil }
            let app = String((value["app"] as? String ?? "Unknown").prefix(128))
            let title = String((value["title"] as? String ?? "").prefix(256))
            let space = String(describing: value["space"] ?? "—")
            let display = String(describing: value["display"] ?? "—")
            let canMove = (value["can-move"] as? NSNumber)?.boolValue
                ?? (value["has-ax-reference"] as? NSNumber)?.boolValue
                ?? true
            return MacPlusPlusWindowEntry(
                id: id, app: app, title: title, space: space, display: display,
                focused: (value["focused"] as? NSNumber)?.boolValue ?? false,
                canMove: canMove
            )
        }
    }

    static func search(_ query: MacPlusPlusWindowQuery, values: [MacPlusPlusWindowEntry] = load()) -> [MacPlusPlusWindowEntry] {
        let scored = values.compactMap { value -> (MacPlusPlusWindowEntry, Int)? in
            guard let score = MacPlusPlusSearchText.score(query: query.term, candidate: value.searchText) else {
                return nil
            }
            return (value, score)
        }
        return scored
            .sorted {
                if $0.1 != $1.1 { return $0.1 < $1.1 }
                if $0.0.focused != $1.0.focused { return $0.0.focused }
                if $0.0.app.caseInsensitiveCompare($1.0.app) != .orderedSame {
                    return $0.0.app.localizedCaseInsensitiveCompare($1.0.app) == .orderedAscending
                }
                return $0.0.title.localizedCaseInsensitiveCompare($1.0.title) == .orderedAscending
            }
            .prefix(maximumResults)
            .map(\.0)
    }
}

struct MacPlusPlusPickerQuery: Equatable, Sendable {
    let namespace: MacPlusPlusPickerNamespace
    let term: String

    static func parse(_ raw: String) -> MacPlusPlusPickerQuery? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let aliases: [(String, MacPlusPlusPickerNamespace)] = [
            ("keybinds", .keybinds), ("keybind", .keybinds), ("shortcuts", .keybinds),
            ("shortcut", .keybinds), ("keys", .keybinds),
            ("emoji", .emoji), ("emojis", .emoji),
            ("symbols", .symbols), ("symbol", .symbols), ("sf", .symbols)
        ]
        let lowered = trimmed.lowercased()
        for (alias, namespace) in aliases {
            if lowered == alias { return MacPlusPlusPickerQuery(namespace: namespace, term: "") }
            guard lowered.hasPrefix(alias + " ") else { continue }
            let start = trimmed.index(trimmed.startIndex, offsetBy: alias.count)
            return MacPlusPlusPickerQuery(
                namespace: namespace,
                term: String(trimmed[start...]).trimmingCharacters(in: .whitespacesAndNewlines)
            )
        }
        return nil
    }
}

enum MacPlusPlusPickerCatalogError: Error, CustomStringConvertible {
    case unreadable(String)
    case invalid(String)

    var description: String {
        switch self {
        case .unreadable(let detail): return "picker catalog is unreadable: \(detail)"
        case .invalid(let detail): return "picker catalog is invalid: \(detail)"
        }
    }
}

struct MacPlusPlusPickerEntry: Codable, Hashable, Sendable {
    let value: String
    let name: String
    let keywords: [String]

    var searchText: String {
        ([value, name] + keywords).joined(separator: " ").folding(
            options: [.caseInsensitive, .diacriticInsensitive],
            locale: Locale(identifier: "en_US_POSIX")
        ).lowercased()
    }
}

struct MacPlusPlusPickerCatalog: Sendable {
    static let maximumEntriesPerKind = 160
    static let maximumResults = 48
    static let maximumResourceBytes = 256 * 1_024

    let emoji: [MacPlusPlusPickerEntry]
    let symbols: [MacPlusPlusPickerEntry]

    private struct Document: Decodable {
        let schemaVersion: Int
        let emoji: [MacPlusPlusPickerEntry]
        let symbols: [MacPlusPlusPickerEntry]

        enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case emoji
            case symbols
        }
    }

    static func load(from url: URL) throws -> MacPlusPlusPickerCatalog {
        let data: Data
        do {
            let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
            guard values.isRegularFile == true else {
                throw MacPlusPlusPickerCatalogError.unreadable("not a regular file")
            }
            guard let size = values.fileSize, size > 0, size <= maximumResourceBytes else {
                throw MacPlusPlusPickerCatalogError.invalid("resource exceeds the \(maximumResourceBytes)-byte limit")
            }
            data = try Data(contentsOf: url, options: [.mappedIfSafe])
        } catch let error as MacPlusPlusPickerCatalogError {
            throw error
        } catch {
            throw MacPlusPlusPickerCatalogError.unreadable(error.localizedDescription)
        }

        let document: Document
        do {
            document = try JSONDecoder().decode(Document.self, from: data)
        } catch {
            throw MacPlusPlusPickerCatalogError.invalid(error.localizedDescription)
        }
        guard document.schemaVersion == 1 else {
            throw MacPlusPlusPickerCatalogError.invalid("unsupported schema version")
        }
        try validate(document.emoji, kind: "emoji")
        try validate(document.symbols, kind: "symbols")
        return MacPlusPlusPickerCatalog(emoji: document.emoji, symbols: document.symbols)
    }

    static func loadProduction(
        bundle: Bundle = .main,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) throws -> MacPlusPlusPickerCatalog {
        let root = productionRoot(homeDirectory: homeDirectory)
        let candidates = [
            bundle.url(forResource: "MacPlusPlusPickerCatalog", withExtension: "json"),
            root
                .appendingPathComponent("Source/MacPlusPlusCast/Resources", isDirectory: true)
                .appendingPathComponent("MacPlusPlusPickerCatalog.json")
        ].compactMap { $0 }
        guard let existing = candidates.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
            throw MacPlusPlusPickerCatalogError.unreadable("MacPlusPlusPickerCatalog.json was not found")
        }
        return try load(from: existing)
    }

    static func productionRoot(homeDirectory: URL) -> URL {
        guard let configured = ProcessInfo.processInfo.environment["MACPP_ROOT"],
              !configured.isEmpty else {
            return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
        }
        let candidate = URL(fileURLWithPath: configured, isDirectory: true)
        return FileManager.default.fileExists(atPath: candidate.appendingPathComponent("config/public-shell.json").path)
            ? candidate
            : URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
    }

    func searchEmoji(_ query: String, limit: Int = maximumResults) -> [MacPlusPlusPickerEntry] {
        Self.search(emoji, query: query, limit: limit)
    }

    func searchSymbols(_ query: String, limit: Int = maximumResults) -> [MacPlusPlusPickerEntry] {
        Self.search(symbols, query: query, limit: limit)
    }

    private static func validate(_ entries: [MacPlusPlusPickerEntry], kind: String) throws {
        guard !entries.isEmpty, entries.count <= maximumEntriesPerKind else {
            throw MacPlusPlusPickerCatalogError.invalid("\(kind) must contain 1...\(maximumEntriesPerKind) entries")
        }
        var values = Set<String>()
        for entry in entries {
            let name = entry.name.trimmingCharacters(in: .whitespacesAndNewlines)
            let value = entry.value.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 80, !value.isEmpty, value.count <= 80,
                  entry.keywords.count <= 12,
                  entry.keywords.allSatisfy({ !$0.isEmpty && $0.count <= 40 }) else {
                throw MacPlusPlusPickerCatalogError.invalid("malformed \(kind) entry \(entry.name)")
            }
            guard values.insert(value).inserted else {
                throw MacPlusPlusPickerCatalogError.invalid("duplicate \(kind) value \(value)")
            }
        }
    }

    private static func search(
        _ entries: [MacPlusPlusPickerEntry],
        query: String,
        limit: Int
    ) -> [MacPlusPlusPickerEntry] {
        let normalized = MacPlusPlusSearchText.normalize(query)
        let tokens = MacPlusPlusSearchText.tokens(query)
        let cappedLimit = max(1, min(limit, maximumResults))
        guard !tokens.isEmpty else { return Array(entries.prefix(cappedLimit)) }

        return entries.compactMap { entry -> (MacPlusPlusPickerEntry, Int)? in
            guard let score = MacPlusPlusSearchText.score(
                query: normalized,
                candidate: entry.searchText,
                aliases: entry.keywords
            ) else { return nil }
            return (entry, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            return $0.0.name.localizedCaseInsensitiveCompare($1.0.name) == .orderedAscending
        }
        .prefix(cappedLimit)
        .map(\.0)
    }
}

enum MacPlusPlusKeybindScope: String, Sendable {
    case work = "WORK"
    case game = "GAME"
}

struct MacPlusPlusKeybindSource: Sendable {
    let url: URL
    let scope: MacPlusPlusKeybindScope
}

struct MacPlusPlusKeybind: Hashable, Sendable {
    let id: String
    let scope: MacPlusPlusKeybindScope
    let sourceName: String
    let line: Int
    let chord: String
    let displayChord: String
    let command: String
    let section: String
    let summary: String

    var searchText: String {
        [scope.rawValue, sourceName, chord, displayChord, command, section, summary]
            .joined(separator: " ")
            .lowercased()
    }
}

struct MacPlusPlusKeybindLoadResult: Sendable {
    let keybinds: [MacPlusPlusKeybind]
    let issues: [String]
}

enum MacPlusPlusKeybindParser {
    static let maximumFileBytes = 256 * 1_024
    static let maximumBindings = 256
    static let maximumLineLength = 4_096

    static func productionSources(
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser,
        repositoryRoot: URL? = nil
    ) -> [MacPlusPlusKeybindSource] {
        let root = repositoryRoot ?? MacPlusPlusPickerCatalog.productionRoot(homeDirectory: homeDirectory)
        return [
            MacPlusPlusKeybindSource(url: homeDirectory.appendingPathComponent(".skhdrc"), scope: .work),
            MacPlusPlusKeybindSource(url: root.appendingPathComponent("config/skhd-game-mode.conf"), scope: .game)
        ]
    }

    static func load(sources: [MacPlusPlusKeybindSource]) -> MacPlusPlusKeybindLoadResult {
        var keybinds: [MacPlusPlusKeybind] = []
        var issues: [String] = []
        for source in sources {
            do {
                let values = try source.url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                guard values.isRegularFile == true else {
                    issues.append("\(source.url.lastPathComponent) is not a regular file")
                    continue
                }
                guard let size = values.fileSize, size <= maximumFileBytes else {
                    issues.append("\(source.url.lastPathComponent) exceeds \(maximumFileBytes) bytes")
                    continue
                }
                let text = try String(contentsOf: source.url, encoding: .utf8)
                let remaining = max(0, maximumBindings - keybinds.count)
                keybinds.append(contentsOf: parse(text, source: source, limit: remaining))
            } catch {
                issues.append("\(source.url.lastPathComponent): \(error.localizedDescription)")
            }
            if keybinds.count >= maximumBindings { break }
        }
        return MacPlusPlusKeybindLoadResult(keybinds: keybinds, issues: issues)
    }

    static func parse(_ text: String, source: MacPlusPlusKeybindSource, limit: Int = maximumBindings) -> [MacPlusPlusKeybind] {
        guard limit > 0 else { return [] }
        let physicalLines = text.components(separatedBy: .newlines)
        var bindings: [MacPlusPlusKeybind] = []
        var pendingComments: [String] = []
        var section = source.scope == .work ? "Work shortcuts" : "Game shortcuts"
        var index = 0

        while index < physicalLines.count, bindings.count < min(limit, maximumBindings) {
            let lineNumber = index + 1
            var raw = physicalLines[index]
            index += 1
            guard raw.count <= maximumLineLength else { continue }
            var trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                pendingComments.removeAll()
                continue
            }
            if trimmed.hasPrefix("#") {
                let comment = String(trimmed.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !comment.isEmpty { pendingComments.append(comment) }
                continue
            }

            while trimmed.hasSuffix("\\"), index < physicalLines.count {
                raw.removeLast()
                let continuation = physicalLines[index]
                index += 1
                guard continuation.count <= maximumLineLength else { break }
                raw += " " + continuation.trimmingCharacters(in: .whitespacesAndNewlines)
                trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            }

            guard let colon = bindingSeparator(in: trimmed) else {
                pendingComments.removeAll()
                continue
            }
            let chord = String(trimmed[..<colon]).trimmingCharacters(in: .whitespacesAndNewlines)
            let commandStart = trimmed.index(after: colon)
            let command = String(trimmed[commandStart...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard !chord.isEmpty, !command.isEmpty else {
                pendingComments.removeAll()
                continue
            }

            if pendingComments.count == 1,
               isSectionComment(pendingComments[0]) {
                section = sentenceCase(pendingComments[0])
            }
            let commentSummary = pendingComments.count > 1
                ? pendingComments.joined(separator: " ")
                : nil
            let summary = conciseSummary(command: command, comments: commentSummary)
            let identifier = "\(source.scope.rawValue.lowercased()):\(source.url.lastPathComponent):\(lineNumber):\(chord)"
            bindings.append(MacPlusPlusKeybind(
                id: identifier,
                scope: source.scope,
                sourceName: source.url.lastPathComponent,
                line: lineNumber,
                chord: chord,
                displayChord: displayChord(chord),
                command: command,
                section: section,
                summary: summary
            ))
            pendingComments.removeAll()
        }
        return bindings
    }

    static func search(_ keybinds: [MacPlusPlusKeybind], query: String, limit: Int = 48) -> [MacPlusPlusKeybind] {
        let normalized = MacPlusPlusSearchText.normalize(query)
        let tokens = MacPlusPlusSearchText.tokens(query)
        let capped = max(1, min(limit, 48))
        guard !tokens.isEmpty else { return Array(keybinds.prefix(capped)) }
        return keybinds.compactMap { binding -> (MacPlusPlusKeybind, Int)? in
            guard let score = MacPlusPlusSearchText.score(
                query: normalized,
                candidate: binding.searchText,
                aliases: [binding.summary, binding.section]
            ) else { return nil }
            return (binding, score)
        }
        .sorted {
            if $0.1 != $1.1 { return $0.1 < $1.1 }
            if $0.0.scope != $1.0.scope { return $0.0.scope.rawValue < $1.0.scope.rawValue }
            return $0.0.line < $1.0.line
        }
        .prefix(capped)
        .map(\.0)
    }

    private static func bindingSeparator(in line: String) -> String.Index? {
        var escaped = false
        for index in line.indices {
            let character = line[index]
            if character == "\\" { escaped.toggle(); continue }
            if character == ":", !escaped { return index }
            escaped = false
        }
        return nil
    }

    private static func isSectionComment(_ comment: String) -> Bool {
        comment.count <= 52
            && !comment.contains(":")
            && !comment.hasSuffix(".")
            && !comment.lowercased().hasPrefix("the ")
    }

    private static func sentenceCase(_ value: String) -> String {
        guard let first = value.first else { return value }
        return first.uppercased() + String(value.dropFirst())
    }

    private static func displayChord(_ raw: String) -> String {
        let aliases: [String: String] = [
            "cmd": "⌘", "command": "⌘", "alt": "⌥", "option": "⌥",
            "ctrl": "⌃", "control": "⌃", "shift": "⇧", "fn": "fn"
        ]
        let keyAliases: [String: String] = [
            "space": "Space", "return": "Return", "enter": "Return", "tab": "Tab",
            "escape": "Esc", "esc": "Esc", "delete": "Delete", "backspace": "Delete",
            "left": "←", "right": "→", "up": "↑", "down": "↓"
        ]
        let pieces = raw
            .replacingOccurrences(of: "+", with: " ")
            .replacingOccurrences(of: "-", with: " ")
            .split(whereSeparator: \.isWhitespace)
            .map { String($0).lowercased() }
        guard let key = pieces.last else { return raw }
        let modifiers = pieces.dropLast().compactMap { aliases[$0] }.joined()
        let renderedKey = keyAliases[key] ?? key.uppercased()
        return modifiers + renderedKey
    }

    private static func conciseSummary(command: String, comments: String?) -> String {
        if let comments {
            let compact = comments.replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            if compact.count <= 96 { return sentenceCase(compact) }
        }
        let lower = command.lowercased()
        if let match = capture(#"window --focus (west|east|north|south)"#, in: lower) {
            return "Focus window \(match)"
        }
        if let match = capture(#"window --swap (west|east|north|south)"#, in: lower) {
            return "Swap window \(match)"
        }
        if let match = capture(#"window --space ([0-9]+)"#, in: lower) {
            return lower.contains("space --focus") ? "Move window to space \(match) and follow" : "Move window to space \(match)"
        }
        if let match = capture(#"space --focus ([0-9]+)"#, in: lower) { return "Focus space \(match)" }
        if lower.contains("zoom-fullscreen") { return "Toggle window fullscreen" }
        if lower.contains("zoom-parent") { return "Toggle parent zoom" }
        if lower.contains("--toggle float") { return "Toggle floating window" }
        if lower.contains("space --balance") { return "Balance tiled windows" }
        if lower.contains("space --rotate") { return "Rotate tiled layout" }
        if lower.contains("--toggle split") { return "Toggle split direction" }
        if lower.contains("macpp-cast-open") { return "Open Search" }
        if lower.contains("macpp-mission-control") { return "Open Mission Control" }
        if lower.contains("quick-peek-open") { return "Open Quick Peek" }
        if lower.contains("restart-macpp") { return "Restart shell services" }
        if lower.contains("dismiss-surfaces") { return "Dismiss a stuck shell surface" }
        let executable = command.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? command
        return URL(fileURLWithPath: executable).deletingPathExtension().lastPathComponent
            .replacingOccurrences(of: "-", with: " ")
            .capitalized
    }

    private static func capture(_ pattern: String, in value: String) -> String? {
        // Fixed parser literals are exercised by the production-backed tests.
        // macpp:silent-ok an invalid future literal only disables its optional summary
        guard let expression = try? NSRegularExpression(pattern: pattern),
              let match = expression.firstMatch(in: value, range: NSRange(value.startIndex..., in: value)),
              match.numberOfRanges > 1,
              let range = Range(match.range(at: 1), in: value) else { return nil }
        return String(value[range])
    }
}
