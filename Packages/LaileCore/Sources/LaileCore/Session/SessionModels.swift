import Foundation

public struct PlannedExercise: Codable, Sendable, Hashable {
    public var spec: ExerciseSpec
    public var dose: Dose
    /// Side to track. Nil = the side the camera sees best.
    public var side: Side?
    /// Clinician override for the rep target (interior angle). Used to enforce knee limits.
    public var repTargetOverride: Double?

    public init(spec: ExerciseSpec, dose: Dose, side: Side? = nil, repTargetOverride: Double? = nil) {
        self.spec = spec
        self.dose = dose
        self.side = side
        self.repTargetOverride = repTargetOverride
    }

    public var repRule: RepRule? {
        guard case .reps(var rule) = spec.kind else { return nil }
        if let override = repTargetOverride { rule.target = override }
        return rule
    }
}

/// A line the coach says. Pre-generated audio is looked up by `audioKey` (a hash of the
/// text); `key` is a human-readable label for the audio manifest.
public struct CueLine: Codable, Sendable, Hashable {
    public enum Priority: Int, Codable, Sendable, Comparable {
        case low = 0, normal, high
        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var key: String?
    public var text: String
    public var priority: Priority

    public init(_ text: String, key: String? = nil, priority: Priority = .normal) {
        self.text = text
        self.key = key
        self.priority = priority
    }

    static let numberWords = ["zero", "one", "two", "three", "four", "five", "six", "seven", "eight", "nine", "ten",
                              "eleven", "twelve", "thirteen", "fourteen", "fifteen", "sixteen", "seventeen", "eighteen", "nineteen", "twenty"]

    public static func count(_ n: Int) -> CueLine {
        let text = n < numberWords.count ? numberWords[n].capitalized : "\(n)"
        return CueLine(text, key: "count.\(n)", priority: .low)
    }

    public static let go = CueLine("Go!", key: "cue.go")
    public static let holdIt = CueLine("Hold it there.", key: "cue.hold")
    public static let relax = CueLine("And relax.", key: "cue.relax")
    public static let niceWork = CueLine("Nice work.", key: "cue.nice-work")
    public static let rest = CueLine("Rest.", key: "cue.rest")
    public static let sessionDone = CueLine("That's the session done. Great work today.", key: "cue.session-done")
    public static let cantSee = CueLine("I can't see you clearly, so I'm not counting that. Check the camera.", key: "cue.cant-see")
    public static let paused = CueLine("Paused. Take your time.", key: "cue.paused")
}

public enum StopReason: String, Codable, Sendable, Hashable {
    case symptom, skipped, userEnded, redFlag
}

public struct ExerciseResult: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var exerciseId: String
    public var side: Side?
    public var plannedSets: Int
    public var repsPerSet: [Int]
    public var partialReps: Int
    public var holdSecondsPerSet: [Int]
    /// Smallest / largest tracked interior angle while active (verified frames only).
    public var minAngle: Double?
    public var maxAngle: Double?
    /// Peak angle of each counted rep.
    public var repPeakAngles: [Double]
    public var formWarnings: Int
    public var stopReason: StopReason?

    public init(id: UUID = UUID(), exerciseId: String, side: Side?, plannedSets: Int) {
        self.id = id
        self.exerciseId = exerciseId
        self.side = side
        self.plannedSets = plannedSets
        self.repsPerSet = []
        self.partialReps = 0
        self.holdSecondsPerSet = []
        self.repPeakAngles = []
        self.formWarnings = 0
    }

    public var completedSets: Int { max(repsPerSet.count, holdSecondsPerSet.count) }
    public var totalReps: Int { repsPerSet.reduce(0, +) }
    public var totalHoldSeconds: Int { holdSecondsPerSet.reduce(0, +) }
}

public struct SessionSummary: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case program, snack, workout, baseline, stream
    }

    public var id: UUID
    public var kind: Kind
    public var title: String
    public var mode: AppMode
    public var startedAt: Date
    public var endedAt: Date
    public var programId: UUID?
    public var templateId: String?
    public var streamId: UUID?
    public var exercises: [ExerciseResult]
    public var symptoms: [SymptomReport]
    public var painBefore: Int?
    public var painAfter: Int?
    public var escalation: EscalationLevel?

    public init(id: UUID = UUID(), kind: Kind, title: String, mode: AppMode, startedAt: Date, endedAt: Date,
                programId: UUID? = nil, templateId: String? = nil, streamId: UUID? = nil,
                exercises: [ExerciseResult] = [], symptoms: [SymptomReport] = [],
                painBefore: Int? = nil, painAfter: Int? = nil, escalation: EscalationLevel? = nil) {
        self.id = id
        self.kind = kind
        self.title = title
        self.mode = mode
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.programId = programId
        self.templateId = templateId
        self.streamId = streamId
        self.exercises = exercises
        self.symptoms = symptoms
        self.painBefore = painBefore
        self.painAfter = painAfter
        self.escalation = escalation
    }

    public var isBaseline: Bool { kind == .baseline }
    public var verifiedReps: Int { exercises.reduce(0) { $0 + $1.totalReps } }
    public var holdSeconds: Int { exercises.reduce(0) { $0 + $1.totalHoldSeconds } }
    public var durationSeconds: Int { max(0, Int(endedAt.timeIntervalSince(startedAt))) }
    public var isStretchOnly: Bool {
        let library = ExerciseLibrary.standard
        return !exercises.isEmpty && exercises.allSatisfy { library.spec($0.exerciseId)?.category == .stretch }
    }
}
