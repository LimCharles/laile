import Foundation

public enum WeightBearingStatus: String, Codable, Sendable, CaseIterable, Hashable {
    case full, partial, none

    public var label: String {
        switch self {
        case .full: return "Full weight-bearing"
        case .partial: return "Partial weight-bearing"
        case .none: return "Non-weight-bearing"
        }
    }
}

/// Limits the clinician sets. Enforced in code on every program and stream.
public struct Precautions: Codable, Sendable, Hashable {
    /// Maximum clinical knee flexion in degrees (0 = straight).
    public var maxKneeFlexion: Double?
    /// Maximum clinical hip flexion in degrees (e.g. 90 for posterior hip precautions).
    public var maxHipFlexion: Double?
    public var weightBearing: WeightBearingStatus
    public var maxImpact: ImpactLevel
    public var noWristLoading: Bool
    public var avoidExerciseIds: [String]
    public var affectedSide: Side?
    public var notes: String

    public init(maxKneeFlexion: Double? = nil, maxHipFlexion: Double? = nil, weightBearing: WeightBearingStatus = .full,
                maxImpact: ImpactLevel = .high, noWristLoading: Bool = false, avoidExerciseIds: [String] = [],
                affectedSide: Side? = nil, notes: String = "") {
        self.maxKneeFlexion = maxKneeFlexion
        self.maxHipFlexion = maxHipFlexion
        self.weightBearing = weightBearing
        self.maxImpact = maxImpact
        self.noWristLoading = noWristLoading
        self.avoidExerciseIds = avoidExerciseIds
        self.affectedSide = affectedSide
        self.notes = notes
    }

    public static let none = Precautions()
}

public enum ProgramItemSource: String, Codable, Sendable, Hashable {
    case clinician, aiDraft, template
}

public struct ProgramItem: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var exerciseId: String
    public var dose: Dose
    public var timesPerDay: Int
    /// Clinician's knee-flexion target for this exercise (clinical degrees).
    public var targetKneeFlexion: Double?
    public var rationale: String
    public var source: ProgramItemSource

    public init(id: UUID = UUID(), exerciseId: String, dose: Dose, timesPerDay: Int = 1, targetKneeFlexion: Double? = nil,
                rationale: String = "", source: ProgramItemSource) {
        self.id = id
        self.exerciseId = exerciseId
        self.dose = dose
        self.timesPerDay = timesPerDay
        self.targetKneeFlexion = targetKneeFlexion
        self.rationale = rationale
        self.source = source
    }
}

public enum ProgramStatus: String, Codable, Sendable, Hashable {
    case draft, signed, archived
}

public struct Program: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var title: String
    public var patientId: UUID?
    public var items: [ProgramItem]
    public var precautions: Precautions
    public var painStopSetAbove: Int
    public var status: ProgramStatus
    public var version: Int
    public var createdAt: Date
    public var signedAt: Date?
    public var signedBy: String?
    /// Who produced the first draft: "hunyuan", "rule-based template", or a clinician's name.
    public var draftedBy: String
    public var summary: String
    /// Items the drafter proposed that the safety check removed, with the reason.
    public var blockedSuggestions: [ProgramViolation]

    public init(id: UUID = UUID(), title: String, patientId: UUID? = nil, items: [ProgramItem], precautions: Precautions,
                painStopSetAbove: Int = 4, status: ProgramStatus = .draft, version: Int = 1, createdAt: Date = Date(),
                signedAt: Date? = nil, signedBy: String? = nil, draftedBy: String, summary: String = "",
                blockedSuggestions: [ProgramViolation] = []) {
        self.id = id
        self.title = title
        self.patientId = patientId
        self.items = items
        self.precautions = precautions
        self.painStopSetAbove = painStopSetAbove
        self.status = status
        self.version = version
        self.createdAt = createdAt
        self.signedAt = signedAt
        self.signedBy = signedBy
        self.draftedBy = draftedBy
        self.summary = summary
        self.blockedSuggestions = blockedSuggestions
    }

    public var symptomPolicy: SymptomPolicy {
        SymptomPolicy(painStopSetAbove: painStopSetAbove, painStopExerciseAt: min(10, max(painStopSetAbove + 2, 6)), mode: .rehab)
    }

    /// Turn program items into conductor-ready planned exercises.
    public func plan(library: ExerciseLibrary = .standard) -> [PlannedExercise] {
        items.compactMap { item in
            guard let spec = library.spec(item.exerciseId) else { return nil }
            var override: Double?
            if spec.tracksKneeFlexion, case .reps(let rule) = spec.kind {
                // Clinical flexion (0° = straight) = 180 − interior angle. The rep-counting
                // threshold may be lowered (clinician target or precaution cap) but never raised:
                // a higher clinician target is a goal shown on progress, not a bar a rep must clear.
                let defaultFlexion = 180 - rule.target
                let flexion = [defaultFlexion, item.targetKneeFlexion, precautions.maxKneeFlexion].compactMap { $0 }.min() ?? defaultFlexion
                if flexion < defaultFlexion - 0.5 { override = 180 - flexion }
            }
            return PlannedExercise(spec: spec, dose: item.dose, side: precautions.affectedSide, repTargetOverride: override)
        }
    }
}

public struct ProgramViolation: Codable, Sendable, Hashable, Identifiable {
    public var id: String { "\(exerciseId)-\(rule)" }
    public var exerciseId: String
    public var rule: String
    public var message: String

    public init(exerciseId: String, rule: String, message: String) {
        self.exerciseId = exerciseId
        self.rule = rule
        self.message = message
    }
}

/// Hard safety rules. Anything that violates a precaution is blocked, not just warned about.
public enum ContraindicationChecker {
    public static func violations(spec: ExerciseSpec, item: ProgramItem? = nil, precautions: Precautions) -> [ProgramViolation] {
        var result: [ProgramViolation] = []
        func add(_ rule: String, _ message: String) {
            result.append(ProgramViolation(exerciseId: spec.id, rule: rule, message: message))
        }

        if precautions.avoidExerciseIds.contains(spec.id) {
            add("avoid-list", "\(spec.name) is on this patient's avoid list.")
        }
        switch precautions.weightBearing {
        case .none where spec.loads.weightBearing:
            add("weight-bearing", "\(spec.name) is weight-bearing; patient is non-weight-bearing.")
        case .partial where spec.loads.weightBearing && spec.loads.impact > .low:
            add("weight-bearing", "\(spec.name) is too much load for partial weight-bearing.")
        default:
            break
        }
        if spec.loads.impact > precautions.maxImpact {
            add("impact", "\(spec.name) is \(spec.loads.impact.label.lowercased()); limit is \(precautions.maxImpact.label.lowercased()).")
        }
        if let maxKnee = precautions.maxKneeFlexion {
            let demand = item?.targetKneeFlexion ?? spec.loads.peakKneeFlexion
            // Knee-tracked rep exercises can be capped by lowering their target instead of blocking.
            if demand > maxKnee && !(spec.tracksKneeFlexion && item?.targetKneeFlexion == nil) {
                add("knee-flexion", "\(spec.name) needs \(Int(demand))° knee bend; limit is \(Int(maxKnee))°.")
            }
        }
        if let maxHip = precautions.maxHipFlexion, spec.loads.peakHipFlexion > maxHip {
            add("hip-flexion", "\(spec.name) needs \(Int(spec.loads.peakHipFlexion))° hip bend; limit is \(Int(maxHip))°.")
        }
        if precautions.noWristLoading && spec.loads.loadsWrists {
            add("wrist", "\(spec.name) loads the wrists.")
        }
        return result
    }

    public static func violations(program: Program, library: ExerciseLibrary = .standard) -> [ProgramViolation] {
        program.items.flatMap { item -> [ProgramViolation] in
            guard let spec = library.spec(item.exerciseId) else {
                return [ProgramViolation(exerciseId: item.exerciseId, rule: "unknown", message: "\(item.exerciseId) is not in the exercise library.")]
            }
            return violations(spec: spec, item: item, precautions: program.precautions)
        }
    }

    /// Cleans a draft: drops unknown exercises, clamps doses into safe ranges, caps knee
    /// targets at the precaution limit, and removes anything contraindicated.
    public static func sanitize(items: [ProgramItem], precautions: Precautions, library: ExerciseLibrary = .standard) -> (items: [ProgramItem], blocked: [ProgramViolation]) {
        var kept: [ProgramItem] = []
        var blocked: [ProgramViolation] = []
        var seen = Set<String>()
        for var item in items {
            guard let spec = library.spec(item.exerciseId) else {
                blocked.append(ProgramViolation(exerciseId: item.exerciseId, rule: "unknown", message: "\(item.exerciseId) is not in the vetted exercise library."))
                continue
            }
            guard !seen.contains(spec.id) else { continue }
            item.dose = normalizedDose(item.dose, spec: spec)
            item.timesPerDay = item.timesPerDay.clamped(to: 1...4)
            if let limit = precautions.maxKneeFlexion, let target = item.targetKneeFlexion, target > limit, spec.tracksKneeFlexion {
                item.targetKneeFlexion = limit
            }
            let problems = violations(spec: spec, item: item, precautions: precautions)
            if problems.isEmpty {
                kept.append(item)
                seen.insert(spec.id)
            } else {
                blocked += problems
            }
        }
        return (kept, blocked)
    }

    static func normalizedDose(_ dose: Dose, spec: ExerciseSpec) -> Dose {
        var d = dose
        if spec.kind.isHold {
            d.reps = nil
            d.holdSeconds = d.holdSeconds ?? spec.defaultDose.holdSeconds
        } else {
            d.holdSeconds = nil
            d.reps = d.reps ?? spec.defaultDose.reps
        }
        return d.clamped(to: spec.limits)
    }
}
