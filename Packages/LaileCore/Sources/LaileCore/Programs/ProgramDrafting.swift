import Foundation

public enum Procedure: String, Codable, Sendable, CaseIterable, Hashable {
    case totalKneeReplacement
    case totalHipReplacement
    case kneeOsteoarthritis
    case lowBackPain
    case generalDeconditioning
    case other

    public var label: String {
        switch self {
        case .totalKneeReplacement: return "Total knee replacement"
        case .totalHipReplacement: return "Total hip replacement"
        case .kneeOsteoarthritis: return "Knee osteoarthritis"
        case .lowBackPain: return "Low back pain"
        case .generalDeconditioning: return "General deconditioning"
        case .other: return "Other"
        }
    }
}

/// Everything a drafter (AI or template) may use to propose a program.
public struct PatientContext: Codable, Sendable, Hashable {
    public var displayName: String
    public var age: Int?
    public var procedure: Procedure
    public var procedureDate: Date?
    public var precautions: Precautions
    public var comorbidities: [String]
    public var goals: [String]
    public var clinicalNotes: String
    public var latestKneeFlexion: Double?

    public init(displayName: String, age: Int? = nil, procedure: Procedure, procedureDate: Date? = nil,
                precautions: Precautions, comorbidities: [String] = [], goals: [String] = [], clinicalNotes: String = "",
                latestKneeFlexion: Double? = nil) {
        self.displayName = displayName
        self.age = age
        self.procedure = procedure
        self.procedureDate = procedureDate
        self.precautions = precautions
        self.comorbidities = comorbidities
        self.goals = goals
        self.clinicalNotes = clinicalNotes
        self.latestKneeFlexion = latestKneeFlexion
    }

    public func daysSinceProcedure(now: Date) -> Int? {
        procedureDate.map { max(0, Int(now.timeIntervalSince($0) / 86_400)) }
    }
}

/// The JSON shape the LLM must return when drafting a program. Anything else is rejected.
public struct ProgramDraftResponse: Codable, Sendable, Hashable {
    public struct Item: Codable, Sendable, Hashable {
        public var exerciseId: String
        public var sets: Int
        public var reps: Int?
        public var holdSeconds: Int?
        public var restSeconds: Int?
        public var timesPerDay: Int?
        public var targetKneeFlexion: Double?
        public var rationale: String

        public init(exerciseId: String, sets: Int, reps: Int? = nil, holdSeconds: Int? = nil, restSeconds: Int? = nil,
                    timesPerDay: Int? = nil, targetKneeFlexion: Double? = nil, rationale: String) {
            self.exerciseId = exerciseId
            self.sets = sets
            self.reps = reps
            self.holdSeconds = holdSeconds
            self.restSeconds = restSeconds
            self.timesPerDay = timesPerDay
            self.targetKneeFlexion = targetKneeFlexion
            self.rationale = rationale
        }
    }

    public var title: String
    public var summary: String
    public var items: [Item]

    public init(title: String, summary: String, items: [Item]) {
        self.title = title
        self.summary = summary
        self.items = items
    }

    /// Validate and convert to a draft program (never signed — a clinician must sign).
    public func toProgram(context: PatientContext, patientId: UUID?, draftedBy: String, library: ExerciseLibrary = .standard) -> Program {
        let raw = items.map { item in
            ProgramItem(
                exerciseId: item.exerciseId,
                dose: Dose(sets: item.sets, reps: item.reps, holdSeconds: item.holdSeconds, restSeconds: item.restSeconds ?? 30),
                timesPerDay: item.timesPerDay ?? 1,
                targetKneeFlexion: item.targetKneeFlexion,
                rationale: item.rationale,
                source: .aiDraft
            )
        }
        let (kept, blocked) = ContraindicationChecker.sanitize(items: raw, precautions: context.precautions, library: library)
        return Program(title: title, patientId: patientId, items: kept, precautions: context.precautions,
                       status: .draft, draftedBy: draftedBy, summary: summary, blockedSuggestions: blocked)
    }
}

/// Deterministic protocol-based drafter. It's the fallback when the LLM is offline, and
/// it's also the reference the LLM's catalog is drawn from.
public enum TemplateDrafter {
    public static func draft(context: PatientContext, patientId: UUID?, now: Date = Date(), library: ExerciseLibrary = .standard) -> Program {
        let days = context.daysSinceProcedure(now: now) ?? 0
        var items: [ProgramDraftResponse.Item] = []
        var title = "Home program"
        var summary = ""

        switch context.procedure {
        case .totalKneeReplacement:
            let phase = days <= 14 ? 1 : (days <= 42 ? 2 : 3)
            title = "Knee replacement — phase \(phase)"
            let flexTarget = phase == 1 ? 90.0 : (phase == 2 ? 110 : 120)
            summary = "Day \(days) after knee replacement. Focus: \(phase == 1 ? "circulation, getting the knee straight, and regaining bend towards 90°" : phase == 2 ? "knee bend towards 110° and building standing strength" : "full function, strength and balance")."
            items.append(.init(exerciseId: "ankle-pumps", sets: 1, holdSeconds: 45, timesPerDay: phase == 1 ? 3 : 1, rationale: "Keeps blood moving to lower clot risk while activity is reduced."))
            items.append(.init(exerciseId: "quad-set", sets: 10, holdSeconds: 5, restSeconds: 5, timesPerDay: 2, rationale: "Restores full knee straightening and wakes up the quadriceps."))
            items.append(.init(exerciseId: "heel-slide", sets: 2, reps: 10, timesPerDay: 2, targetKneeFlexion: flexTarget, rationale: "Progressive knee bend towards \(Int(flexTarget))° to prevent stiffness."))
            items.append(.init(exerciseId: "straight-leg-raise", sets: 2, reps: 10, rationale: "Builds quadriceps strength without bending the knee."))
            if phase >= 2 {
                items.append(.init(exerciseId: "sit-to-stand", sets: 2, reps: 8, rationale: "Functional strength for getting out of chairs independently."))
                items.append(.init(exerciseId: "mini-squat", sets: 2, reps: 10, rationale: "Supported, shallow squats to build standing strength."))
                items.append(.init(exerciseId: "glute-bridge", sets: 2, reps: 10, rationale: "Hip strength to take load off the knee."))
            } else {
                items.append(.init(exerciseId: "long-arc-quad", sets: 2, reps: 10, rationale: "Seated knee straightening against gravity."))
            }
        case .totalHipReplacement:
            title = "Hip replacement — early phase"
            summary = "Day \(days) after hip replacement. Respect hip precautions; focus on circulation, glute and quadriceps activation."
            items.append(.init(exerciseId: "ankle-pumps", sets: 1, holdSeconds: 45, timesPerDay: 3, rationale: "Circulation to lower clot risk."))
            items.append(.init(exerciseId: "quad-set", sets: 10, holdSeconds: 5, restSeconds: 5, timesPerDay: 2, rationale: "Quadriceps activation."))
            items.append(.init(exerciseId: "glute-bridge", sets: 2, reps: 8, rationale: "Glute strength for walking stability."))
            items.append(.init(exerciseId: "heel-slide", sets: 2, reps: 10, rationale: "Gentle hip and knee movement within precautions."))
            items.append(.init(exerciseId: "sit-to-stand", sets: 2, reps: 6, rationale: "Functional transfers (use a high chair)."))
        case .kneeOsteoarthritis:
            title = "Knee strength program"
            summary = "Strengthening and mobility for knee osteoarthritis."
            items.append(.init(exerciseId: "quad-set", sets: 10, holdSeconds: 5, restSeconds: 5, rationale: "Quadriceps activation."))
            items.append(.init(exerciseId: "straight-leg-raise", sets: 2, reps: 12, rationale: "Quadriceps strength with low joint load."))
            items.append(.init(exerciseId: "sit-to-stand", sets: 3, reps: 10, rationale: "Functional leg strength."))
            items.append(.init(exerciseId: "glute-bridge", sets: 2, reps: 12, rationale: "Hip strength reduces knee load."))
            items.append(.init(exerciseId: "hamstring-stretch", sets: 2, holdSeconds: 30, rationale: "Maintains flexibility."))
        case .lowBackPain:
            title = "Back-friendly movement"
            summary = "Gentle core and hip work with mobility."
            items.append(.init(exerciseId: "glute-bridge", sets: 2, reps: 12, rationale: "Glute and back-extensor activation."))
            items.append(.init(exerciseId: "plank", sets: 2, holdSeconds: 20, rationale: "Core endurance."))
            items.append(.init(exerciseId: "hip-flexor-stretch", sets: 2, holdSeconds: 30, rationale: "Eases tight hip flexors from sitting."))
            items.append(.init(exerciseId: "hamstring-stretch", sets: 2, holdSeconds: 30, rationale: "Hamstring flexibility."))
        case .generalDeconditioning, .other:
            title = "Foundations"
            summary = "Whole-body strength and mobility basics."
            items.append(.init(exerciseId: "sit-to-stand", sets: 2, reps: 10, rationale: "Everyday leg strength."))
            items.append(.init(exerciseId: "incline-push-up", sets: 2, reps: 8, rationale: "Upper-body strength at an easy angle."))
            items.append(.init(exerciseId: "glute-bridge", sets: 2, reps: 10, rationale: "Hip strength."))
            items.append(.init(exerciseId: "chest-opener", sets: 1, holdSeconds: 30, rationale: "Posture."))
        }

        var program = ProgramDraftResponse(title: title, summary: summary, items: items)
            .toProgram(context: context, patientId: patientId, draftedBy: "Rule-based template", library: library)
        program.items = program.items.map { var i = $0; i.source = .template; return i }
        return program
    }
}
