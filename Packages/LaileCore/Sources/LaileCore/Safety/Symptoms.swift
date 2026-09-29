import Foundation

/// How a spoken remark mid-exercise is classified. The LLM (or the offline classifier)
/// proposes a category; `SymptomRules` — plain code — decides what happens.
public enum SymptomCategory: String, Codable, Sendable, CaseIterable, Hashable {
    /// "Fine", "okay", counting along.
    case normal
    /// Muscle effort: "burning", "tired", "hard".
    case effort
    /// Stretch sensation: "pulling", "tight".
    case expectedStretch
    /// Can't tell yet: "ow", "hmm", "feels weird".
    case ambiguous
    /// Real pain: "sharp", "stabbing", "hurts".
    case pain
    /// Something mechanically off: clicking, giving way, numbness, tingling.
    case wrongSensation
    /// Needs medical attention now or today.
    case redFlag

    public var needsClinicianReview: Bool {
        switch self {
        case .pain, .wrongSensation, .redFlag: return true
        default: return false
        }
    }
}

public enum EscalationLevel: String, Codable, Sendable, Hashable {
    /// Contact the care team / see a doctor today.
    case contactCareTeamToday
    /// Call emergency services now.
    case emergency
}

public enum SymptomSource: String, Codable, Sendable, Hashable {
    case voiceLLM, voiceOnDevice, tapped, typed
}

public struct SymptomReport: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var timestamp: Date
    public var category: SymptomCategory
    /// Exactly what the user said.
    public var utterance: String
    public var bodyLocation: String?
    public var side: Side?
    /// sharp, dull, pulling, clicking, giving way, numbness, tingling, swelling…
    public var quality: String?
    /// 0–10 when known.
    public var severity: Int?
    public var source: SymptomSource

    // Context captured at the moment it was said.
    public var exerciseId: String?
    public var setIndex: Int?
    public var repIndex: Int?
    public var holdSecond: Int?
    public var angle: Double?

    public var action: SymptomAction?
    public var redFlagReason: String?

    public init(id: UUID = UUID(), timestamp: Date = Date(), category: SymptomCategory, utterance: String,
                bodyLocation: String? = nil, side: Side? = nil, quality: String? = nil, severity: Int? = nil,
                source: SymptomSource, exerciseId: String? = nil, setIndex: Int? = nil, repIndex: Int? = nil,
                holdSecond: Int? = nil, angle: Double? = nil, action: SymptomAction? = nil, redFlagReason: String? = nil) {
        self.id = id
        self.timestamp = timestamp
        self.category = category
        self.utterance = utterance
        self.bodyLocation = bodyLocation
        self.side = side
        self.quality = quality
        self.severity = severity
        self.source = source
        self.exerciseId = exerciseId
        self.setIndex = setIndex
        self.repIndex = repIndex
        self.holdSecond = holdSecond
        self.angle = angle
        self.action = action
        self.redFlagReason = redFlagReason
    }

    /// e.g. "Sharp pain, inside of right knee, 6/10 — heel slides, set 2, rep 7 at 95° flexion"
    public var clinicalSummary: String {
        var parts: [String] = []
        var what = [quality, category == .pain ? "pain" : nil].compactMap { $0 }.joined(separator: " ")
        if what.isEmpty { what = category.rawValue }
        parts.append(what.prefix(1).uppercased() + what.dropFirst())
        if let loc = bodyLocation {
            // "inside of knee" + right → "inside of right knee"
            if let side, let range = loc.range(of: " of ") {
                parts.append("\(loc[..<range.upperBound])\(side.rawValue) \(loc[range.upperBound...])")
            } else {
                parts.append([side?.rawValue, loc].compactMap { $0 }.joined(separator: " "))
            }
        }
        if let severity { parts.append("\(severity)/10") }
        var context: [String] = []
        if let exerciseId { context.append(ExerciseLibrary.standard.spec(exerciseId)?.name ?? exerciseId) }
        if let setIndex { context.append("set \(setIndex + 1)") }
        if let repIndex { context.append("rep \(repIndex)") }
        if let holdSecond { context.append("\(holdSecond)s into hold") }
        if let angle {
            let spec = exerciseId.flatMap { ExerciseLibrary.standard.spec($0) }
            if spec?.kind.trackedAngle?.vertex == .knee {
                context.append("knee bent to \(Int((180 - angle).rounded()))°")
            } else {
                context.append("at \(Int(angle.rounded()))° joint angle")
            }
        }
        let head = parts.joined(separator: ", ")
        return context.isEmpty ? head : head + " — " + context.joined(separator: ", ")
    }
}

/// Per-person limits, set by the clinician in Rehab mode.
public struct SymptomPolicy: Codable, Sendable, Hashable {
    /// Pain above this (0–10) ends the set. Physio "pain-monitoring" style programs commonly
    /// accept discomfort up to about 4–5/10 that settles by the next day; the clinician sets it.
    public var painStopSetAbove: Int
    /// Pain at or above this ends the exercise.
    public var painStopExerciseAt: Int
    public var mode: AppMode
    public var emergencyNumber: String

    public init(painStopSetAbove: Int, painStopExerciseAt: Int, mode: AppMode, emergencyNumber: String = "995") {
        self.painStopSetAbove = painStopSetAbove
        self.painStopExerciseAt = painStopExerciseAt
        self.mode = mode
        self.emergencyNumber = emergencyNumber
    }

    public static let rehabDefault = SymptomPolicy(painStopSetAbove: 4, painStopExerciseAt: 7, mode: .rehab)
    /// Move mode has no clinician, so it is more conservative.
    public static let moveDefault = SymptomPolicy(painStopSetAbove: 2, painStopExerciseAt: 5, mode: .move)
}

public enum SymptomAction: Codable, Sendable, Hashable {
    case continueExercise
    case clarify
    case pauseAndRate
    case stopSet
    case stopExercise
    case endSession(EscalationLevel)

    public var label: String {
        switch self {
        case .continueExercise: return "Continued"
        case .clarify: return "Asked to clarify"
        case .pauseAndRate: return "Paused to rate pain"
        case .stopSet: return "Set stopped"
        case .stopExercise: return "Exercise stopped"
        case .endSession(.emergency): return "Session ended — emergency advice given"
        case .endSession(.contactCareTeamToday): return "Session ended — told to contact care team"
        }
    }
}

public enum SymptomRules {
    /// Deterministic decision. Red-flag keywords are re-checked here even if a classifier
    /// (human or LLM) labelled the remark as something milder.
    public static func decide(_ report: SymptomReport, policy: SymptomPolicy) -> (action: SymptomAction, redFlag: RedFlag?) {
        if let flag = RedFlagDetector.detect(report.utterance) {
            return (.endSession(flag.level), flag)
        }
        switch report.category {
        case .redFlag:
            return (.endSession(.contactCareTeamToday), nil)
        case .normal, .effort:
            return (.continueExercise, nil)
        case .expectedStretch:
            if let s = report.severity, s > policy.painStopSetAbove { return (.stopSet, nil) }
            return (.continueExercise, nil)
        case .ambiguous:
            return (.clarify, nil)
        case .pain:
            guard let s = report.severity else { return (.pauseAndRate, nil) }
            if s >= policy.painStopExerciseAt { return (.stopExercise, nil) }
            if s > policy.painStopSetAbove { return (.stopSet, nil) }
            return (.continueExercise, nil)
        case .wrongSensation:
            return (.stopExercise, nil)
        }
    }
}

public struct RedFlag: Sendable, Hashable {
    public var level: EscalationLevel
    public var reason: String
}

/// Keyword safety net for symptoms that must never be handled by the chat model alone.
public enum RedFlagDetector {
    static let emergency: [(pattern: [String], reason: String)] = [
        (["chest pain"], "chest pain"), (["chest hurts"], "chest pain"), (["chest is tight"], "chest tightness"),
        (["tight chest"], "chest tightness"), (["pain in my chest"], "chest pain"),
        (["can't breathe"], "difficulty breathing"), (["cannot breathe"], "difficulty breathing"),
        (["can not breathe"], "difficulty breathing"), (["short of breath"], "shortness of breath"),
        (["shortness of breath"], "shortness of breath"), (["struggling to breathe"], "difficulty breathing"),
        (["hard to breathe"], "difficulty breathing"), (["trouble breathing"], "difficulty breathing"),
        (["difficulty breathing"], "difficulty breathing"),
        (["passing out"], "fainting"), (["passed out"], "fainting"), (["going to faint"], "fainting"),
        (["about to faint"], "fainting"), (["coughing blood"], "coughing blood"), (["coughing up blood"], "coughing blood"),
    ]

    static let careTeamToday: [(pattern: [String], reason: String)] = [
        (["calf", "swollen"], "possible blood clot (calf swelling)"), (["calf", "swelling"], "possible blood clot (calf swelling)"),
        (["calf", "swelled"], "possible blood clot (calf swelling)"), (["calf", "puffy"], "possible blood clot (calf swelling)"),
        (["calf", "hot"], "possible blood clot (hot calf)"), (["calf", "red"], "possible blood clot (red calf)"),
        (["leg", "swollen"], "leg swelling"), (["wound", "oozing"], "wound problem"), (["wound", "pus"], "wound problem"),
        (["wound", "leaking"], "wound problem"), (["wound", "bleeding"], "wound bleeding"), (["wound", "opened"], "wound opened"),
        (["fever"], "fever"), (["chills"], "chills"), (["can't feel my"], "loss of sensation"),
        (["cannot feel my"], "loss of sensation"), (["can't put weight"], "can't bear weight"),
        (["cannot put weight"], "can't bear weight"), (["dizzy"], "dizziness"), (["light headed"], "light-headedness"),
        (["lightheaded"], "light-headedness"),
    ]

    public static func detect(_ utterance: String) -> RedFlag? {
        let text = TextNormalizer.normalize(utterance)
        for entry in emergency where entry.pattern.allSatisfy({ TextNormalizer.contains(text, phrase: $0) }) {
            return RedFlag(level: .emergency, reason: entry.reason)
        }
        for entry in careTeamToday where entry.pattern.allSatisfy({ TextNormalizer.contains(text, phrase: $0) }) {
            return RedFlag(level: .contactCareTeamToday, reason: entry.reason)
        }
        return nil
    }
}

enum TextNormalizer {
    /// Lowercased words separated by single spaces, padded with a space at each end so
    /// phrases can be matched on word boundaries ("red" must not match "tired").
    static func normalize(_ s: String) -> String {
        let lowered = s.lowercased().replacingOccurrences(of: "’", with: "'")
        let mapped = lowered.unicodeScalars.map { scalar -> Character in
            CharacterSet.alphanumerics.contains(scalar) || scalar == "'" ? Character(scalar) : " "
        }
        let words = String(mapped).split(separator: " ", omittingEmptySubsequences: true)
        return " " + words.joined(separator: " ") + " "
    }

    static func contains(_ normalized: String, phrase: String) -> Bool {
        normalized.contains(" \(phrase) ")
    }

    static func containsAny(_ normalized: String, _ phrases: [String]) -> Bool {
        phrases.contains { contains(normalized, phrase: $0) }
    }

    static func firstMatch(_ normalized: String, _ phrases: [String]) -> String? {
        phrases.first { contains(normalized, phrase: $0) }
    }
}

/// Fixed lines spoken for each rule outcome when there's no LLM in the loop.
public enum SymptomResponses {
    public static let clarify = CueLine("Is that a stretching feeling, or a sharp pain?", key: "sym.clarify", priority: .high)
    public static let rate = CueLine("Let's pause. From zero to ten, how bad is the pain?", key: "sym.rate", priority: .high)
    public static let acknowledgeStretch = CueLine("That pulling feeling is normal. Keep breathing.", key: "sym.stretch-ok")
    public static let acknowledgeEffort = CueLine("That's your muscles working. You've got this.", key: "sym.effort-ok")
    public static let acknowledgeWithinLimit = CueLine("Okay, noted. That's within your limit, so carry on gently.", key: "sym.within-limit")
    public static let stopSet = CueLine("Let's stop this set there and rest. I've noted it for your records.", key: "sym.stop-set", priority: .high)
    public static let stopExercise = CueLine("Let's stop this exercise. I've noted exactly what happened for your records.", key: "sym.stop-exercise", priority: .high)
    public static let careTeamToday = CueLine("Please stop exercising and contact your care team today. I've noted what you told me.", key: "sym.care-team", priority: .high)
    public static let doctorToday = CueLine("Please stop exercising and get this checked by a doctor today.", key: "sym.doctor", priority: .high)
    /// Answer to "how did that feel?" when it felt fine.
    public static let goodToHear = CueLine("Good to hear.", key: "sym.good-to-hear")

    public static func emergency(number: String) -> CueLine {
        CueLine("Stop now. This could be serious. Call \(number) for an ambulance, or ask someone nearby to help you.", key: "sym.emergency.\(number)", priority: .high)
    }

    public static var all: [CueLine] {
        [clarify, rate, acknowledgeStretch, acknowledgeEffort, acknowledgeWithinLimit, goodToHear, stopSet, stopExercise, careTeamToday, doctorToday, emergency(number: "995")]
    }

    public static func line(for action: SymptomAction, category: SymptomCategory, policy: SymptomPolicy) -> CueLine? {
        switch action {
        case .continueExercise:
            switch category {
            case .expectedStretch: return acknowledgeStretch
            case .effort: return acknowledgeEffort
            case .pain: return acknowledgeWithinLimit
            default: return nil
            }
        case .clarify: return clarify
        case .pauseAndRate: return rate
        case .stopSet: return stopSet
        case .stopExercise: return stopExercise
        case .endSession(.emergency): return emergency(number: policy.emergencyNumber)
        case .endSession(.contactCareTeamToday): return policy.mode == .rehab ? careTeamToday : doctorToday
        }
    }
}
