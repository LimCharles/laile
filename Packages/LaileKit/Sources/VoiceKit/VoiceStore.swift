import Foundation
import LaileCore

/// Where a coach voice's audio comes from: the app bundle (`Cues/<voice>/`, pre-generated with
/// `generate-cues`), or the on-device cache of lines fetched from the server for voices that
/// aren't bundled.
public final class VoiceStore: @unchecked Sendable {
    public static let shared = VoiceStore()

    private let bundle: Bundle
    private let cacheRoot: URL
    private let lock = NSLock()
    private var inFlight = Set<String>()

    public init(bundle: Bundle = .main, cacheRoot: URL? = nil) {
        self.bundle = bundle
        self.cacheRoot = cacheRoot ?? FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("LaileVoice", isDirectory: true)
    }

    /// Playable file for this line in this voice, if we have one.
    public func url(for line: CueLine, voice: CoachVoice) -> URL? {
        if let bundled = bundle.url(forResource: line.audioKey, withExtension: "mp3", subdirectory: "Cues/\(voice.rawValue)") {
            return bundled
        }
        let cached = cacheFile(line, voice)
        return FileManager.default.fileExists(atPath: cached.path) ? cached : nil
    }

    public func store(_ data: Data, for line: CueLine, voice: CoachVoice) {
        let file = cacheFile(line, voice)
        try? FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? data.write(to: file, options: .atomic)
    }

    /// Fetches any lines we don't have yet (a few at a time). Returns how many are available.
    @discardableResult
    public func prefetch(_ lines: [CueLine], voice: CoachVoice, fetch: @escaping @Sendable (String, CoachVoice) async -> Data?,
                         progress: (@Sendable (Int, Int) -> Void)? = nil) async -> Int {
        let missing = lines.filter { url(for: $0, voice: voice) == nil && claim($0, voice) }
        var ready = lines.count - missing.count
        progress?(ready, lines.count)
        await withTaskGroup(of: Bool.self) { group in
            var iterator = missing.makeIterator()
            func addNext() {
                guard let line = iterator.next() else { return }
                group.addTask {
                    defer { self.release(line, voice) }
                    guard let data = await fetch(line.text, voice) else { return false }
                    self.store(data, for: line, voice: voice)
                    return true
                }
            }
            for _ in 0..<3 { addNext() }
            for await ok in group {
                if ok { ready += 1 }
                progress?(ready, lines.count)
                addNext()
            }
        }
        return ready
    }

    private func cacheFile(_ line: CueLine, _ voice: CoachVoice) -> URL {
        cacheRoot.appendingPathComponent(voice.rawValue, isDirectory: true).appendingPathComponent("\(line.audioKey).mp3")
    }

    private func claim(_ line: CueLine, _ voice: CoachVoice) -> Bool {
        lock.withLock { inFlight.insert("\(voice.rawValue)/\(line.audioKey)").inserted }
    }

    private func release(_ line: CueLine, _ voice: CoachVoice) {
        _ = lock.withLock { inFlight.remove("\(voice.rawValue)/\(line.audioKey)") }
    }
}
