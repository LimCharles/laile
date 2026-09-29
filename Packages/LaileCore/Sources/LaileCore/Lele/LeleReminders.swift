import Foundation

/// A reminder Lele leaves on the phone, for when the app is closed.
public struct PlannedReminder: Sendable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Hashable {
        case medication, morningCheckIn, sessionNudge
    }

    public var id: String
    public var kind: Kind
    public var date: Date
    public var body: String

    public init(id: String, kind: Kind, date: Date, body: String) {
        self.id = id
        self.kind = kind
        self.date = date
        self.body = body
    }
}

/// Which reminders to put on the phone for the next few days. The phone can't run Lele's round
/// while the app is closed, so these cover the moments that matter: medicine times, the morning
/// check-in while a physio supervises, and an evening nudge if today's session hasn't happened.
/// Opening a reminder brings the person to Lele, whose round has the full message.
public enum LeleReminders {
    public static let checkInTime = TimeOfDay(8, 30)
    public static let nudgeTime = TimeOfDay(18, 30)
    public static let days = 3

    public struct Input: Sendable {
        public var now: Date
        public var timeZone: TimeZone
        public var enrollments: [Enrollment]
        public var medications: [Medication]
        /// Today's doses, to skip the ones already taken.
        public var dosesToday: [MedicationDose]
        public var sessionDoneToday: Bool

        public init(now: Date, timeZone: TimeZone, enrollments: [Enrollment], medications: [Medication] = [],
                    dosesToday: [MedicationDose] = [], sessionDoneToday: Bool = false) {
            self.now = now
            self.timeZone = timeZone
            self.enrollments = enrollments
            self.medications = medications
            self.dosesToday = dosesToday
            self.sessionDoneToday = sessionDoneToday
        }
    }

    public static func plan(_ input: Input) -> [PlannedReminder] {
        let today = DayKey(input.now, timeZone: input.timeZone)
        let active = input.enrollments.filter(\.isActive)
        let supervised = active.first(where: \.isSupervised)
        let taken = Set(input.dosesToday.filter(\.taken).map { "\($0.medication.id)-\($0.scheduled.hour)-\($0.scheduled.minute)" })
        var out: [PlannedReminder] = []

        func add(_ id: String, _ kind: PlannedReminder.Kind, _ time: TimeOfDay, on day: DayKey, _ body: String) {
            guard let date = time.date(on: day, timeZone: input.timeZone), date > input.now else { return }
            out.append(PlannedReminder(id: "\(id)-\(day)", kind: kind, date: date, body: body))
        }

        for offset in 0..<days {
            let day = today.adding(days: offset)
            for medication in input.medications {
                if let ends = medication.endsOn, ends < day { continue }
                for time in medication.times {
                    let key = "\(medication.id)-\(time.hour)-\(time.minute)"
                    if offset == 0, taken.contains(key) { continue }
                    add("med-\(key)", .medication, time, on: day,
                        "Time for your \(medication.name), \(medication.doseText). Tap to tell me when you've taken it.")
                }
            }
            if let supervised {
                add("checkin", .morningCheckIn, checkInTime, on: day,
                    "Good morning! How's your \(LeleRound.focusArea(of: supervised.program)) feeling today?")
            }
            if !active.isEmpty, !(offset == 0 && input.sessionDoneToday) {
                let title = supervised?.title ?? active[0].title
                add("nudge", .sessionNudge, nudgeTime, on: day, "Still time for today's \(title) session. Even a short one counts.")
            }
        }
        return out.sorted { $0.date < $1.date }
    }
}
