import Foundation

/// Offline, rule-based classifier for what people say mid-exercise.
///
/// Used when there's no network or LLM, and as the mock "LLM" in tests and demos. The cloud
/// coach (Hunyuan via ADP) returns the same `SymptomReport` shape through a tool call, so the
/// rules downstream never care which one produced it.
public enum UtteranceClassifier {
    static let negatedPain = ["no pain", "not painful", "doesn't hurt", "does not hurt", "don't hurt", "not hurting",
                              "isn't hurting", "no it's fine", "not sore", "pain free", "painless"]
    static let normal = ["fine", "okay", "ok", "good", "great", "alright", "all right", "all good", "no problem", "easy",
                         "feels good", "feels fine", "normal", "yes", "yep", "yeah", "i'm good", "im good", "no issues"]
    static let effort = ["burn", "burning", "tired", "hard", "heavy", "shaking", "shaky", "exhausted", "tough", "working"]
    static let stretch = ["pull", "pulling", "tight", "tightness", "stretch", "stretching", "stiff", "stiffness"]
    static let painWords = ["pain", "painful", "hurts", "hurt", "hurting", "sharp", "stabbing", "shooting", "agony",
                            "sore", "aching", "ache", "throbbing"]
    static let wrong = ["click", "clicking", "clicked", "pop", "popped", "popping", "gave way", "give way", "giving way",
                        "buckled", "locked", "locking", "catching", "numb", "numbness", "tingling", "tingle",
                        "pins and needles", "grinding", "unstable"]
    static let ambiguous = ["ow", "ouch", "ah", "argh", "ahh", "oof", "hmm", "weird", "strange", "funny", "not sure", "odd", "off"]

    static let qualities: [(String, String)] = [
        ("sharp", "sharp"), ("stabbing", "stabbing"), ("shooting", "shooting"), ("burning", "burning"),
        ("dull", "dull"), ("aching", "aching"), ("ache", "aching"), ("throbbing", "throbbing"), ("pulling", "pulling"),
        ("tight", "tight"), ("click", "clicking"), ("clicking", "clicking"), ("clicked", "clicking"), ("pop", "popping"),
        ("popped", "popping"), ("gave way", "giving way"), ("giving way", "giving way"), ("numb", "numbness"),
        ("tingling", "tingling"), ("pins and needles", "tingling"), ("grinding", "grinding"), ("swollen", "swelling"),
    ]

    static let locations = ["lower back", "upper back", "kneecap", "knee", "hip", "groin", "thigh", "hamstring", "quad",
                            "calf", "shin", "ankle", "foot", "heel", "back", "neck", "shoulder", "elbow", "wrist",
                            "chest", "glute", "bum", "bottom", "scar", "wound"]
    static let locationQualifiers: [(String, String)] = [
        ("inside", "inside of"), ("inner", "inside of"), ("outside", "outside of"), ("outer", "outside of"),
        ("front", "front of"), ("back of", "back of"), ("behind", "back of"), ("under", "under"),
    ]

    static let numberWords: [String: Int] = [
        "zero": 0, "one": 1, "two": 2, "three": 3, "four": 4, "five": 5, "six": 6, "seven": 7, "eight": 8, "nine": 9, "ten": 10,
    ]

    /// Classify one utterance. `awaitingRating` = we just asked "zero to ten, how bad?".
    public static func classify(_ utterance: String, awaitingRating: Bool = false) -> SymptomReport {
        let text = TextNormalizer.normalize(utterance)
        let severity = parseSeverity(utterance)
        let quality = qualities.first { TextNormalizer.contains(text, phrase: $0.0) }?.1
        let location = parseLocation(text)
        let side: Side? = TextNormalizer.contains(text, phrase: "left") ? .left : (TextNormalizer.contains(text, phrase: "right") && !TextNormalizer.contains(text, phrase: "all right") ? .right : nil)

        func report(_ category: SymptomCategory, severity sev: Int? = severity) -> SymptomReport {
            SymptomReport(category: category, utterance: utterance, bodyLocation: location, side: side, quality: quality,
                          severity: sev, source: .voiceOnDevice)
        }

        if let flag = RedFlagDetector.detect(utterance) {
            var r = report(.redFlag)
            r.redFlagReason = flag.reason
            return r
        }
        if awaitingRating, let severity {
            return report(severity == 0 ? .normal : .pain, severity: severity)
        }
        if TextNormalizer.containsAny(text, negatedPain) { return report(.normal) }
        if TextNormalizer.containsAny(text, wrong) { return report(.wrongSensation) }

        let mentionsPain = TextNormalizer.containsAny(text, painWords)
        let mentionsStretch = TextNormalizer.containsAny(text, stretch)
        let mentionsEffort = TextNormalizer.containsAny(text, effort)

        if mentionsPain {
            // "sore thighs" / "aching muscles" during effort with no sharp words → effort, not pain.
            let sharp = TextNormalizer.containsAny(text, ["sharp", "stabbing", "shooting", "agony", "hurts", "hurt", "pain", "painful", "hurting"])
            if !sharp && (mentionsEffort || mentionsStretch) { return report(mentionsStretch ? .expectedStretch : .effort) }
            return report(.pain)
        }
        if mentionsStretch { return report(.expectedStretch) }
        if mentionsEffort { return report(.effort) }
        if TextNormalizer.containsAny(text, ambiguous) { return report(.ambiguous) }
        if TextNormalizer.containsAny(text, normal) || isJustCounting(text) { return report(.normal) }
        return report(.ambiguous)
    }

    /// Pulls a 0–10 rating out of "about a six", "7 out of 10", "maybe 3".
    public static func parseSeverity(_ utterance: String) -> Int? {
        let text = TextNormalizer.normalize(utterance)
        let words = text.split(separator: " ").map(String.init)
        for (i, word) in words.enumerated() {
            let value = Int(word) ?? numberWords[word]
            guard let value, (0...10).contains(value) else { continue }
            // Skip counts like "one more rep" unless it's clearly a rating.
            let next = i + 1 < words.count ? words[i + 1] : ""
            if next == "more" || next == "rep" || next == "reps" || next == "second" || next == "seconds" { continue }
            return value
        }
        return nil
    }

    static func parseLocation(_ text: String) -> String? {
        guard let location = locations.first(where: { TextNormalizer.contains(text, phrase: $0) }) else { return nil }
        if let qualifier = locationQualifiers.first(where: { TextNormalizer.contains(text, phrase: $0.0) })?.1 {
            return "\(qualifier) \(location)"
        }
        return location
    }

    static func isJustCounting(_ text: String) -> Bool {
        let words = text.split(separator: " ").map(String.init)
        return !words.isEmpty && words.allSatisfy { Int($0) != nil || numberWords[$0] != nil || ["and", "a", "hold"].contains($0) }
    }
}

/// Keeps the coach inside the "explain, never advise on medication" boundary.
public enum MedicationBoundary {
    static let doseChangePhrases = [
        "take more", "take extra", "double", "skip my", "skip the", "stop taking", "stop my", "increase my", "decrease my",
        "reduce my", "lower my dose", "higher dose", "another tablet", "another pill", "extra pill", "extra tablet",
        "should i take", "can i take", "is it okay to take", "is it ok to take", "how much should", "change my dose",
    ]

    public static let referral = "That's a question for your doctor or pharmacist — I can't advise on doses. I'll add it to your questions for your next visit."

    public static func isDoseQuestion(_ text: String) -> Bool {
        TextNormalizer.containsAny(TextNormalizer.normalize(text), doseChangePhrases)
    }
}
