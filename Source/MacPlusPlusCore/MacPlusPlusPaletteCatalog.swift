import Foundation

struct MacPlusPlusPalettePreset: Codable, Equatable, Sendable {
    let frame: String
    let panel: String
    let text: String
    let accent: String
    let nativeAccent: Int
    let nativeLabel: String

    private enum CodingKeys: String, CodingKey {
        case frame, panel, text, accent
        case nativeAccent = "native_accent"
        case nativeLabel = "native_label"
    }
}

/// Canonical built-in palette values shared by Shell and standalone Search.
/// Build products receive the same `config/palettes.json` as a resource; a
/// source-tree path is only a development fallback. Custom wallpaper palettes
/// remain dynamic and are intentionally not part of this catalog.
enum MacPlusPlusPaletteCatalog {
    private struct Document: Decodable {
        let schemaVersion: Int
        let `default`: String
        let dedicated: [String]
        let presets: [String: MacPlusPlusPalettePreset]

        private enum CodingKeys: String, CodingKey {
            case schemaVersion = "schema_version"
            case `default`, dedicated, presets
        }
    }

    private static let emergencyDefaultPreset = MacPlusPlusPalettePreset(
        frame: "080D19", panel: "02050B", text: "DDE9FF", accent: "6EA6FF",
        nativeAccent: 4, nativeLabel: "Blue"
    )

    // Minimal emergency set for a damaged/missing bundled resource. It keeps
    // Work readable, White accessible, and both isolated modes visibly red;
    // the complete built-in catalog still lives only in palettes.json.
    private static let emergencyDocument = Document(
        schemaVersion: 1,
        default: "midnight",
        dedicated: ["midnight", "white"],
        presets: [
            "midnight": emergencyDefaultPreset,
            "white": MacPlusPlusPalettePreset(
                frame: "F2F3F5", panel: "FFFFFF", text: "1D1D1F", accent: "7899C8",
                nativeAccent: 4, nativeLabel: "Blue"
            ),
            "game": MacPlusPlusPalettePreset(
                frame: "3A0B12", panel: "160408", text: "FFF0EC", accent: "FF3C55",
                nativeAccent: 0, nativeLabel: "Red"
            ),
        ]
    )

    private static let document: Document = {
        let environment = ProcessInfo.processInfo.environment["MACPP_PALETTE_CONFIG_PATH"]
            .map { URL(fileURLWithPath: $0) }
        let bundled = Bundle.main.url(forResource: "palettes", withExtension: "json")
        let candidates = [environment, bundled].compactMap { $0 }

        for candidate in candidates where FileManager.default.fileExists(atPath: candidate.path) {
            do {
                let value = try JSONDecoder().decode(
                    Document.self, from: Data(contentsOf: candidate)
                )
                guard value.schemaVersion == 1,
                      value.presets[value.default] != nil,
                      !value.dedicated.isEmpty,
                      value.dedicated.allSatisfy({ value.presets[$0] != nil }),
                      value.presets.values.allSatisfy(\MacPlusPlusPalettePreset.hasValidTokens) else {
                    throw NSError(
                        domain: "MacPlusPlusPaletteCatalog",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "unsupported schema or missing default"]
                    )
                }
                return value
            } catch {
                NSLog("MacPlusPlus palette catalog rejected %@: %@", candidate.path, String(describing: error))
            }
        }
        NSLog("MacPlusPlus palette catalog is unavailable; using the mode-safe emergency catalog")
        return emergencyDocument
    }()

    static var defaultName: String { document.default }
    static var dedicatedNames: [String] { document.dedicated }
    static var presetNames: [String] {
        Array(document.presets.keys).sorted()
    }

    static func preset(named name: String) -> MacPlusPlusPalettePreset? {
        document.presets[name]
    }

    static var defaultPreset: MacPlusPlusPalettePreset {
        document.presets[defaultName] ?? emergencyDefaultPreset
    }
}

private extension MacPlusPlusPalettePreset {
    var hasValidTokens: Bool {
        [frame, panel, text, accent].allSatisfy { token in
            token.count == 6 && token.allSatisfy(\.isHexDigit)
        }
    }
}
