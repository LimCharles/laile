import Foundation

public enum AppMode: String, Codable, Sendable, CaseIterable, Hashable {
    /// Clinician-prescribed home rehab.
    case rehab
    /// Self-directed quick calisthenics and stretching.
    case move
}

public enum ExerciseCategory: String, Codable, Sendable, CaseIterable, Hashable {
    case stretch, mobility, strength, cardio, circulation
}

public enum CameraView: String, Codable, Sendable, Hashable {
    case side, front, any
}

public enum Posture: String, Codable, Sendable, Hashable {
    case standing, seated, supine, plank, kneeling

    /// Camera placement advice for this posture.
    public var cameraTip: String {
        switch self {
        case .standing: return "Stand the phone up at waist height, about two to three metres away."
        case .seated: return "Put the phone at chair height, about two metres away."
        case .supine: return "Prop the phone on a chair beside your bed, level with the mattress."
        case .plank: return "Put the phone on the floor, about two metres to your side."
        case .kneeling: return "Put the phone low, about two metres away."
        }
    }
}

public enum ImpactLevel: Int, Codable, Sendable, Hashable, Comparable, CaseIterable {
    case none = 0, low, moderate, high

    public static func < (lhs: ImpactLevel, rhs: ImpactLevel) -> Bool { lhs.rawValue < rhs.rawValue }

    public var label: String {
        switch self {
        case .none: return "No impact"
        case .low: return "Low impact"
        case .moderate: return "Moderate impact"
        case .high: return "High impact"
        }
    }
}

public enum AngleCondition: Codable, Sendable, Hashable {
    case atLeast(Double)
    case atMost(Double)
    case between(Double, Double)

    public func isSatisfied(by angle: Double) -> Bool {
        switch self {
        case .atLeast(let v): return angle >= v
        case .atMost(let v): return angle <= v
        case .between(let lo, let hi): return angle >= lo && angle <= hi
        }
    }
}

/// A rep goes start → target → start on the tracked angle. Direction is implied by the
/// numbers (target < start for bending, target > start for straightening).
public struct RepRule: Codable, Sendable, Hashable {
    public var angle: AngleDefinition
    /// Interior angle (degrees) at the resting position.
    public var start: Double
    /// Interior angle (degrees) that must be reached for a full rep.
    public var target: Double
    /// Fraction of the range that counts as a "partial" rep (not counted, but coached).
    public var partialFraction: Double

    public init(angle: AngleDefinition, start: Double, target: Double, partialFraction: Double = 0.45) {
        self.angle = angle
        self.start = start
        self.target = target
        self.partialFraction = partialFraction
    }

    /// True when the rep bends the joint (interior angle decreases).
    public var isFlexion: Bool { target < start }
}

public struct HoldRule: Codable, Sendable, Hashable {
    /// Nil means presence-only: the camera confirms you're in frame and the timer runs.
    public var angle: AngleDefinition?
    public var condition: AngleCondition?
    /// Spoken when the condition isn't met and the timer pauses.
    public var correction: String?

    public init(angle: AngleDefinition? = nil, condition: AngleCondition? = nil, correction: String? = nil) {
        self.angle = angle
        self.condition = condition
        self.correction = correction
    }

    public static let presenceOnly = HoldRule()
}

public enum ExerciseKind: Codable, Sendable, Hashable {
    case reps(RepRule)
    case hold(HoldRule)

    public var trackedAngle: AngleDefinition? {
        switch self {
        case .reps(let rule): return rule.angle
        case .hold(let rule): return rule.angle
        }
    }

    public var isHold: Bool {
        if case .hold = self { return true }
        return false
    }
}

public struct FormCheck: Codable, Sendable, Hashable {
    public var id: String
    public var angle: AngleDefinition
    public var condition: AngleCondition
    public var cue: String

    public init(id: String, angle: AngleDefinition, condition: AngleCondition, cue: String) {
        self.id = id
        self.angle = angle
        self.condition = condition
        self.cue = cue
    }
}

public struct Dose: Codable, Sendable, Hashable {
    public var sets: Int
    public var reps: Int?
    public var holdSeconds: Int?
    public var restSeconds: Int

    public init(sets: Int, reps: Int? = nil, holdSeconds: Int? = nil, restSeconds: Int = 30) {
        self.sets = sets
        self.reps = reps
        self.holdSeconds = holdSeconds
        self.restSeconds = restSeconds
    }

    public func clamped(to limits: DoseLimits) -> Dose {
        Dose(
            sets: sets.clamped(to: limits.sets),
            reps: reps.map { limits.reps.map($0.clamped(to:)) ?? $0 } ?? nil,
            holdSeconds: holdSeconds.map { limits.holdSeconds.map($0.clamped(to:)) ?? $0 } ?? nil,
            restSeconds: restSeconds.clamped(to: limits.restSeconds)
        )
    }

    public var shortDescription: String {
        if let reps { return "\(sets) × \(reps)" }
        if let holdSeconds { return "\(sets) × \(holdSeconds)s" }
        return "\(sets) sets"
    }
}

/// Safe parameter ranges a clinician (or the AI drafter) may choose within.
public struct DoseLimits: Codable, Sendable, Hashable {
    public var sets: ClosedRange<Int>
    public var reps: ClosedRange<Int>?
    public var holdSeconds: ClosedRange<Int>?
    public var restSeconds: ClosedRange<Int>

    public init(sets: ClosedRange<Int>, reps: ClosedRange<Int>? = nil, holdSeconds: ClosedRange<Int>? = nil, restSeconds: ClosedRange<Int> = 5...120) {
        self.sets = sets
        self.reps = reps
        self.holdSeconds = holdSeconds
        self.restSeconds = restSeconds
    }
}

/// What an exercise demands of the body — used by the contraindication checker.
public struct ExerciseLoads: Codable, Sendable, Hashable {
    public var weightBearing: Bool
    public var impact: ImpactLevel
    /// Clinical knee flexion (0° = straight) reached at full range.
    public var peakKneeFlexion: Double
    /// Clinical hip flexion (0° = standing straight) reached at full range.
    public var peakHipFlexion: Double
    public var loadsWrists: Bool

    public init(weightBearing: Bool, impact: ImpactLevel, peakKneeFlexion: Double, peakHipFlexion: Double, loadsWrists: Bool = false) {
        self.weightBearing = weightBearing
        self.impact = impact
        self.peakKneeFlexion = peakKneeFlexion
        self.peakHipFlexion = peakHipFlexion
        self.loadsWrists = loadsWrists
    }
}

public struct ExerciseCues: Codable, Sendable, Hashable {
    /// Why this exercise matters, in plain language.
    public var purpose: String
    /// How to get into the start position.
    public var setup: String
    /// One-line movement instruction said right before the first rep.
    public var go: String

    public init(purpose: String, setup: String, go: String) {
        self.purpose = purpose
        self.setup = setup
        self.go = go
    }
}

/// How an exercise result turns into a tracked metric.
public enum MetricSource: String, Codable, Sendable, Hashable {
    /// Clinical flexion = 180 − smallest interior angle reached.
    case peakFlexionFromMinAngle
    /// Extension deficit = 180 − largest interior angle reached.
    case extensionDeficitFromMaxAngle
    /// Best set's verified rep count.
    case bestSetReps
    /// Best set's verified hold seconds.
    case bestSetHoldSeconds
}

public struct MetricBinding: Codable, Sendable, Hashable {
    public var kind: MetricKind
    public var source: MetricSource

    public init(_ kind: MetricKind, _ source: MetricSource) {
        self.kind = kind
        self.source = source
    }
}

public struct ExerciseSpec: Codable, Sendable, Hashable, Identifiable {
    public var id: String
    public var name: String
    public var modes: Set<AppMode>
    public var category: ExerciseCategory
    public var posture: Posture
    public var cameraView: CameraView
    public var kind: ExerciseKind
    public var formChecks: [FormCheck]
    public var defaultDose: Dose
    public var limits: DoseLimits
    public var loads: ExerciseLoads
    public var cues: ExerciseCues
    public var metric: MetricBinding?
    /// 1 (gentle) … 5 (hard).
    public var intensity: Int
    /// Progression family (e.g. "push-up") and order within it.
    public var family: String?
    public var familyLevel: Int?
    /// True when a two-sided exercise should be done on each side.
    public var perSide: Bool

    public init(
        id: String, name: String, modes: Set<AppMode>, category: ExerciseCategory, posture: Posture,
        cameraView: CameraView, kind: ExerciseKind, formChecks: [FormCheck] = [], defaultDose: Dose,
        limits: DoseLimits, loads: ExerciseLoads, cues: ExerciseCues, metric: MetricBinding? = nil,
        intensity: Int, family: String? = nil, familyLevel: Int? = nil, perSide: Bool = false
    ) {
        self.id = id
        self.name = name
        self.modes = modes
        self.category = category
        self.posture = posture
        self.cameraView = cameraView
        self.kind = kind
        self.formChecks = formChecks
        self.defaultDose = defaultDose
        self.limits = limits
        self.loads = loads
        self.cues = cues
        self.metric = metric
        self.intensity = intensity
        self.family = family
        self.familyLevel = familyLevel
        self.perSide = perSide
    }

    /// Body parts the camera must see for this exercise.
    public var requiredParts: [BodyPart] {
        var parts = Set<BodyPart>()
        kind.trackedAngle?.parts.forEach { parts.insert($0) }
        formChecks.forEach { $0.angle.parts.forEach { parts.insert($0) } }
        if parts.isEmpty { parts = [.shoulder, .hip] }
        return BodyPart.allCases.filter(parts.contains)
    }

    /// True when the tracked rep angle is the knee bending (so a clinician's
    /// knee-flexion limit can be enforced by lowering the rep target).
    public var tracksKneeFlexion: Bool {
        if case .reps(let rule) = kind, rule.angle.vertex == .knee, rule.isFlexion { return true }
        return false
    }
}

extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
