import Fluent
import LaileCore
import Vapor

/// A message in someone's conversation with Lele (kept here so their clinician can read it too).
final class LeleMessageModel: Model, @unchecked Sendable {
    static let schema = "lele_messages"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "created_at") var createdAt: Date
    @Field(key: "kind") var kind: String
    @OptionalField(key: "dedupe_key") var dedupeKey: String?
    @Field(key: "payload") var message: LeleMessage

    init() {}

    init(userID: UUID, message: LeleMessage) {
        self.id = message.id
        self.$user.id = userID
        apply(message)
    }

    func apply(_ message: LeleMessage) {
        createdAt = message.createdAt
        kind = message.kind.rawValue
        dedupeKey = message.dedupeKey
        self.message = message
    }
}

struct CreateLeleMessages: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(LeleMessageModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("created_at", .datetime, .required)
            .field("kind", .string, .required)
            .field("dedupe_key", .string)
            .field("payload", .json, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(LeleMessageModel.schema).delete()
    }
}

/// Lele's side of the conversation: running the round, handling answers, chatting.
struct LeleService {
    let app: Application
    let db: Database
    let logger: Logger

    func recent(for userID: UUID, limit: Int = 40) async throws -> [LeleMessage] {
        try await LeleMessageModel.query(on: db).filter(\.$user.$id == userID).sort(\.$createdAt, .descending).limit(limit).all().map(\.message)
    }

    func save(_ message: LeleMessage, userID: UUID) async throws {
        if let existing = try await LeleMessageModel.find(message.id, on: db) {
            existing.apply(message)
            try await existing.save(on: db)
        } else {
            try await LeleMessageModel(userID: userID, message: message).create(on: db)
        }
    }

    /// Lele's round for one person: gathers what's happened and lets the rules decide whether to speak up.
    @discardableResult
    /// `stampedAt` overrides the messages' time (the demo runs a round as if it were daytime).
    func round(for user: UserModel, now: Date = Date(), stampedAt: Date? = nil) async throws -> [LeleMessage] {
        let userID = try user.requireID()
        let timeZone = TimeZone(identifier: user.timeZone) ?? TimeZone(identifier: "Asia/Singapore")!
        let enrollments = try await EnrollmentStore(db: db).active(for: userID)
        guard !enrollments.isEmpty else { return [] }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let startOfDay = calendar.startOfDay(for: now)
        let sessions = try await SessionModel.query(on: db).filter(\.$user.$id == userID).sort(\.$startedAt, .descending).limit(20).all()
        let profile = try await activePatientProfile(for: userID)
        var doses: [MedicationDose] = []
        if let profile {
            let day = DayKey(now, timeZone: timeZone)
            let log = try await MedicationLogModel.query(on: db).filter(\.$user.$id == userID).filter(\.$day == day.description).all().compactMap(\.entry)
            doses = MedicationSchedule.doses(for: profile.medications, on: day, log: log)
        }
        let samples = try await MetricSampleModel.samples(for: userID, on: db)
        let flags = ProgressOverviewBuilder.trends(samples: samples, mode: user.mode)
            .filter { $0.kind != .painAtRest }.flatMap(\.flags).map(\.message)
        let recent = try await LeleMessageModel.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$createdAt >= now.addingTimeInterval(-4 * 86_400)).all().map(\.message)
        let input = LeleRoundInput(
            now: now, timeZone: timeZone, firstName: Self.firstName(user.displayName), enrollments: enrollments,
            lastSessionAt: sessions.first?.startedAt, sessionsToday: sessions.filter { $0.startedAt >= startOfDay }.count,
            dosesToday: doses, progressFlags: flags, nextVisitAt: profile?.nextVisitAt, clinicianName: profile.map { CallName.plain($0.clinician.displayName) },
            recentMessages: recent
        )
        var messages = LeleRound.decide(input)
        if let stampedAt { messages = messages.map { var m = $0; m.createdAt = stampedAt; return m } }
        for message in messages { try await save(message, userID: userID) }
        return messages
    }

    func activePatientProfile(for userID: UUID) async throws -> PatientProfileModel? {
        try await PatientProfileModel.query(on: db).filter(\.$user.$id == userID).filter(\.$dischargedAt == nil).with(\.$clinician).first()
    }

    /// Someone tapped an answer (or typed one) to a question Lele asked.
    func reply(to messageID: UUID, actionId: String?, text: String?, user: UserModel) async throws -> API.LeleTurnResponse {
        let userID = try user.requireID()
        guard let model = try await LeleMessageModel.find(messageID, on: db), model.$user.id == userID else { throw Abort(.notFound) }
        var question = model.message
        guard question.answeredAt == nil else { return API.LeleTurnResponse(messages: []) }
        let now = Date()
        let typed = text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        // Buttons are suggestions: a typed answer is matched to the option it means.
        let action = actionId.flatMap { id in question.actions.first { $0.id == id } }
            ?? typed.flatMap { ReplyReader.action(in: question, for: $0) }
        guard typed != nil || action != nil else { throw Abort(.badRequest, reason: "Pick an answer or type one.") }
        let answer = typed ?? action?.label ?? ""
        if PlanChat.isPlanQuestion(question), let key = question.dedupeKey {
            return try await planTurn(question, key: key, actionId: action?.id, typed: typed, answer: answer, user: user)
        }
        question.answer = answer
        question.answeredAt = now
        // The question is only saved as answered once the turn has succeeded, so a failed reply
        // can be answered again.
        var out: [LeleMessage] = [question, LeleMessage(createdAt: now, kind: .chat, author: .person, text: answer)]
        var notes: [CareNote] = []
        let clinician = try await activePatientProfile(for: userID).map { CallName.plain($0.clinician.displayName) }
        func say(_ text: String, actions: [LeleAction] = []) {
            out.append(LeleMessage(createdAt: now.addingTimeInterval(1), kind: .chat, text: text, actions: actions))
        }

        switch (question.kind, action?.id) {
        case (.morningCheckIn, "better"?):
            say("Brilliant, that's what we like to see. Today's session is as planned.")
        case (.morningCheckIn, "same"?):
            say("Steady is fine. Today's session is as planned; tell me if anything feels off while we go.")
        case (.morningCheckIn, "worse"?):
            let flare = CareMemory.flare(at: now, reply: answer)
            try await CareNoteStore(db: db).save(flare, userID: userID)
            notes.append(flare)
            say("Sorry to hear that. I've made today's session gentler (smaller range, shorter holds) and noted it for \(clinician ?? "your records"). If it keeps getting worse, or you notice a hot, swollen calf or a fever, contact your care team today.")
        case (.barrier, let id?), (.progress, let id?):
            if let barrier = Barrier(rawValue: id) {
                let note = CareMemory.barrier(barrier, at: now)
                try await CareNoteStore(db: db).save(note, userID: userID)
                notes.append(note)
                let short = try await EnrollmentStore(db: db).active(for: userID).first
                say(barrier.response, actions: [short.map { LeleAction(id: "start", label: "Start \($0.title)", kind: .startSession, value: $0.id.uuidString) }
                                                 ?? LeleAction(id: "quick", label: "2-minute desk reset", kind: .startSession, value: "snack:desk-reset")])
            } else if id == "fine" {
                say("Good to hear. Steady weeks are normal before the next jump. Keep going!")
            }
        case (.reminder, "taken"?):
            if let value = action?.value, let (medID, time) = Self.parseDose(value) {
                let timeZone = TimeZone(identifier: user.timeZone) ?? .current
                let entry = MedicationLogEntry(medicationId: medID, day: DayKey(now, timeZone: timeZone), scheduled: time, takenAt: now)
                try await MedicationLogModel(userID: userID, entry: entry).create(on: db)
            }
            say("Thanks, noted.")
        default:
            if let typed {
                let turn = try await chat(typed, user: user, echo: false, prefix: out)
                try await save(question, userID: userID)
                return turn
            }
        }
        try await save(question, userID: userID)
        for message in out.dropFirst(2) { try await save(message, userID: userID) }
        try await save(out[1], userID: userID)
        return API.LeleTurnResponse(messages: out, careNotes: notes)
    }

    /// One answer in planning-by-chat: ask the next question, or build the plan once all five are in.
    func planTurn(_ question: LeleMessage, key: String, actionId: String?, typed: String?, answer: String,
                  user: UserModel) async throws -> API.LeleTurnResponse {
        let userID = try user.requireID()
        // A red flag said mid-planning is never read as an answer.
        if let typed, RedFlagDetector.detect(typed) != nil { return try await chat(typed, user: user) }
        guard let outcome = PlanChat.answer(dedupeKey: key, actionId: actionId, text: typed) else { return API.LeleTurnResponse(messages: []) }
        let now = Date()
        var answered = question
        answered.answer = answer
        answered.answeredAt = now
        let mine = LeleMessage(createdAt: now, kind: .chat, author: .person, text: answer)
        try await save(mine, userID: userID)
        var out = [answered, mine]
        switch outcome {
        case .ask(let step, let answers, let lead):
            let next = PlanChat.question(step, answers: answers, at: now.addingTimeInterval(1), lead: lead)
            try await save(next, userID: userID)
            out.append(next)
        case .build(let answers):
            let base = try await HealthStore(db: db).get(userID)
            let built = try await LelePlanService(app: app, db: db, logger: logger).build(answers.profile(base: base, at: now), user: user)
            out += built.messages
        }
        try await save(answered, userID: userID)
        return API.LeleTurnResponse(messages: out)
    }

    /// Free chat with Lele. Safety rules answer first; the model (ADP, then Hunyuan) otherwise; offline rules last.
    func chat(_ text: String, user: UserModel, echo: Bool = true, prefix: [LeleMessage] = []) async throws -> API.LeleTurnResponse {
        let userID = try user.requireID()
        let now = Date()
        var out = prefix
        let mine = LeleMessage(createdAt: now, kind: .chat, author: .person, text: text)
        if echo { out.append(mine) }
        try await save(mine, userID: userID)

        var replyText: String
        var notes: [CareNote] = []
        if let flag = RedFlagDetector.detect(text) {
            replyText = flag.level == .emergency
                ? "Please stop and call 995 now, or ask someone nearby to help you. \(flag.reason.capitalized) needs urgent attention."
                : "Please don't exercise today and contact your care team or a doctor today about the \(flag.reason). I've noted it for your records."
        } else if MedicationBoundary.isDoseQuestion(text) {
            replyText = MedicationBoundary.referral
        } else if PlanChat.wantsNewPlan(text) {
            // "I want a new program": Lele plans it with them right here in the chat.
            let supervisor = try await activePatientProfile(for: userID)
            let question = PlanChat.start(at: now.addingTimeInterval(1), supervised: supervisor != nil,
                                          clinician: supervisor.map { CallName.plain($0.clinician.displayName) })
            try await save(question, userID: userID)
            out.append(question)
            return API.LeleTurnResponse(messages: out)
        } else {
            let context = try await LeleContext.build(for: user, db: db)
            replyText = try await LeleAgent(app: app, logger: logger).reply(to: text, context: context, userID: userID)
            let (clean, remember) = LeleAgent.extractRemember(replyText)
            replyText = clean
            if let remember, let note = remember.careNote(at: now) {
                try await CareNoteStore(db: db).save(note, userID: userID)
                notes.append(note)
            }
        }
        let reply = LeleMessage(createdAt: now.addingTimeInterval(1), kind: .chat, text: replyText)
        try await save(reply, userID: userID)
        out.append(reply)
        return API.LeleTurnResponse(messages: out, careNotes: notes)
    }

    static func firstName(_ displayName: String) -> String { CallName.from(displayName) }

    static func parseDose(_ value: String) -> (UUID, TimeOfDay)? {
        let parts = value.split(separator: "|")
        guard parts.count == 2, let id = UUID(uuidString: String(parts[0])) else { return nil }
        let hm = parts[1].split(separator: ":").compactMap { Int($0) }
        guard hm.count == 2 else { return nil }
        return (id, TimeOfDay(hm[0], hm[1]))
    }
}

/// What Lele knows about someone, as the PATIENT CONTEXT and CARE NOTES blocks its prompt expects.
enum LeleContext {
    static func build(for user: UserModel, db: Database) async throws -> String {
        let userID = try user.requireID()
        var lines: [String] = ["PATIENT CONTEXT: \(user.displayName)."]
        for enrollment in try await EnrollmentStore(db: db).active(for: userID) {
            let items = enrollment.program.items.compactMap { item in ExerciseLibrary.standard.spec(item.exerciseId).map { "\($0.name) \(item.dose.shortDescription)" } }
            var line = "Program: \(enrollment.title) (\(enrollment.kind.rawValue)\(enrollment.supervisorName.map { ", supervised by \($0)" } ?? "")): \(items.joined(separator: ", "))."
            if let calibration = enrollment.calibration {
                line += " First-session check-in: " + calibration.exercises.map(\.summary).joined(separator: "; ") + "."
            }
            lines.append(line)
        }
        if let health = try await HealthStore(db: db).get(userID) {
            lines.append("Goals: \(health.goals.map(\.label).joined(separator: ", ")); \(health.minutesPerDay) min a day; careful with: \(health.sensitiveAreas.map(\.label).joined(separator: ", ")).")
        }
        let samples = try await MetricSampleModel.samples(for: userID, on: db)
        for trend in ProgressOverviewBuilder.trends(samples: samples, mode: user.mode) {
            guard let latest = trend.latest else { continue }
            let recent = trend.samples.suffix(5).map { trend.kind.format($0.value) }.joined(separator: ", ")
            lines.append("\(trend.kind.displayName): latest \(trend.kind.format(latest.value)) (last sessions: \(recent)).")
        }
        let sessions = try await SessionModel.query(on: db).filter(\.$user.$id == userID).sort(\.$startedAt, .descending).limit(1).all()
        if let last = sessions.first { lines.append("Last session: \(last.summary.title), \(Formatters.relative(last.startedAt)).") }
        let notes = try await CareNoteStore(db: db).all(for: userID).filter(\.isActive)
        if !notes.isEmpty { lines.append("CARE NOTES: " + notes.map(\.contextLine).joined(separator: " | ")) }
        return lines.joined(separator: "\n")
    }
}

/// Parsed `{"remember": {...}}` line from Lele's reply.
struct RememberRequest: Codable {
    struct Body: Codable {
        var kind: String
        var exercise_id: String?
        var body_location: String?
        var severity: Int?
        var note: String
    }
    var remember: Body

    func careNote(at date: Date) -> CareNote? {
        // The model writes this JSON, so its numbers and text are bounded before they reach a record.
        var body = remember
        body.note = String(body.note.trimmingCharacters(in: .whitespacesAndNewlines).prefix(500))
        body.severity = body.severity.map { min(max($0, 0), 10) }
        guard !body.note.isEmpty else { return nil }
        let exercise = body.exercise_id.flatMap { ExerciseLibrary.standard.spec($0) }
        switch body.kind {
        case "sore_spot", "feels_wrong":
            guard let exercise else { return nil }
            let report = SymptomReport(timestamp: date, category: body.kind == "feels_wrong" ? .wrongSensation : .pain, utterance: body.note,
                                       bodyLocation: body.body_location, severity: body.severity ?? 4, source: .typed, exerciseId: exercise.id)
            return CareMemory.update([], after: SessionSummary(kind: .program, title: "Chat with Lele", mode: .move, startedAt: date, endedAt: date,
                                                               symptoms: [report])).first.map { note in
                var n = note
                n.source = .lele
                return n
            }
        default:
            var note = CareNote(createdAt: date, kind: .barrier, source: .lele, exerciseId: exercise?.id, text: body.note,
                                events: [.init(date: date, text: "Told Lele: \(body.note)")])
            note.status = .resolved
            return note
        }
    }
}

struct LeleFeature: LaileFeature {
    let name = "lele"
    var migrations: [any Migration] { [CreateLeleMessages()] }

    func boot(_ app: Application) async throws {
        let lele = app.protected.grouped("lele")
        lele.get("messages") { req async throws -> [LeleMessage] in
            let user = try req.user
            let service = LeleService(app: req.application, db: req.db, logger: req.logger)
            try await service.round(for: user)
            return try await service.recent(for: user.requireID())
        }
        lele.post("messages", ":id", "reply") { req async throws -> API.LeleTurnResponse in
            guard let id = req.parameters.get("id", as: UUID.self) else { throw Abort(.badRequest) }
            let body = try req.content.decode(API.LeleReplyRequest.self)
            // Same limits as chat: a typed answer is trimmed and capped at 1000 characters.
            let text = body.text?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty.map { String($0.prefix(1000)) }
            return try await LeleService(app: req.application, db: req.db, logger: req.logger)
                .reply(to: id, actionId: body.actionId, text: text, user: req.user)
        }
        lele.post("chat") { req async throws -> API.LeleTurnResponse in
            let body = try req.content.decode(API.LeleChatRequest.self)
            let text = body.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { throw Abort(.badRequest) }
            return try await LeleService(app: req.application, db: req.db, logger: req.logger).chat(String(text.prefix(1000)), user: req.user)
        }

        // Lele's round runs on its own every 15 minutes (and whenever the app asks for messages).
        guard app.environment != .testing else { return }
        app.eventLoopGroup.next().scheduleRepeatedAsyncTask(initialDelay: .minutes(1), delay: .minutes(15)) { _ in
            let db = app.db
            let logger = app.logger
            return app.eventLoopGroup.next().makeFutureWithTask {
                do {
                    let userIDs = Set(try await EnrollmentModel.query(on: db).filter(\.$status == Enrollment.Status.active.rawValue).all().map { $0.$user.id })
                    for id in userIDs {
                        guard let user = try await UserModel.find(id, on: db) else { continue }
                        try await LeleService(app: app, db: db, logger: logger).round(for: user)
                    }
                } catch {
                    logger.warning("Lele round failed: \(error)")
                }
            }
        }
    }
}
