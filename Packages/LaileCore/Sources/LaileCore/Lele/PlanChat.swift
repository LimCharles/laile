import Foundation

/// Planning a new program by talking to Lele, inside the normal chat. Someone says they want new
/// goals or a different program; Lele asks five short questions (goals, time, experience, what
/// needs care, safety), each answerable with a button or in their own words, then builds the plan.
///
/// The answers so far travel in the question's `dedupeKey` ("plan:<step>|<json>"), so the flow
/// needs no extra storage and works in any client that can show Lele's questions.
public enum PlanChat {
    public enum Step: String, Codable, Sendable, CaseIterable {
        case goals, minutes, experience, areas, safety
    }

    /// What has been answered so far.
    public struct Answers: Codable, Sendable, Hashable {
        public var goals: [HealthProfile.Goal] = []
        public var minutes: Int?
        public var experience: HealthProfile.Experience?
        public var areas: [HealthProfile.BodyArea]?
        public var safetyConcern: Bool?
        /// Their own words along the way, kept for Lele and the physio.
        public var said: [String] = []

        public init() {}

        /// The answers as a health profile, keeping anything a clinician set and earlier notes.
        public func profile(base: HealthProfile?, at date: Date) -> HealthProfile {
            var profile = base ?? HealthProfile()
            profile.goals = goals.isEmpty ? profile.goals : goals
            profile.minutesPerDay = minutes ?? profile.minutesPerDay
            profile.experience = experience ?? profile.experience
            profile.sensitiveAreas = areas ?? profile.sensitiveAreas
            var notes = said
            if safetyConcern == true { notes.append("Has been told to be careful with exercise, or gets chest pain or dizziness") }
            if !notes.isEmpty { profile.notes = notes.joined(separator: ". ") }
            profile.updatedAt = date
            return profile
        }
    }

    // MARK: - Starting

    /// True when someone asks for a new or different program, or to change their goals.
    public static func wantsNewPlan(_ text: String) -> Bool {
        let said = Words(text)
        let asks = ["new program", "new plan", "new routine", "different program", "different plan", "change my program",
                    "change my plan", "change my goals", "new goals", "set goals", "replace my program", "replace my plan",
                    "make me a program", "make me a plan", "build me a program", "build me a plan", "make a program",
                    "make a plan", "create a program", "create a plan", "plan for me", "program for me", "harder program",
                    "easier program", "switch program", "switch my program", "update my goals", "my goals have changed"]
        if said.hasAny(["don't want", "dont want", "do not want", "no need for", "not looking for"]) { return false }
        return said.affirmsAny(asks)
    }

    /// Lele's first question.
    public static func start(at date: Date, supervised: Bool, clinician: String?) -> LeleMessage {
        var intro = "Let's build you a new plan. A few quick questions, and you can tap an answer or say it in your own words."
        if supervised, let clinician {
            intro += " Since you're in \(clinician)'s program, I'll send the plan to them to approve before it starts."
        }
        return question(.goals, answers: Answers(), at: date, lead: intro)
    }

    // MARK: - Asking

    public static func question(_ step: Step, answers: Answers, at date: Date, lead: String? = nil) -> LeleMessage {
        let (text, actions) = prompt(step)
        let body = [lead, text].compactMap { $0 }.joined(separator: "\n\n")
        return LeleMessage(createdAt: date, kind: .welcome, text: body, actions: actions, dedupeKey: key(step, answers))
    }

    static func prompt(_ step: Step) -> (String, [LeleAction]) {
        func reply(_ id: String, _ label: String) -> LeleAction { LeleAction(id: id, label: label, kind: .reply) }
        switch step {
        case .goals:
            return ("What would you like to work on now?",
                    HealthProfile.Goal.allCases.map { reply("goal:\($0.rawValue)", $0.label) })
        case .minutes:
            return ("How many minutes can you give it on most days?",
                    [5, 10, 15, 20, 30].map { reply("min:\($0)", "\($0) minutes") })
        case .experience:
            return ("How much do you exercise at the moment?",
                    HealthProfile.Experience.allCases.map { reply("exp:\($0.rawValue)", $0.label) })
        case .areas:
            return ("Is there anywhere that hurts or that you need to be careful with?",
                    HealthProfile.BodyArea.allCases.map { reply("area:\($0.rawValue)", $0.label) } + [reply("area:none", "Nothing, I'm fine")])
        case .safety:
            return ("Last one, just to be safe: has a doctor told you to be careful with exercise, or do you get chest pain or dizziness when you're active?",
                    [reply("safe:no", "No"), reply("safe:yes", "Yes")])
        }
    }

    // MARK: - Answering

    public enum Outcome: Sendable, Hashable {
        /// Ask this next (or ask the same step again, with `lead` explaining).
        case ask(Step, Answers, lead: String?)
        /// Everything is answered: build the plan.
        case build(Answers)
    }

    /// Reads one answer (a tapped option or free text) for the step encoded in `dedupeKey`.
    public static func answer(dedupeKey: String, actionId: String?, text: String?) -> Outcome? {
        guard let (step, saved) = parse(dedupeKey) else { return nil }
        var answers = saved
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let typed, !typed.isEmpty, actionId == nil { answers.said.append(typed) }
        let value = actionId.flatMap { id in id.split(separator: ":", maxSplits: 1).last.map(String.init) }

        switch step {
        case .goals:
            let goals = value.flatMap(HealthProfile.Goal.init(rawValue:)).map { [$0] } ?? typed.map(GoalsReader.goals(in:)) ?? []
            guard !goals.isEmpty else { return .ask(.goals, answers, lead: "Tell me a bit more, or pick the closest one.") }
            answers.goals = goals
            return .ask(.minutes, answers, lead: nil)
        case .minutes:
            guard let minutes = value.flatMap(Int.init) ?? typed.flatMap(GoalsReader.minutes(in:)) else {
                return .ask(.minutes, answers, lead: "Roughly how many minutes? Five is fine too.")
            }
            answers.minutes = minutes
            return .ask(.experience, answers, lead: nil)
        case .experience:
            guard let experience = value.flatMap(HealthProfile.Experience.init(rawValue:)) ?? typed.flatMap(GoalsReader.experience(in:)) else {
                return .ask(.experience, answers, lead: "Would you say you're new to it, move now and then, or train regularly?")
            }
            answers.experience = experience
            return .ask(.areas, answers, lead: nil)
        case .areas:
            let areas: [HealthProfile.BodyArea]?
            if value == "none" { areas = [] } else if let area = value.flatMap(HealthProfile.BodyArea.init(rawValue:)) { areas = [area] }
            else { areas = typed.flatMap(GoalsReader.areas(in:)) }
            guard let areas else { return .ask(.areas, answers, lead: "I'll note that. Is it one of these areas, or nothing at all?") }
            answers.areas = areas
            return .ask(.safety, answers, lead: nil)
        case .safety:
            guard let concern = value.map({ $0 == "yes" }) ?? typed.flatMap(GoalsReader.safetyConcern(in:)) else {
                return .ask(.safety, answers, lead: "Just to be safe, is that a yes or a no?")
            }
            answers.safetyConcern = concern
            return .build(answers)
        }
    }

    // MARK: - State in the dedupe key

    public static func isPlanQuestion(_ message: LeleMessage) -> Bool { message.dedupeKey?.hasPrefix("plan:") == true }

    static func key(_ step: Step, _ answers: Answers) -> String {
        let json = (try? JSONEncoder().encode(answers)).map { $0.base64EncodedString() } ?? ""
        // A fresh suffix keeps every question unique, so asking again never collides with an old one.
        return "plan:\(step.rawValue)|\(json)|\(UUID().uuidString.prefix(8))"
    }

    static func parse(_ key: String) -> (Step, Answers)? {
        guard key.hasPrefix("plan:") else { return nil }
        let parts = key.dropFirst(5).split(separator: "|", omittingEmptySubsequences: false)
        guard let first = parts.first, let step = Step(rawValue: String(first)) else { return nil }
        let answers = parts.count > 1 ? Data(base64Encoded: String(parts[1])).flatMap { try? JSONDecoder().decode(Answers.self, from: $0) } : nil
        return (step, answers ?? Answers())
    }
}
