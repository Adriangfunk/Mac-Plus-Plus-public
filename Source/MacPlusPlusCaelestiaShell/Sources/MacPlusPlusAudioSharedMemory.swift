import Foundation
import Darwin

@_silgen_name("macpp_audio_shared_open_reader")
private func macppAudioSharedOpenReader(_ name: UnsafePointer<CChar>) -> Int32

/// Reader for the audio producer's POSIX shared-memory snapshot.
///
/// The producer owns the object and publishes complete JSON frames with a
/// seqlock.  Opening/mapping it for the short duration of a shell sample is
/// deliberate: if the producer is restarted, the old object cannot remain
/// pinned in this process and the next sample automatically attaches to the
/// replacement.
final class MacPlusPlusAudioSharedMemory {
    static let shared = MacPlusPlusAudioSharedMemory()

    private let name = "/macpp.audio.v1"
    private let magic: UInt32 = 0x52414345
    private let version: UInt32 = 1
    private let headerSize = 24
    private let jsonCapacity = 16_384
    private let mappingSize = 24 + 16_384

    func readJSON() -> [String: Any]? {
        name.withCString { path in
            let descriptor = macppAudioSharedOpenReader(path)
            guard descriptor >= 0 else { return nil }
            defer { close(descriptor) }

            // The producer unlinks and recreates this object during a restart.
            // There is a short interval in which the new descriptor exists but
            // has not reached the published state size yet. Mapping the full
            // snapshot before checking that size can succeed and then fault
            // with SIGBUS when the reader touches a page past EOF.
            var attributes = stat()
            guard fstat(descriptor, &attributes) == 0,
                  attributes.st_size >= off_t(mappingSize) else {
                return nil
            }
            let mapped = mmap(nil, mappingSize, PROT_READ, MAP_SHARED,
                              descriptor, 0)
            guard let base = mapped,
                  base != UnsafeMutableRawPointer(bitPattern: -1) else {
                return nil
            }
            defer { munmap(base, mappingSize) }

            @inline(__always) func load32(_ offset: Int) -> UInt32 {
                base.advanced(by: offset).loadUnaligned(as: UInt32.self)
            }
            @inline(__always) func load64(_ offset: Int) -> UInt64 {
                base.advanced(by: offset).loadUnaligned(as: UInt64.self)
            }

            guard load32(0) == magic, load32(4) == version else { return nil }
            for _ in 0..<4 {
                let before = load64(8)
                if before & 1 != 0 { continue }
                OSMemoryBarrier()
                let length = Int(load32(16))
                guard length > 0, length <= jsonCapacity else { return nil }
                let bytes = Data(bytes: base.advanced(by: headerSize), count: length)
                OSMemoryBarrier()
                let after = load64(8)
                guard before == after, after & 1 == 0 else { continue }
        return (try? JSONSerialization.jsonObject(with: bytes)) as? [String: Any] // macpp:silent-ok malformed shared-memory payload is treated as unavailable
            }
            return nil
        }
    }
}
