import Foundation

/// Reads a typed or spoken answer to one of Lele's questions. The buttons under a question are
/// suggestions; people can also just say how they are, and this maps their words onto the same
/// options. Plain keyword rules, so the result is predictable and testable.
public enum ReplyReader {
    /// The suggested reply that matches what they wrote, if any.
    public static func action(in message: LeleMessage, for text: String) -> LeleAction? {
        let replies = message.actions.filter { $0.kind == .reply }
        guard !replies.isEmpty else { return nil }
        let said = Words(text)
        if let exact = replies.first(where: { said.text == $0.label.lowercased() }) { return exact }
        // A dose is only logged on a clear "taken": whole words ("yes" must not match "yesterday"),
        // and nothing that says it hasn't happened yet today.
        let wholeWords = message.kind == .reminder
        if wholeWords, said.hasAny(notTakenYet) { return nil }
        for (id, cues) in cues(for: message.kind) where said.affirmsAny(cues, wholeWords: wholeWords) {
            if let action = replies.first(where: { $0.id == id }) { return action }
        }
        return nil
    }

    /// Reminder replies that mean the dose has not been taken today.
    static let notTakenYet = ["not yet", "yesterday", "later", "forgot", "missed", "skip", "will take", "going to"]

    /// Ordered: the first match wins, so negated and specific phrases come before broad words.
    static func cues(for kind: LeleMessage.Kind) -> [(String, [String])] {
        switch kind {
        case .morningCheckIn:
            return [
                ("worse", ["not good", "not great", "not so good", "not well", "not better", "not fine", "not ok", "not okay",
                           "not alright"]),
                ("better", ["not sore", "no pain", "no more", "not stiff", "no swelling", "not swollen", "less sore", "less pain",
                            "not as sore", "not as bad", "better", "good", "great", "improv", "easier", "loosen"]),
                ("worse", ["worse", "sore", "swollen", "swelling", "hurt", "pain", "stiff", "bad", "rough", "aching", "ache", "throb"]),
                ("same", ["same", "no change", "similar", "ok", "okay", "alright", "fine", "not bad", "not so bad", "meh", "so-so"]),
            ]
        case .barrier, .progress:
            return [
                ("worried", ["worri", "scared", "afraid", "nervous", "anxious", "careful", "make it worse"]),
                ("pain", ["hurt", "pain", "sore", "ache", "aching"]),
                ("time", ["busy", "time", "work", "schedule", "kids", "travel", "shift"]),
                ("forgot", ["forgot", "forget", "remember", "slipped my mind"]),
                ("energy", ["tired", "energy", "exhausted", "fatigue", "sleep", "lazy", "motivat", "low"]),
                ("fine", ["nothing", "all good", "all fine", "fine", "no problem"]),
            ]
        case .reminder:
            return [("taken", ["taken", "took", "done", "had it", "yes", "yep", "yeah"])]
        default:
            return []
        }
    }
}

/// Reads typed answers in Lele's goals conversation.
public enum GoalsReader {
    public static func goals(in text: String) -> [HealthProfile.Goal] {
        let said = Words(text)
        let table: [(HealthProfile.Goal, [String])] = [
            (.recoverInjury, ["injur", "surgery", "operation", "recover", "rehab", "physio", "sprain", "replacement", "fracture",
                              "broke my", "torn", "tear"]),
            (.getStronger, ["strong", "strength", "muscle", "push-up", "pushup", "push up", "pull-up", "pullup", "pull up", "fit",
                            "tone", "build", "lift", "squat"]),
            (.easeAches, ["ache", "aching", "stiff", "sore", "pain", "hurt", "back", "neck"]),
            (.moveMore, ["busy", "desk", "sitting", "sit all day", "active", "move more", "energy", "habit", "walk", "lazy"]),
            (.flexibility, ["flexib", "loosen", "stretch", "mobil", "touch my toes", "supple", "tight"]),
        ]
        return table.filter { said.hasAny($0.1) }.map(\.0)
    }

    /// Minutes most days, snapped to the options Lele offers (5 to 30).
    public static func minutes(in text: String) -> Int? {
        let said = Words(text)
        var value: Int?
        if let match = said.text.range(of: #"\d{1,3}"#, options: .regularExpression) {
            value = Int(said.text[match])
            if said.has("hour"), let v = value, v <= 3 { value = v * 60 }
        } else if said.hasAny(["half an hour", "half hour"]) { value = 30 }
        else if said.hasAny(["quarter of an hour", "quarter hour"]) { value = 15 }
        else if said.hasAny(["an hour", "one hour"]) { value = 60 }
        else {
            let words: [(String, Int)] = [("thirty", 30), ("twenty", 20), ("fifteen", 15), ("ten", 10), ("five", 5),
                                          ("couple of minutes", 5), ("few minutes", 5), ("not much", 5), ("little", 5)]
            value = words.first { said.has($0.0) }?.1
        }
        guard let minutes = value, minutes > 0 else { return nil }
        return [5, 10, 15, 20, 30].min { abs($0 - minutes) < abs($1 - minutes) }
    }

    public static func experience(in text: String) -> HealthProfile.Experience? {
        let said = Words(text)
        if said.hasAny(["never", "new", "beginner", "haven't", "havent", "not much", "rarely", "don't exercise", "dont exercise",
                        "couch", "out of shape", "not at all"]) { return .new }
        if said.hasAny(["sometimes", "now and then", "occasionally", "a bit", "a little", "weekend", "once a week", "on and off"]) {
            return .some
        }
        if said.hasAny(["regular", "every day", "daily", "gym", "train", "athlete", "run", "lift", "often", "most days",
                        "several times", "a lot"]) { return .regular }
        return nil
    }

    /// Sensitive areas. An empty list means they said there's nothing; nil means it wasn't clear.
    public static func areas(in text: String) -> [HealthProfile.BodyArea]? {
        let said = Words(text)
        let table: [(HealthProfile.BodyArea, [String])] = [
            (.knees, ["knee"]), (.hips, ["hip"]), (.back, ["back", "spine", "lumbar"]),
            (.shoulders, ["shoulder", "rotator"]), (.neck, ["neck"]), (.wrists, ["wrist", "hand", "carpal"]),
        ]
        let found = table.filter { said.hasAny($0.1) }.map(\.0)
        if !found.isEmpty { return found }
        if said.hasAny(["nothing", "none", "no", "nope", "nah", "fine", "all good", "i'm good", "im good"]) { return [] }
        return nil
    }

    /// The safety question: true means a concern (gentle mode). Any concern that isn't denied counts,
    /// wherever it sits: "I get dizzy sometimes, but no chest pain" is a concern.
    public static func safetyConcern(in text: String) -> Bool? {
        let said = Words(text)
        if said.affirmsAny(["chest pain", "faint", "dizz", "heart", "blood pressure", "doctor said", "doctor told", "told me to",
                            "breathless", "short of breath", "pass out", "passed out"]) { return true }
        let negatives = ["no", "nope", "nah", "never", "not", "none", "nothing"]
        if negatives.contains(where: { said.text.hasPrefix($0 + " ") || said.text == $0 || said.text.hasPrefix($0 + ",") }) { return false }
        if said.affirmsAny(["yes", "yeah", "yep", "sometimes", "i do"], wholeWords: true) { return true }
        if said.hasAny(negatives) { return false }
        return nil
    }
}

/// Lowercased text with word-start matching ("hurt" matches "hurts" but not "shurt").
struct Words {
    let text: String

    init(_ raw: String) {
        text = raw.lowercased().replacingOccurrences(of: "’", with: "'").trimmingCharacters(in: .whitespacesAndNewlines.union(.punctuationCharacters))
    }

    func has(_ cue: String) -> Bool {
        text.range(of: #"\b"# + NSRegularExpression.escapedPattern(for: cue), options: .regularExpression) != nil
    }

    func hasAny(_ cues: [String]) -> Bool { cues.contains(where: has) }

    /// True when `cue` appears at least once without being denied: no "no", "not", "never" and the
    /// like in the two words before it, and no "anymore" or "gone" right after it. "No more pain"
    /// and "not stiff anymore" do not count as pain or stiffness. Cues that contain a negator
    /// themselves ("not good", "no pain") are matched as written.
    func affirms(_ cue: String, wholeWords: Bool = false) -> Bool {
        let pattern = #"\b"# + NSRegularExpression.escapedPattern(for: cue) + (wholeWords ? #"\b"# : "")
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
        let whole = NSRange(text.startIndex..., in: text)
        // "not stiff anymore" is a denial already; "anymore" only cancels a plain symptom word.
        let cueIsDenial = Self.words(Substring(cue)).first.map(Self.negators.contains) ?? false
        for match in regex.matches(in: text, range: whole) {
            guard let range = Range(match.range, in: text) else { continue }
            let before = Self.words(text[..<range.lowerBound]).suffix(2)
            let after = Self.words(text[range.upperBound...]).prefix(2)
            if before.contains(where: Self.negators.contains) { continue }
            if !cueIsDenial, after.contains(where: Self.settled.contains) { continue }
            return true
        }
        return false
    }

    func affirmsAny(_ cues: [String], wholeWords: Bool = false) -> Bool {
        cues.contains { affirms($0, wholeWords: wholeWords) }
    }

    static let negators: Set<String> = [
        "no", "not", "never", "without", "hardly", "barely", "isn't", "isnt", "wasn't", "wasnt", "aren't", "arent",
        "don't", "dont", "doesn't", "doesnt", "didn't", "didnt", "haven't", "havent", "hasn't", "hasnt", "won't", "wont",
    ]
    static let settled: Set<String> = ["anymore", "gone"]

    static func words(_ s: Substring) -> [String] {
        s.split { !$0.isLetter && $0 != "'" }.map(String.init)
    }
}
