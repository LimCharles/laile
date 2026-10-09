import Foundation

/// A supervised person asking their physio to add a catalog program. Lele passes it on; only the
/// physio can approve it.
public struct ProgramRequest: Codable, Sendable, Hashable, Identifiable {
    public enum Status: String, Codable, Sendable, Hashable {
        case pending, approved, declined
    }

    public var id: UUID
    public var catalogId: String
    public var title: String
    public var status: Status
    /// The physio's note when they answer.
    public var note: String?
    public var createdAt: Date
    public var decidedAt: Date?

    public init(id: UUID = UUID(), catalogId: String, title: String, status: Status = .pending, note: String? = nil,
                createdAt: Date, decidedAt: Date? = nil) {
        self.id = id
        self.catalogId = catalogId
        self.title = title
        self.status = status
        self.note = note
        self.createdAt = createdAt
        self.decidedAt = decidedAt
    }
}

/// One line in a clinician's daily list: something Lele noticed about a patient.
public struct BriefItem: Codable, Sendable, Hashable, Identifiable {
    public enum Kind: String, Codable, Sendable, Hashable {
        case redFlag, worse, painReports, request, draft, missed, barrier, checkIn, plateau, visit
    }

    public enum Priority: Int, Codable, Sendable, Hashable, Comparable {
        /// Look now.
        case urgent = 0
        /// Worth acting on today.
        case today
        /// Good to know.
        case fyi

        public static func < (lhs: Priority, rhs: Priority) -> Bool { lhs.rawValue < rhs.rawValue }
    }

    public var id: String
    public var kind: Kind
    public var priority: Priority
    public var text: String
    public var at: Date?
    /// For approvals.
    public var requestId: UUID?
    /// For drafts waiting for a signature.
    public var programId: UUID?

    public init(id: String, kind: Kind, priority: Priority, text: String, at: Date? = nil, requestId: UUID? = nil, programId: UUID? = nil) {
        self.id = id
        self.kind = kind
        self.priority = priority
        self.text = text
        self.at = at
        self.requestId = requestId
        self.programId = programId
    }
}

/// Everything about one patient that the daily list looks at.
public struct BriefInput: Sendable {
    public var now: Date
    public var timeZone: TimeZone
    public var redFlags: [(at: Date, text: String)]
    public var unreviewedReports: [Date]
    public var careNotes: [CareNote]
    public var lastSessionAt: Date?
    public var hasSignedProgram: Bool
    public var checkIns: [(title: String, at: Date)]
    public var drafts: [Program]
    public var requests: [ProgramRequest]
    public var progressFlags: [String]
    public var nextVisitAt: Date?

    public init(now: Date, timeZone: TimeZone, redFlags: [(at: Date, text: String)] = [], unreviewedReports: [Date] = [],
                careNotes: [CareNote] = [], lastSessionAt: Date? = nil, hasSignedProgram: Bool = true,
                checkIns: [(title: String, at: Date)] = [], drafts: [Program] = [], requests: [ProgramRequest] = [],
                progressFlags: [String] = [], nextVisitAt: Date? = nil) {
        self.now = now
        self.timeZone = timeZone
        self.redFlags = redFlags
        self.unreviewedReports = unreviewedReports
        self.careNotes = careNotes
        self.lastSessionAt = lastSessionAt
        self.hasSignedProgram = hasSignedProgram
        self.checkIns = checkIns
        self.drafts = drafts
        self.requests = requests
        self.progressFlags = progressFlags
        self.nextVisitAt = nextVisitAt
    }
}

/// The clinician's daily list, as rules: what Lele saw since yesterday, most pressing first.
/// Plain code picks what's on it, and nothing here changes a program.
public enum ClinicianBrief {
    public static let missedDays = 3

    public static func items(for input: BriefInput) -> [BriefItem] {
        let day: TimeInterval = 86_400
        let now = input.now
        var out: [BriefItem] = []

        for (i, flag) in input.redFlags.enumerated() {
            out.append(BriefItem(id: "red-\(i)", kind: .redFlag, priority: .urgent, text: "Red flag: \(flag.text)", at: flag.at))
        }
        if let latest = input.unreviewedReports.max() {
            let n = input.unreviewedReports.count
            out.append(BriefItem(id: "pain", kind: .painReports, priority: .today,
                                 text: "\(n) pain report\(n == 1 ? "" : "s") to review", at: latest))
        }
        for note in input.careNotes where note.isActive && note.kind == .flare && now.timeIntervalSince(note.createdAt) < day {
            out.append(BriefItem(id: "worse-\(note.id)", kind: .worse, priority: .today,
                                 text: "Said things were worse this morning. Lele made today's session gentler.", at: note.createdAt))
        }
        for request in input.requests where request.status == .pending {
            out.append(BriefItem(id: "request-\(request.id)", kind: .request, priority: .today,
                                 text: "Asks to add \(request.title) alongside their program", at: request.createdAt, requestId: request.id))
        }
        for draft in input.drafts where draft.status == .draft {
            out.append(BriefItem(id: "draft-\(draft.id)", kind: .draft, priority: .today,
                                 text: "Program v\(draft.version) is waiting for your signature", at: draft.createdAt, programId: draft.id))
        }
        if input.hasSignedProgram {
            if let last = input.lastSessionAt {
                let days = Int(now.timeIntervalSince(last) / day)
                if days >= missedDays {
                    out.append(BriefItem(id: "missed", kind: .missed, priority: .today,
                                         text: "No session in \(days) days. Lele is asking what's getting in the way.", at: last))
                }
            } else {
                out.append(BriefItem(id: "missed", kind: .missed, priority: .today, text: "Hasn't done a session yet"))
            }
        }
        for note in input.careNotes where note.kind == .barrier && now.timeIntervalSince(note.createdAt) < 3 * day {
            out.append(BriefItem(id: "barrier-\(note.id)", kind: .barrier, priority: .fyi, text: "Told Lele what's getting in the way: \(note.text.lowercased())", at: note.createdAt))
        }
        for checkIn in input.checkIns where now.timeIntervalSince(checkIn.at) < 2 * day {
            out.append(BriefItem(id: "checkin-\(checkIn.title)", kind: .checkIn, priority: .fyi,
                                 text: "Did the check-in for \(checkIn.title); targets are set", at: checkIn.at))
        }
        for (i, flag) in input.progressFlags.enumerated() {
            out.append(BriefItem(id: "trend-\(i)", kind: .plateau, priority: .fyi, text: flag))
        }
        if let visit = input.nextVisitAt, visit > now, visit.timeIntervalSince(now) < 2 * day {
            var calendar = Calendar(identifier: .gregorian)
            calendar.timeZone = input.timeZone
            let f = DateFormatter()
            f.timeZone = input.timeZone
            f.dateFormat = "EEEE"
            let when = calendar.isDate(visit, inSameDayAs: now) ? "today"
                : calendar.isDate(visit, inSameDayAs: now.addingTimeInterval(day)) ? "tomorrow" : "on \(f.string(from: visit))"
            f.dateFormat = "h:mm a"
            out.append(BriefItem(id: "visit", kind: .visit, priority: .fyi, text: "Visit \(when) at \(f.string(from: visit)). Lele is helping them prepare.", at: visit))
        }
        return out.sorted { a, b in
            if a.priority != b.priority { return a.priority < b.priority }
            return (a.at ?? .distantPast) > (b.at ?? .distantPast)
        }
    }
}
