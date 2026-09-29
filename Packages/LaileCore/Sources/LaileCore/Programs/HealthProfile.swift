import Foundation

/// What a person told Lele about themselves, plus limits that follow them into every program.
/// A clinician's precautions are merged in while they're supervised (and can be carried over
/// at discharge), so a knee limit keeps protecting someone in a squat class.
public struct HealthProfile: Codable, Sendable, Hashable {
    public enum Goal: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
        case getStronger, easeAches, moveMore, flexibility, recoverInjury
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .getStronger: return "Get stronger"
            case .easeAches: return "Ease aches and stiffness"
            case .moveMore: return "Move more on busy days"
            case .flexibility: return "Loosen up"
            case .recoverInjury: return "Recover from an injury or surgery"
            }
        }
    }

    public enum BodyArea: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
        case knees, hips, back, shoulders, neck, wrists
        public var id: String { rawValue }
        public var label: String { rawValue.capitalized }
    }

    public enum Experience: String, Codable, Sendable, CaseIterable, Hashable, Identifiable {
        case new, some, regular
        public var id: String { rawValue }
        public var label: String {
            switch self {
            case .new: return "New to exercise"
            case .some: return "I move now and then"
            case .regular: return "I train regularly"
            }
        }
    }

    public var goals: [Goal]
    public var minutesPerDay: Int
    public var experience: Experience
    /// Areas that hurt or that someone has said to be careful with.
    public var sensitiveAreas: [BodyArea]
    /// Anything else they told Lele, in their words.
    public var notes: String
    /// Limits carried over from a clinician (e.g. at discharge).
    public var clinicianPrecautions: Precautions?
    public var updatedAt: Date

    public init(goals: [Goal] = [], minutesPerDay: Int = 10, experience: Experience = .some, sensitiveAreas: [BodyArea] = [],
                notes: String = "", clinicianPrecautions: Precautions? = nil, updatedAt: Date = Date()) {
        self.goals = goals
        self.minutesPerDay = minutesPerDay
        self.experience = experience
        self.sensitiveAreas = sensitiveAreas
        self.notes = notes
        self.clinicianPrecautions = clinicianPrecautions
        self.updatedAt = updatedAt
    }

    /// Cautious limits from what they told Lele (not a diagnosis), plus anything a clinician set.
    public var precautions: Precautions {
        var p = Precautions()
        if sensitiveAreas.contains(.knees) {
            p.maxImpact = .low
            p.avoidExerciseIds += ["deep-squat-hold", "jumping-jacks", "high-knees"]
        }
        if sensitiveAreas.contains(.hips) { p.maxImpact = min(p.maxImpact, .low) }
        if sensitiveAreas.contains(.back) { p.maxImpact = min(p.maxImpact, .moderate) }
        if sensitiveAreas.contains(.wrists) { p.noWristLoading = true }
        if sensitiveAreas.contains(.shoulders) { p.maxShoulderElevation = 120 }
        if goals.contains(.recoverInjury) { p.maxImpact = min(p.maxImpact, .low) }
        return clinicianPrecautions.map { p.merged(with: $0) } ?? p
    }

    /// Someone describing an injury or ongoing pain should see a physiotherapist; Lele says so.
    public var shouldSeeClinician: Bool { goals.contains(.recoverInjury) || (!sensitiveAreas.isEmpty && goals.contains(.easeAches)) }
}

/// Builds a self-guided program from someone's goals. Deterministic, so it works offline and is
/// the reference an LLM draft is checked against. Everything passes the contraindication check.
public enum PersonalProgramDrafter {
    public struct Draft: Sendable, Hashable {
        public var program: Program
        /// One line per choice, in Lele's voice.
        public var reasons: [String]

        public init(program: Program, reasons: [String]) {
            self.program = program
            self.reasons = reasons
        }
    }

    public static func draft(_ profile: HealthProfile, library: ExerciseLibrary = .standard) -> Draft {
        let areas = Set(profile.sensitiveAreas)
        let precautions = profile.precautions
        var picks: [(String, Dose, String)] = []
        func add(_ id: String, _ dose: Dose, _ why: String) {
            guard !picks.contains(where: { $0.0 == id }) else { return }
            picks.append((id, dose, why))
        }
        let beginner = profile.experience == .new
        let pushUp = profile.experience == .regular ? "push-up" : (profile.experience == .some ? "knee-push-up" : "incline-push-up")

        for goal in profile.goals.isEmpty ? [.getStronger] : profile.goals {
            switch goal {
            case .getStronger:
                add(areas.contains(.knees) || beginner ? "sit-to-stand" : "squat", Dose(sets: 2, reps: 10, restSeconds: 30),
                    areas.contains(.knees) ? "Chair stands build your legs kindly on the knees." : "Squats work the biggest muscles you have.")
                add(pushUp, Dose(sets: 2, reps: 8, restSeconds: 30), "Push-ups at your level; I'll move you up when you're ready.")
                add("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 20), "Bridges for strong hips and a happier back.")
                add("plank", Dose(sets: 2, holdSeconds: beginner ? 15 : 30, restSeconds: 20), "A plank for your core.")
            case .easeAches:
                if areas.contains(.back) || areas.isEmpty {
                    add("glute-bridge", Dose(sets: 2, reps: 12, restSeconds: 20), "Bridges take load off a sore lower back.")
                    add("hip-flexor-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10), "Opens hips that tighten from sitting.")
                }
                if areas.contains(.shoulders) || areas.contains(.neck) {
                    add("neck-shoulder-rolls", Dose(sets: 1, holdSeconds: 30, restSeconds: 5), "Loosens a tense neck and shoulders.")
                    add("scapular-squeeze", Dose(sets: 8, holdSeconds: 5, restSeconds: 5), "Wakes up the muscles that fix a desk slump.")
                    add("wall-slide", Dose(sets: 2, reps: 8, restSeconds: 20), "Gentle, supported arm lifts.")
                }
                if areas.contains(.knees) {
                    add("sit-to-stand", Dose(sets: 2, reps: 8, restSeconds: 30), "Chair stands keep knees strong without strain.")
                    add("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10), "Eases tight hamstrings that pull on the knee.")
                }
                add("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5), "Undoes the hunch from phones and desks.")
            case .moveMore:
                add("sit-to-stand", Dose(sets: 1, reps: 10, restSeconds: 20), "Quick chair stands you can do anywhere.")
                if !areas.contains(.knees) { add("high-knees", Dose(sets: 1, reps: 30, restSeconds: 20), "A burst to get your heart going.") }
                add("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5), "A posture reset.")
            case .flexibility:
                add("hamstring-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10), "Loosens the backs of your legs.")
                add("hip-flexor-stretch", Dose(sets: 1, holdSeconds: 30, restSeconds: 10), "Opens the front of your hips.")
                add("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5), "Opens your chest and shoulders.")
                if !areas.contains(.knees) { add("deep-squat-hold", Dose(sets: 1, holdSeconds: 30, restSeconds: 10), "A deep squat rest for hips and ankles.") }
                add("shoulder-flexion", Dose(sets: 1, reps: 10, restSeconds: 10), "Full arm lifts, measured so you can watch your reach.")
            case .recoverInjury:
                add("glute-bridge", Dose(sets: 2, reps: 10, restSeconds: 30), "Gentle strength that's easy on joints.")
                add("sit-to-stand", Dose(sets: 2, reps: 8, restSeconds: 30), "Everyday strength, done slowly.")
                add("chest-opener", Dose(sets: 1, holdSeconds: 30, restSeconds: 5), "A gentle stretch to finish.")
            }
        }

        let count = profile.minutesPerDay <= 3 ? 3 : (profile.minutesPerDay <= 6 ? 4 : (profile.minutesPerDay <= 12 ? 5 : 6))
        let items = picks.prefix(count).map { ProgramItem(exerciseId: $0.0, dose: $0.1, rationale: $0.2, source: .aiDraft) }
        let (kept, blocked) = ContraindicationChecker.sanitize(items: Array(items), precautions: precautions, library: library)
        let reasons = kept.map { item in picks.first { $0.0 == item.exerciseId }?.2 ?? "" }.filter { !$0.isEmpty }
        let focus = profile.goals.first.map { goal -> String in
            switch goal {
            case .getStronger: return "strength"
            case .easeAches: return "easing aches"
            case .moveMore: return "moving more"
            case .flexibility: return "mobility"
            case .recoverInjury: return "gentle strength"
            }
        } ?? "strength"
        let program = Program(title: "\(profile.minutesPerDay)-minute \(focus) plan".capitalizedFirst, items: kept, precautions: precautions,
                              status: .signed, draftedBy: "Lele", summary: "Built by Lele from your goals.", blockedSuggestions: blocked)
        return Draft(program: program, reasons: reasons)
    }
}

/// What to do after physio ends: a catalog program that builds on it.
public enum FollowOn {
    public static func catalogId(for procedure: Procedure) -> String {
        switch procedure {
        case .totalKneeReplacement, .kneeOsteoarthritis, .totalHipReplacement: return "strong-knees"
        case .stiffShoulder, .shoulderPain: return "shoulder-mobility"
        case .lowBackPain: return "core-foundations"
        case .generalDeconditioning, .other: return "strength-10"
        }
    }
}

extension String {
    /// "10-minute strength plan" stays as is; "strength plan" → "Strength plan".
    var capitalizedFirst: String { prefix(1).uppercased() + dropFirst() }
}
