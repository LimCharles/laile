import Foundation

/// How a spoken remark mid-exercise is classified. The LLM (or the offline classifier)
/// proposes a category, and `SymptomRules` (plain code) sets what happens next.
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
    /// 0 to 10 when known.
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

    /// e.g. "Sharp pain, inside of right knee, 6/10; heel slides, set 2, rep 7 at 95° flexion"
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
        return context.isEmpty ? head : head + "; " + context.joined(separator: ", ")
    }
}

/// Per-person limits, set by the clinician in Rehab mode.
public struct SymptomPolicy: Codable, Sendable, Hashable {
    /// Pain above this (0 to 10) ends the set. Physio "pain-monitoring" style programs commonly
    /// accept discomfort up to about 4 or 5 out of 10 that settles by the next day; the clinician sets it.
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
        case .endSession(.emergency): return "Session ended with emergency advice"
        case .endSession(.contactCareTeamToday): return "Session ended; told to contact care team"
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
            // A classifier can spot a red flag our keyword net words differently ("there's a
            // pressure on my chest"). If the utterance still matches emergency wording, it must
            // be able to reach the emergency level instead of being capped at "contact today".
            let level: EscalationLevel = RedFlagDetector.matchesEmergencyWording(report.utterance)
                ? .emergency : .contactCareTeamToday
            return (.endSession(level), nil)
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
///
/// Two matching mechanisms, tried in this order:
///
///  1. `emergency` / `careTeamToday` — exact phrases, as before.
///  2. `emergencyRules` / `careTeamRules` — an anchor word and a modifier word that only have
///     to be *near* each other. This is what lets "my chest is really tight" through while
///     "my calf feels tired" still does not match, because "tired" is not a swelling word.
///
/// Negation is applied to both: a match is dropped only when a negator sits **directly**
/// beside it ("no chest pain", "not dizzy", "chest pain is gone"). Anything less direct keeps
/// the red flag — when in doubt we escalate, we never quietly carry on.
public enum RedFlagDetector {

    // MARK: - Exact phrases

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

        // Speech recognition routinely drops the apostrophe, so every "can't" rule is listed twice.
        (["cant breathe"], "difficulty breathing"), (["cant catch my breath"], "difficulty breathing"),
        (["can't catch my breath"], "difficulty breathing"), (["cant get my breath"], "difficulty breathing"),
        (["can't get my breath"], "difficulty breathing"), (["no air"], "difficulty breathing"),
        (["not getting enough air"], "difficulty breathing"),
        // "breathless", "gasping" and a racing or pounding heart are left out: after jumping jacks
        // or high knees they are normal, and an ambulance call for a hard set is its own harm.
        (["suffocating"], "difficulty breathing"),

        // Fainting. "faint" alone is also an adjective ("a faint click"), so only the phrasings
        // that actually mean it are listed.
        (["feel faint"], "fainting"), (["feeling faint"], "fainting"), (["felt faint"], "fainting"),
        (["fainting"], "fainting"), (["fainted"], "fainting"),
        (["pass out"], "fainting"), (["black out"], "fainting"), (["blacking out"], "fainting"),
        (["blacked out"], "fainting"), (["i collapsed"], "collapse"), (["i've collapsed"], "collapse"),
        (["i have collapsed"], "collapse"), (["i just collapsed"], "collapse"),

        (["heart attack"], "possible heart attack"),

        (["vomiting blood"], "vomiting blood"), (["throwing up blood"], "vomiting blood"),
        (["being sick with blood"], "vomiting blood"), (["cough up blood"], "coughing blood"),

        // Stroke (FAST) and airway.
        (["face is drooping"], "possible stroke"), (["face drooping"], "possible stroke"),
        (["mouth is drooping"], "possible stroke"), (["slurred speech"], "possible stroke"),
        (["slurring my words"], "possible stroke"), (["one side of my face"], "possible stroke"),
        (["cant speak properly"], "possible stroke"), (["can't speak properly"], "possible stroke"),
        (["sudden severe headache"], "sudden severe headache"), (["worst headache"], "sudden severe headache"),
        (["thunderclap headache"], "sudden severe headache"),
        (["throat is closing"], "airway swelling"), (["throat closing"], "airway swelling"),
        (["tongue is swelling"], "airway swelling"), (["lips are swelling"], "airway swelling"),

        // On the floor and unable to get up.
        (["cant get up"], "collapse"), (["can't get up"], "collapse"),
        (["cant get off the floor"], "collapse"), (["can't get off the floor"], "collapse"),
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

        // Weight bearing. "can't bear weight" was the stated reason but never the matched phrase.
        (["can't bear weight"], "can't bear weight"), (["cannot bear weight"], "can't bear weight"),
        (["cant bear weight"], "can't bear weight"), (["cant put weight"], "can't bear weight"),
        (["can't stand on it"], "can't bear weight"), (["cant stand on it"], "can't bear weight"),
        (["can't stand on my"], "can't bear weight"), (["cant stand on my"], "can't bear weight"),
        (["can't walk on it"], "can't bear weight"), (["cant walk on it"], "can't bear weight"),
        (["can't walk on my"], "can't bear weight"), (["cant walk on my"], "can't bear weight"),
        (["cant weight bear"], "can't bear weight"), (["can't weight bear"], "can't bear weight"),

        // Falls.
        // "i fell" and "fell off" are left out: "I fell asleep" and "the strap fell off" are not falls.
        (["fell over"], "a fall"), (["fell down"], "a fall"),
        (["had a fall"], "a fall"), (["i've fallen"], "a fall"), (["ive fallen"], "a fall"),
        (["i have fallen"], "a fall"), (["slipped and fell"], "a fall"), (["tripped and fell"], "a fall"),
        (["fell onto the floor"], "a fall"), (["fell on the floor"], "a fall"),
        (["ended up on the floor"], "a fall"),

        // Fever, dizziness and circulation wordings.
        (["have a temperature"], "fever"), (["having a temperature"], "fever"),
        (["running a temperature"], "fever"), (["high temperature"], "fever"),
        (["shivering"], "fever"), (["burning up"], "fever"),
        (["vertigo"], "dizziness"), (["room is spinning"], "dizziness"),
        (["everything is spinning"], "dizziness"), (["my head is spinning"], "dizziness"),
        (["woozy"], "dizziness"), (["wheezing"], "wheezing"), (["wheeze"], "wheezing"),
        (["leg is cold"], "poor circulation in the leg"), (["legs are cold"], "poor circulation in the leg"),
        (["leg is pale"], "poor circulation in the leg"), (["leg is blue"], "poor circulation in the leg"),
        (["leg is white"], "poor circulation in the leg"), (["leg has gone blue"], "poor circulation in the leg"),
        (["foot is cold"], "poor circulation in the leg"), (["foot is pale"], "poor circulation in the leg"),
        (["foot is blue"], "poor circulation in the leg"),

        // Loss of sensation wordings.
        (["no feeling in my"], "loss of sensation"), (["lost feeling in my"], "loss of sensation"),
        (["gone numb"], "loss of sensation"), (["has gone dead"], "loss of sensation"),
    ]

    // MARK: - Anchor + modifier rules

    /// Fires when one `anchors` word and one `modifiers` word appear within `window` words of
    /// each other. Empty `modifiers` means the anchor alone is enough.
    ///
    /// This is what makes the net survive ordinary speech: "my chest is really tight",
    /// "chest tightness", "pain in the chest" and "chest pressure" are all the same report.
    struct RedFlagRule: Sendable {
        var anchors: [String]
        var modifiers: [String]
        var window: Int
        var reason: String
    }

    static let emergencyRules: [RedFlagRule] = [
        // Deliberately not matched on proximity: breathing. "breathing hard" and "let me catch
        // my breath" are normal mid-exercise talk, so breathing stays on exact phrases only.
        .init(anchors: ["chest"],
              // "sore" is left out on purpose — a sore chest after push-ups is usually muscular,
              // and a false ambulance call is its own harm.
              modifiers: ["pain", "painful", "tight", "tightness", "tightens", "tightening", "hurts", "hurt",
                          "hurting", "ache", "aches", "aching", "pressure", "heavy", "heaviness", "squeezing",
                          "squeezed", "crushing", "crushed", "burning", "burns", "discomfort", "constriction"],
              window: 4,
              reason: "chest pain"),
    ]

    static let careTeamRules: [RedFlagRule] = [
        // Swelling in a leg (DVT), plurals included. Warm, hot and tender legs are left out: after
        // squats or a walk they are ordinary, and the exact "calf" + "hot" pair above still applies.
        .init(anchors: ["leg", "legs", "calf", "calves", "thigh", "thighs", "ankle", "ankles", "foot", "feet"],
              modifiers: ["swollen", "swelling", "swelled", "swells", "puffy", "puffed", "red", "redness"],
              window: 5,
              reason: "swelling or heat in a leg"),
        // Surgical site. People say incision, scar or stitches far more often than "wound".
        .init(anchors: ["wound", "wounds", "incision", "incisions", "scar", "scars", "stitches", "stitch", "dressing"],
              modifiers: ["oozing", "ooze", "oozes", "pus", "pussy", "leaking", "leak", "leaks", "leaked",
                          "bleeding", "bleed", "bled", "opened", "open", "gaping", "split", "weeping",
                          "discharge", "warm", "hot", "red", "smelly", "smell"],
              window: 5,
              reason: "wound problem"),
    ]

    // MARK: - Negation

    /// Words that flip the meaning of a symptom mentioned right after them. Both apostrophe
    /// forms are listed: the normalizer keeps apostrophes and speech recognition often drops
    /// them. "can't" is deliberately absent — "I can't stop the pain in my chest" means the
    /// opposite of a denial, and a missed cardiac flag is worse than a false one.
    static let negatorsBefore: Set<String> = [
        "no", "not", "never", "without", "nor", "none", "nothing",
        "don't", "dont", "doesn't", "doesnt", "didn't", "didnt", "isn't", "isnt", "aren't", "arent",
        "wasn't", "wasnt", "weren't", "werent", "won't", "wont", "haven't", "havent", "hasn't", "hasnt",
        "hadn't", "hadnt", "ain't", "aint", "resolved", "cleared",
    ]

    /// Words that follow a symptom and mean it has settled.
    static let negatorsAfter: Set<String> = [
        "gone", "resolved", "settled", "better", "improved", "eased", "cleared", "disappeared",
    ]

    /// The only words allowed between a negator and the symptom it denies ("I don't *have* chest
    /// pain", "chest pain *has completely* gone"). Any other word ends the search, so "not good,
    /// chest pain" and "chest pain stopped me" keep their red flag.
    static let negationFiller: Set<String> = [
        "i", "i'm", "im", "it", "it's", "its", "is", "am", "are", "was", "has", "have", "had", "got",
        "get", "getting", "any", "a", "an", "the", "my", "more", "much", "really", "been", "feel",
        "feeling", "felt", "sign", "signs", "of", "now", "all", "completely", "totally", "lot", "bit",
    ]

    /// How far a negator can sit from the match and still count as a direct denial.
    /// Kept tight on purpose: anything looser risks reading "I had chest pain last week but
    /// not now" as a denial, and doubt must fall on keeping the red flag.
    static let negatorLookBehind = 3
    static let negatorLookAhead = 3

    public static func detect(_ utterance: String) -> RedFlag? {
        if let flag = firstMatch(in: utterance, tier: .emergency) { return flag }
        if let flag = firstMatch(in: utterance, tier: .careTeamToday) { return flag }
        return nil
    }

    /// Emergency *subjects*. `detect` needs a full phrase to fire ("chest" plus a pain word);
    /// this only needs the subject. It is used after something else — the cloud coach or the
    /// on-device classifier — has already judged the remark a red flag and we are deciding how
    /// far to escalate. If it is about one of these, "contact the care team today" is not far
    /// enough: "there's a pressure on my chest" and "an elephant is sitting on my chest" both
    /// have to be able to reach the emergency level.
    static let emergencyTopics: Set<String> = [
        "chest", "heart", "breath", "breathe", "breathing", "breathless", "breathlessness", "air",
        "faint", "fainting", "fainted", "collapse", "collapsed", "collapsing", "blood", "stroke",
        "airway", "throat", "suffocating", "gasping", "ambulance",
    ]

    /// True when the utterance is about an emergency subject and that subject is not being
    /// denied. Used to let a classifier's own `redFlag` verdict reach `.emergency` instead of
    /// being capped at `.contactCareTeamToday`.
    public static func matchesEmergencyWording(_ utterance: String) -> Bool {
        let tokens = TextNormalizer.tokens(utterance)
        for (index, token) in tokens.enumerated() where emergencyTopics.contains(token) {
            if !isNegated(tokens, match: Set([index]), span: index...index) { return true }
        }
        return false
    }

    private enum Tier { case emergency, careTeamToday }

    private static func firstMatch(in utterance: String, tier: Tier) -> RedFlag? {
        let tokens = TextNormalizer.tokens(utterance)
        guard !tokens.isEmpty else { return nil }
        let level: EscalationLevel = tier == .emergency ? .emergency : .contactCareTeamToday
        let exact = tier == .emergency ? emergency : careTeamToday
        let rules = tier == .emergency ? emergencyRules : careTeamRules

        for entry in exact {
            var hit = Set<Int>()
            var low = Int.max
            var high = 0
            var matchedAll = true
            for phrase in entry.pattern {
                guard let range = TextNormalizer.range(ofPhrase: phrase, in: tokens) else {
                    matchedAll = false
                    break
                }
                hit.formUnion(range)
                low = min(low, range.lowerBound)
                high = max(high, range.upperBound)
            }
            guard matchedAll else { continue }
            if isNegated(tokens, match: hit, span: low...high) { continue }
            return RedFlag(level: level, reason: entry.reason)
        }

        for rule in rules {
            guard let hit = match(rule, in: tokens) else { continue }
            if isNegated(tokens, match: Set([hit.lowerBound, hit.upperBound]), span: hit) { continue }
            return RedFlag(level: level, reason: rule.reason)
        }
        return nil
    }

    /// The closest anchor/modifier pair within the rule's window, as a token range.
    private static func match(_ rule: RedFlagRule, in tokens: [String]) -> ClosedRange<Int>? {
        let anchors = tokens.indices.filter { rule.anchors.contains(tokens[$0]) }
        guard let first = anchors.first else { return nil }
        if rule.modifiers.isEmpty { return first...first }
        var best: ClosedRange<Int>? = nil
        for anchor in anchors {
            for (offset, token) in tokens.enumerated() where rule.modifiers.contains(token) {
                guard abs(anchor - offset) <= rule.window else { continue }
                if best == nil || abs(anchor - offset) < (best!.upperBound - best!.lowerBound) {
                    best = min(anchor, offset)...max(anchor, offset)
                }
            }
        }
        return best
    }

    /// True when a negator sits directly beside the match. Tokens that are part of the match
    /// itself are skipped, so "can't breathe" and "can't feel my leg" are never self-negating.
    private static func isNegated(_ tokens: [String], match: Set<Int>, span: ClosedRange<Int>) -> Bool {
        for index in match.sorted() {
            var behind = index - 1
            var steps = 0
            while behind >= 0, steps < negatorLookBehind {
                if !match.contains(behind) {
                    if negatorsBefore.contains(tokens[behind]) { return true }
                    if !negationFiller.contains(tokens[behind]) { break }
                }
                behind -= 1
                steps += 1
            }
        }
        var ahead = span.upperBound + 1
        var steps = 0
        while ahead < tokens.count, steps < negatorLookAhead {
            if !match.contains(ahead) {
                if negatorsAfter.contains(tokens[ahead]) { return true }
                if !negationFiller.contains(tokens[ahead]) { break }
            }
            ahead += 1
            steps += 1
        }
        return false
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

    /// `normalize` split into words, for rules that need positions (proximity, negation).
    static func tokens(_ s: String) -> [String] {
        normalize(s).split(separator: " ", omittingEmptySubsequences: true).map(String.init)
    }

    /// Where `phrase` sits inside `tokens` as a run of words, or nil when it isn't there.
    static func range(ofPhrase phrase: String, in tokens: [String]) -> ClosedRange<Int>? {
        let parts = phrase.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard !parts.isEmpty, parts.count <= tokens.count else { return nil }
        for start in 0...(tokens.count - parts.count) {
            if (0..<parts.count).allSatisfy({ tokens[start + $0] == parts[$0] }) {
                return start...(start + parts.count - 1)
            }
        }
        return nil
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
