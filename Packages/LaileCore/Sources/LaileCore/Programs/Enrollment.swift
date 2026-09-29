import Foundation

/// A person taking part in one program. Programs are the unit of everything in Laile:
/// a physio's private program (joined with their code), a catalog program, or one Lele built.
public struct Enrollment: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// Prescribed by a clinician, who supervises it and is the only one who can end it.
        case clinical
        /// Built by Lele from the person's goals.
        case personal
        /// From the Laile catalog.
        case catalog
    }

    public enum Status: String, Codable, Sendable, Hashable {
        case active, completed
    }

    public var id: UUID
    public var kind: Kind
    public var status: Status
    public var title: String
    public var subtitle: String
    /// What a session runs (the clinician's signed version, for clinical programs).
    public var program: Program
    public var catalogId: String?
    public var supervisorName: String?
    public var joinedAt: Date
    public var completedAt: Date?
    /// The clinician's note when they discharge someone.
    public var completionNote: String?
    /// Catalog program suggested to continue with after this one.
    public var followOnCatalogId: String?
    /// Personal targets from the first-session check-in. Nil until it's done.
    public var calibration: Calibration?

    public init(id: UUID = UUID(), kind: Kind, status: Status = .active, title: String, subtitle: String = "", program: Program,
                catalogId: String? = nil, supervisorName: String? = nil, joinedAt: Date = Date(), completedAt: Date? = nil,
                completionNote: String? = nil, followOnCatalogId: String? = nil, calibration: Calibration? = nil) {
        self.id = id
        self.kind = kind
        self.status = status
        self.title = title
        self.subtitle = subtitle
        self.program = program
        self.catalogId = catalogId
        self.supervisorName = supervisorName
        self.joinedAt = joinedAt
        self.completedAt = completedAt
        self.completionNote = completionNote
        self.followOnCatalogId = followOnCatalogId
        self.calibration = calibration
    }

    public var isActive: Bool { status == .active }
    public var isSupervised: Bool { kind == .clinical }
    /// The first session is a check-in that sets personal targets.
    public var needsCalibration: Bool { isActive && calibration == nil }

    /// The check-in session: each exercise once, done to a comfortable effort, so the camera can
    /// see where you are. Reps and holds are open-ended (you stop when it's enough); ranges are
    /// never pushed — pain above your limit still stops the set.
    public func calibrationPlan(precautions: Precautions = .none) -> [PlannedExercise] {
        let base = ContraindicationChecker.filter(program.plan(), precautions: precautions.merged(with: program.precautions)).kept
        return base.map { planned in
            var p = planned
            let limits = planned.spec.limits
            p.dose = Dose(
                sets: 1,
                reps: planned.spec.kind.isHold ? nil : min(20, limits.reps?.upperBound ?? 20),
                holdSeconds: planned.spec.kind.isHold ? min(60, limits.holdSeconds?.upperBound ?? 60) : nil,
                restSeconds: 20
            )
            return p
        }
    }

    /// A regular session: the program, bounded by the person's precautions, tuned to their check-in.
    public func sessionPlan(precautions: Precautions = .none) -> (plan: [PlannedExercise], removed: [ProgramViolation]) {
        let merged = precautions.merged(with: program.precautions)
        let (kept, removed) = ContraindicationChecker.filter(program.plan(), precautions: merged)
        guard let calibration else { return (kept, removed) }
        return (kept.map { calibration.apply(to: $0, supervised: isSupervised) }, removed)
    }
}

/// What the first session measured, per exercise.
public struct Calibration: Codable, Sendable, Hashable {
    public var measuredAt: Date
    public var exercises: [ExerciseCalibration]

    public init(measuredAt: Date, exercises: [ExerciseCalibration]) {
        self.measuredAt = measuredAt
        self.exercises = exercises
    }

    /// Reads a finished check-in session.
    public static func from(_ summary: SessionSummary, library: ExerciseLibrary = .standard) -> Calibration {
        let exercises = summary.exercises.compactMap { result -> ExerciseCalibration? in
            guard let spec = library.spec(result.exerciseId) else { return nil }
            var peak: Double?
            if case .reps(let rule) = spec.kind {
                // Furthest the joint went: smallest angle when bending, largest when lifting/straightening.
                peak = rule.isFlexion ? result.minAngle : result.maxAngle
            }
            let maxReps = result.repsPerSet.max()
            let bestHold = result.holdSecondsPerSet.max()
            guard maxReps != nil || bestHold != nil || peak != nil else { return nil }
            return ExerciseCalibration(exerciseId: spec.id, maxReps: maxReps, bestHoldSeconds: bestHold, peakAngle: peak,
                                       stoppedForSymptom: result.stopReason == .symptom)
        }
        return Calibration(measuredAt: summary.endedAt, exercises: exercises)
    }

    public func exercise(_ id: String) -> ExerciseCalibration? { exercises.first { $0.exerciseId == id } }

    /// Tunes one planned exercise to what the person showed they can comfortably do.
    /// Reps and holds are set to about 70% of their best (a working set, not a max test);
    /// supervised programs are only ever made easier than the clinician's dose, never harder.
    /// A rep counts at 90% of the range they reached, if that's short of the usual target.
    public func apply(to planned: PlannedExercise, supervised: Bool) -> PlannedExercise {
        guard let c = exercise(planned.spec.id) else { return planned }
        var p = planned
        let limits = planned.spec.limits
        if let reps = c.maxReps, reps > 0, let current = p.dose.reps {
            var personal = Int((Double(reps) * 0.7).rounded())
            if let range = limits.reps { personal = personal.clamped(to: range) }
            p.dose.reps = supervised ? min(current, personal) : personal
        }
        if let hold = c.bestHoldSeconds, hold > 0, let current = p.dose.holdSeconds {
            var personal = Int((Double(hold) * 0.7).rounded())
            if let range = limits.holdSeconds { personal = personal.clamped(to: range) }
            p.dose.holdSeconds = supervised ? min(current, personal) : personal
        }
        if let peak = c.peakAngle, let rule = p.repRule {
            let reached = abs(peak - rule.start)
            let usual = abs(rule.target - rule.start)
            if reached < usual {
                let counted = max(usual * 0.3, reached * 0.9) // never a trivially small rep
                p.repTargetOverride = rule.start + (rule.isFlexion ? -counted : counted)
            }
        }
        return p
    }
}

public struct ExerciseCalibration: Codable, Sendable, Hashable {
    public var exerciseId: String
    public var maxReps: Int?
    public var bestHoldSeconds: Int?
    /// Furthest interior angle reached (smallest when bending, largest when lifting).
    public var peakAngle: Double?
    public var stoppedForSymptom: Bool

    public init(exerciseId: String, maxReps: Int? = nil, bestHoldSeconds: Int? = nil, peakAngle: Double? = nil, stoppedForSymptom: Bool = false) {
        self.exerciseId = exerciseId
        self.maxReps = maxReps
        self.bestHoldSeconds = bestHoldSeconds
        self.peakAngle = peakAngle
        self.stoppedForSymptom = stoppedForSymptom
    }

    /// "Heel slides: 10 reps, knee bent to 85°" — for Lele and the clinician.
    public var summary: String {
        let spec = ExerciseLibrary.standard.spec(exerciseId)
        var parts: [String] = []
        if let maxReps { parts.append("\(maxReps) reps") }
        if let bestHoldSeconds { parts.append("\(bestHoldSeconds)s hold") }
        if let peakAngle, let spec, let angle = spec.kind.trackedAngle {
            if angle.vertex == .knee, spec.tracksKneeFlexion { parts.append("knee bent to \(Int((180 - peakAngle).rounded()))°") }
            else if angle == .armRaise { parts.append("arm lifted to \(Int(peakAngle.rounded()))°") }
        }
        if stoppedForSymptom { parts.append("stopped for discomfort") }
        return "\(spec?.name ?? exerciseId): " + (parts.isEmpty ? "done" : parts.joined(separator: ", "))
    }
}
