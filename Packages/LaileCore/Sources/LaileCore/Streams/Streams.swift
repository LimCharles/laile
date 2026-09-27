import Foundation

public enum StreamKind: String, Codable, Sendable, Hashable {
    /// A host broadcasts live over TRTC.
    case live
    /// Pre-recorded host video played in sync for everyone at a scheduled time.
    case premiere
}

public struct StreamSegment: Codable, Sendable, Hashable {
    public var exerciseId: String
    public var durationSeconds: Int
    /// Rest segments show "breathe" instead of counting.
    public var isRest: Bool
    public var coachLine: String?

    public init(exerciseId: String, durationSeconds: Int, isRest: Bool = false, coachLine: String? = nil) {
        self.exerciseId = exerciseId
        self.durationSeconds = durationSeconds
        self.isRest = isRest
        self.coachLine = coachLine
    }

    public static func rest(_ seconds: Int) -> StreamSegment {
        StreamSegment(exerciseId: "rest", durationSeconds: seconds, isRest: true, coachLine: "Shake it out and breathe.")
    }
}

/// A timed follow-along session: everyone does the same segment at the same wall-clock time.
public struct StreamEvent: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var hostName: String
    public var summary: String
    public var kind: StreamKind
    public var scheduledStart: Date
    public var segments: [StreamSegment]
    public var intensity: Int
    public var tags: [String]
    public var videoURL: URL?
    public var trtcRoomId: String?

    public init(id: UUID = UUID(), title: String, hostName: String, summary: String, kind: StreamKind, scheduledStart: Date,
                segments: [StreamSegment], intensity: Int, tags: [String] = [], videoURL: URL? = nil, trtcRoomId: String? = nil) {
        self.id = id
        self.title = title
        self.hostName = hostName
        self.summary = summary
        self.kind = kind
        self.scheduledStart = scheduledStart
        self.segments = segments
        self.intensity = intensity
        self.tags = tags
        self.videoURL = videoURL
        self.trtcRoomId = trtcRoomId
    }

    public var durationSeconds: Int { segments.reduce(0) { $0 + $1.durationSeconds } }
    public var endsAt: Date { scheduledStart.addingTimeInterval(TimeInterval(durationSeconds)) }
    public var minutes: Int { Int((Double(durationSeconds) / 60).rounded(.up)) }
}

public struct StreamPosition: Sendable, Equatable {
    public var segmentIndex: Int
    public var segmentElapsed: TimeInterval
    public var segmentRemaining: TimeInterval
    public var totalElapsed: TimeInterval
}

public enum StreamPhase: Sendable, Equatable {
    case upcoming(startsIn: TimeInterval)
    /// Within the lobby window before start: people gather, camera setup happens here.
    case lobby(startsIn: TimeInterval)
    case live(StreamPosition)
    case ended
}

public enum StreamClock {
    public static let lobbyWindow: TimeInterval = 5 * 60

    /// Where the stream is at `now`. Late joiners land in the right segment automatically.
    public static func phase(of stream: StreamEvent, at now: Date) -> StreamPhase {
        let offset = now.timeIntervalSince(stream.scheduledStart)
        if offset < -lobbyWindow { return .upcoming(startsIn: -offset) }
        if offset < 0 { return .lobby(startsIn: -offset) }
        var cursor: TimeInterval = 0
        for (index, segment) in stream.segments.enumerated() {
            let length = TimeInterval(segment.durationSeconds)
            if offset < cursor + length {
                return .live(StreamPosition(segmentIndex: index, segmentElapsed: offset - cursor,
                                            segmentRemaining: cursor + length - offset, totalElapsed: offset))
            }
            cursor += length
        }
        return .ended
    }
}

public enum StreamEligibility {
    /// Violations if this stream includes anything the person's precautions rule out.
    public static func violations(for stream: StreamEvent, precautions: Precautions, library: ExerciseLibrary = .standard) -> [ProgramViolation] {
        var seen = Set<String>()
        return stream.segments.filter { !$0.isRest }.flatMap { segment -> [ProgramViolation] in
            guard !seen.contains(segment.exerciseId), let spec = library.spec(segment.exerciseId) else { return [] }
            seen.insert(segment.exerciseId)
            return ContraindicationChecker.violations(spec: spec, precautions: precautions)
        }
    }
}

public struct LeaderboardEntry: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var displayName: String
    public var verifiedReps: Int
    public var isYou: Bool

    public init(id: String, displayName: String, verifiedReps: Int, isYou: Bool = false) {
        self.id = id
        self.displayName = displayName
        self.verifiedReps = verifiedReps
        self.isYou = isYou
    }
}

/// Messages on the stream WebSocket.
public enum StreamSocketMessage: Codable, Sendable, Hashable {
    /// Client → server: my verified rep total for this stream.
    case reps(total: Int)
    /// Server → client.
    case leaderboard(entries: [LeaderboardEntry], participants: Int)
}

/// A recurring demo schedule so there is always a stream live or starting soon.
public enum DemoStreams {
    static let hosts = ["Coach Mei", "Coach Arjun", "Coach Farah", "Coach Daniel"]

    static let formats: [(title: String, summary: String, intensity: Int, tags: [String], segments: [StreamSegment])] = [
        ("Lunch-break blast", "Seven fast minutes — no equipment, no excuses.", 3, ["cardio", "strength"], [
            StreamSegment(exerciseId: "jumping-jacks", durationSeconds: 45, coachLine: "Warm up — arms all the way up!"),
            .rest(15),
            StreamSegment(exerciseId: "squat", durationSeconds: 45, coachLine: "Sit back, chest up."),
            .rest(15),
            StreamSegment(exerciseId: "knee-push-up", durationSeconds: 40, coachLine: "Knees down is still a push-up."),
            .rest(20),
            StreamSegment(exerciseId: "reverse-lunge", durationSeconds: 45),
            .rest(15),
            StreamSegment(exerciseId: "plank", durationSeconds: 40, coachLine: "Squeeze everything."),
            .rest(20),
            StreamSegment(exerciseId: "high-knees", durationSeconds: 45, coachLine: "Last one — sprint it out!"),
        ]),
        ("Desk reset", "Five gentle minutes to undo a morning of sitting.", 1, ["stretch", "mobility", "gentle"], [
            StreamSegment(exerciseId: "neck-shoulder-rolls", durationSeconds: 45),
            StreamSegment(exerciseId: "chest-opener", durationSeconds: 45),
            StreamSegment(exerciseId: "sit-to-stand", durationSeconds: 60, coachLine: "Nice and controlled."),
            .rest(15),
            StreamSegment(exerciseId: "hamstring-stretch", durationSeconds: 60),
            StreamSegment(exerciseId: "glute-bridge", durationSeconds: 60),
        ]),
        ("Gentle knee class", "Low-impact moves suitable for most knees.", 1, ["gentle", "knee-friendly"], [
            StreamSegment(exerciseId: "sit-to-stand", durationSeconds: 60),
            .rest(20),
            StreamSegment(exerciseId: "glute-bridge", durationSeconds: 60),
            .rest(20),
            StreamSegment(exerciseId: "hamstring-stretch", durationSeconds: 60),
            StreamSegment(exerciseId: "chest-opener", durationSeconds: 45),
        ]),
    ]

    /// Streams every 20 minutes (rotating formats) from one hour ago to six hours ahead.
    public static func schedule(around now: Date, calendarTimeZone: TimeZone = .current) -> [StreamEvent] {
        let slot: TimeInterval = 20 * 60
        let base = (now.timeIntervalSince1970 / slot).rounded(.down) * slot
        return (-3...18).map { i -> StreamEvent in
            let start = Date(timeIntervalSince1970: base + Double(i) * slot)
            let slotNumber = Int(start.timeIntervalSince1970 / slot)
            let format = formats[((slotNumber % formats.count) + formats.count) % formats.count]
            let host = hosts[((slotNumber % hosts.count) + hosts.count) % hosts.count]
            return StreamEvent(
                id: deterministicUUID(slotNumber),
                title: format.title, hostName: host, summary: format.summary, kind: .premiere,
                scheduledStart: start, segments: format.segments, intensity: format.intensity, tags: format.tags
            )
        }
    }

    /// A stream that starts almost immediately — for trying streams without waiting for the
    /// schedule (demos, first-time users). Gentle format for rehab users.
    public static func practice(startingAt start: Date, gentle: Bool) -> StreamEvent {
        let format = gentle ? formats[2] : formats[0]
        return StreamEvent(title: "Practice: \(format.title)", hostName: "Coach Mei", summary: format.summary, kind: .premiere,
                           scheduledStart: start, segments: format.segments, intensity: format.intensity, tags: format.tags + ["practice"])
    }

    /// Stable ids so every device agrees which stream is which.
    static func deterministicUUID(_ n: Int) -> UUID {
        let hex = String(format: "%012llx", UInt64(bitPattern: Int64(n)))
        return UUID(uuidString: "5EA7C0DE-0000-4000-8000-\(hex.suffix(12))") ?? UUID()
    }
}
