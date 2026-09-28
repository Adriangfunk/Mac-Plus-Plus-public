import AppKit

enum MacPlusPlusClipboardEntryKind {
    case text
    case image
}

struct MacPlusPlusClipboardEntry {
    let id: Int64
    let summary: String
    let createdAt: Date
    let byteCount: Int
    let isPinned: Bool
    let thumbnail: Data?
    let kind: MacPlusPlusClipboardEntryKind
}

struct MacPlusPlusClipboardSearchGeneration {
    private var value = 0

    mutating func advance() -> Int {
        value &+= 1
        return value
    }

    func accepts(_ candidate: Int) -> Bool { value == candidate }
}

/// Clipboard history is excluded from the public profile. This nil-only
/// controller keeps shared Search source type-checkable without pasteboard
/// access or persistent clip storage.
final class MacPlusPlusClipboardHistoryController {
    var isCaptureEnabled = false

    static func makeDefault() -> MacPlusPlusClipboardHistoryController? { nil }
    func start(_ onChange: @escaping () -> Void) {}
    func stop() {}
    func setCaptureEnabled(_ enabled: Bool) {}
    func clearAll(_ completion: @escaping (Bool) -> Void) { completion(false) }
    func copyEntry(id: Int64) -> Bool { false }
    func setPinned(_ pinned: Bool, id: Int64) -> Bool { false }
    func search(_ query: String, completion: @escaping ([MacPlusPlusClipboardEntry]) -> Void) {
        completion([])
    }
}
