import Foundation

/// A message in the person's conversation with Lele: something Lele started (a check-in,
/// a nudge, a reminder), a chat turn, or a note from their clinician.
public struct LeleMessage: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case welcome, morningCheckIn, calibration, nudge, barrier, reminder, progress, visitPrep, discharge, chat, clinician
    }

    public enum Author: String, Codable, Sendable, Hashable {
        case lele, person, clinician
    }

    public var id: UUID
    public var createdAt: Date
    public var kind: Kind
    public var author: Author
    public var text: String
    public var actions: [LeleAction]
    /// The action or words the person answered with.
    public var answer: String?
    public var answeredAt: Date?
    /// Stops the same nudge being sent twice (e.g. "morning-2026-09-30").
    public var dedupeKey: String?

    public init(id: UUID = UUID(), createdAt: Date, kind: Kind, author: Author = .lele, text: String, actions: [LeleAction] = [],
                answer: String? = nil, answeredAt: Date? = nil, dedupeKey: String? = nil) {
        self.id = id
        self.createdAt = createdAt
        self.kind = kind
        self.author = author
        self.text = text
        self.actions = actions
        self.answer = answer
        self.answeredAt = answeredAt
        self.dedupeKey = dedupeKey
    }

    /// Lele started this conversation (counts towards the daily limit).
    public var isInitiative: Bool {
        author == .lele && [.morningCheckIn, .calibration, .nudge, .barrier, .progress, .visitPrep].contains(kind)
    }

    public var isOpenQuestion: Bool { answeredAt == nil && actions.contains { $0.kind == .reply } }
}

public struct LeleAction: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        /// Answer the question with this option.
        case reply
        /// Start a session of an enrollment (value = enrollment id) or a quick session (value = "snack:<id>").
        case startSession
        /// Join a catalog program (value = catalog id).
        case joinProgram
        /// Open the chat, optionally with a prompt (value).
        case openChat
        /// Start a voice check-in with Lele.
        case call
    }

    public var id: String
    public var label: String
    public var kind: Kind
    public var value: String?

    public init(id: String, label: String, kind: Kind, value: String? = nil) {
        self.id = id
        self.label = label
        self.kind = kind
        self.value = value
    }
}

/// Everything Lele looks at on its round for one person.
public struct LeleRoundInput: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var firstName: String
    public var enrollments: [Enrollment]
    public var lastSessionAt: Date?
    public var sessionsToday: Int
    /// Doses scheduled for today that haven't been marked taken.
    public var dosesToday: [MedicationDose]
    /// Plateau/regression messages from progress trends.
    public var progressFlags: [String]
    public var nextVisitAt: Date?
    public var clinicianName: String?
    /// Messages from the last few days (for the daily limit and de-duplication).
    public var recentMessages: [LeleMessage]

    public init(now: Date, timeZone: TimeZone, firstName: String, enrollments: [Enrollment], lastSessionAt: Date?, sessionsToday: Int,
                dosesToday: [MedicationDose] = [], progressFlags: [String] = [], nextVisitAt: Date? = nil, clinicianName: String? = nil,
                recentMessages: [LeleMessage] = []) {
        self.now = now
        self.timeZone = timeZone
        self.firstName = firstName
        self.enrollments = enrollments
        self.lastSessionAt = lastSessionAt
        self.sessionsToday = sessionsToday
        self.dosesToday = dosesToday
        self.progressFlags = progressFlags
        self.nextVisitAt = nextVisitAt
        self.clinicianName = clinicianName
        self.recentMessages = recentMessages
    }
}

/// Lele's initiative, as rules. Code decides *when* Lele speaks up and *what can change*;
/// wording can later be personalised by the model. Guardrails: quiet hours, at most three
/// conversations started per day (reminders the person set up don't count), no repeats.
public enum LeleRound {
    public static let quietBefore = 7
    public static let quietFrom = 21
    public static let dailyLimit = 3

    public static func decide(_ input: LeleRoundInput) -> [LeleMessage] {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = input.timeZone
        let hour = calendar.component(.hour, from: input.now)
        guard hour >= quietBefore, hour < quietFrom else { return [] }
        let day = DayKey(input.now, timeZone: input.timeZone).description
        let sentKeys = Set(input.recentMessages.compactMap(\.dedupeKey))
        let startedToday = input.recentMessages.filter { $0.isInitiative && DayKey($0.createdAt, timeZone: input.timeZone).description == day }.count
        var budget = max(0, dailyLimit - startedToday)
        var out: [LeleMessage] = []

        func propose(_ key: String, initiative: Bool = true, _ make: () -> LeleMessage) {
            guard !sentKeys.contains(key), !out.contains(where: { $0.dedupeKey == key }) else { return }
            if initiative {
                guard budget > 0 else { return }
                budget -= 1
            }
            var message = make()
            message.dedupeKey = key
            out.append(message)
        }

        let active = input.enrollments.filter(\.isActive)
        let supervised = active.first(where: \.isSupervised)
        let name = input.firstName

        // Reminders for doses the person's clinician scheduled: due in the last hour, not yet taken.
        for dose in input.dosesToday where !dose.taken {
            guard let due = dose.scheduled.date(on: DayKey(input.now, timeZone: input.timeZone), timeZone: input.timeZone),
                  input.now >= due, input.now.timeIntervalSince(due) <= 3600 else { continue }
            propose("med-\(dose.medication.id)-\(day)-\(dose.scheduled.label)", initiative: false) {
                LeleMessage(createdAt: input.now, kind: .reminder,
                            text: "It's \(dose.scheduled.label): \(dose.medication.name), \(dose.medication.doseText). \(dose.medication.purpose) Tap when you've taken it.",
                            actions: [LeleAction(id: "taken", label: "Taken", kind: .reply, value: "\(dose.medication.id)|\(dose.scheduled.hour):\(dose.scheduled.minute)")])
            }
        }

        // Morning check-in for supervised programs: how is it compared with yesterday?
        if let supervised, hour < 11, input.sessionsToday == 0 {
            let area = focusArea(of: supervised.program)
            propose("morning-\(day)") {
                LeleMessage(createdAt: input.now, kind: .morningCheckIn,
                            text: "Good morning, \(name)! How's your \(area) feeling compared with yesterday?",
                            actions: [LeleAction(id: "better", label: "Better", kind: .reply),
                                      LeleAction(id: "same", label: "About the same", kind: .reply),
                                      LeleAction(id: "worse", label: "Worse", kind: .reply),
                                      LeleAction(id: "call", label: "Talk it through", kind: .call)])
            }
        }

        // A new program starts with a check-in that sets personal targets.
        for enrollment in active where enrollment.needsCalibration {
            propose("calibrate-\(enrollment.id)") {
                LeleMessage(createdAt: input.now, kind: .calibration,
                            text: "Your first \(enrollment.title) session is a quick check-in: do each move at a comfortable effort and I'll set your targets from what the camera sees. Got a few minutes?",
                            actions: [LeleAction(id: "start", label: "Start check-in", kind: .startSession, value: enrollment.id.uuidString)])
            }
        }

        // Missed sessions: one day is fine ("never miss twice"); two or more, ask what's in the way.
        if input.sessionsToday == 0, !active.isEmpty, let last = input.lastSessionAt {
            let daysSince = calendar.dateComponents([.day], from: calendar.startOfDay(for: last), to: calendar.startOfDay(for: input.now)).day ?? 0
            if daysSince >= 3 {
                propose("barrier-\(day)") {
                    LeleMessage(createdAt: input.now, kind: .barrier,
                                text: "Hi \(name), it's been \(daysSince - 1) days since your last session. No judgement, it happens. What's been getting in the way?",
                                actions: Barrier.allCases.map { LeleAction(id: $0.rawValue, label: $0.label, kind: .reply) })
                }
            } else if daysSince == 2, hour >= 16 {
                let target = supervised ?? active[0]
                propose("missed-\(day)") {
                    LeleMessage(createdAt: input.now, kind: .nudge,
                                text: "You missed yesterday, and that's fine. The trick is never missing twice: even a short session today counts.",
                                actions: [LeleAction(id: "start", label: "Start \(target.title)", kind: .startSession, value: target.id.uuidString),
                                          LeleAction(id: "quick", label: "2-minute desk reset", kind: .startSession, value: "snack:desk-reset")])
                }
            }
        }

        // A plateau: normal, but worth asking about (once a week).
        if let flag = input.progressFlags.first {
            let week = calendar.component(.weekOfYear, from: input.now)
            propose("plateau-\(week)") {
                LeleMessage(createdAt: input.now, kind: .progress,
                            text: "\(flag) That's normal; progress comes in steps. Is anything making sessions harder at the moment?"
                                + (supervised.map { _ in " I've made sure \(input.clinicianName ?? "your clinician") can see it too." } ?? ""),
                            actions: [LeleAction(id: "pain", label: "Pain", kind: .reply),
                                      LeleAction(id: "time", label: "Time", kind: .reply),
                                      LeleAction(id: "fine", label: "All fine", kind: .reply)])
            }
        }

        // Before an appointment: help prepare questions.
        if let visit = input.nextVisitAt, visit > input.now, visit.timeIntervalSince(input.now) <= 2 * 86_400 {
            let clinician = input.clinicianName ?? "your clinician"
            propose("visit-\(DayKey(visit, timeZone: input.timeZone).description)") {
                LeleMessage(createdAt: input.now, kind: .visitPrep,
                            text: "Your appointment with \(clinician) is coming up. Want me to put together a few questions to bring, from your sessions and notes?",
                            actions: [LeleAction(id: "prep", label: "Yes, help me prepare", kind: .openChat,
                                                 value: "Help me prepare questions for my appointment with \(clinician).")])
            }
        }
        return out
    }

    /// "knee", "shoulder" or "body", from what the program measures.
    public static func focusArea(of program: Program) -> String {
        let specs = program.items.compactMap { ExerciseLibrary.standard.spec($0.exerciseId) }
        if specs.contains(where: \.tracksKneeFlexion) { return "knee" }
        if specs.contains(where: { $0.kind.trackedAngle == .armRaise }) { return "shoulder" }
        return "body"
    }
}

/// What gets in the way of exercising, and what Lele says back (from the knowledge base).
public enum Barrier: String, Codable, Sendable, CaseIterable, Hashable {
    case time, pain, worried, forgot, energy

    public var label: String {
        switch self {
        case .time: return "No time"
        case .pain: return "It hurts"
        case .worried: return "Worried I'll hurt it"
        case .forgot: return "I forgot"
        case .energy: return "Low energy"
        }
    }

    public var response: String {
        switch self {
        case .time: return "Totally fair. A two-minute session still counts for your streak, and you can tuck it in after brushing your teeth or while the kettle boils."
        case .pain: return "Thanks for telling me. I've noted it for your records so your program can be adjusted, and I'll make the sore exercises easier. If pain is sharp or keeps getting worse, please contact your clinician."
        case .worried: return "That worry is really common. Your exercises are chosen to be safe for where you are, and pulling or stretching feelings are expected. Tell me how it feels as you go and I'll stop you if anything's outside your limits."
        case .forgot: return "Easily done! I'll nudge you at a good time. Leaving your phone stand where you exercise helps too."
        case .energy: return "Some days are like that. A gentle version still counts, and it often helps with energy. Want a short one?"
        }
    }
}

extension TimeOfDay {
    /// This time on a given calendar day.
    public func date(on day: DayKey, timeZone: TimeZone) -> Date? {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        return calendar.date(from: DateComponents(timeZone: timeZone, year: day.year, month: day.month, day: day.day, hour: hour, minute: minute))
    }
}
