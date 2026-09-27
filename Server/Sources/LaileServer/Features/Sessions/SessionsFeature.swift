import Fluent
import LaileCore
import Vapor

final class SessionModel: Model, @unchecked Sendable {
    static let schema = "sessions"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "kind") var kind: String
    @Field(key: "started_at") var startedAt: Date
    @Field(key: "payload") var summary: SessionSummary

    init() {}

    init(userID: UUID, summary: SessionSummary) {
        self.id = summary.id
        self.$user.id = userID
        self.kind = summary.kind.rawValue
        self.startedAt = summary.startedAt
        self.summary = summary
    }
}

final class MetricSampleModel: Model, @unchecked Sendable {
    static let schema = "metric_samples"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "kind") var kind: String
    @Field(key: "value") var value: Double
    @Field(key: "date") var date: Date
    @Field(key: "is_baseline") var isBaseline: Bool
    @OptionalField(key: "exercise_id") var exerciseId: String?
    @OptionalField(key: "session_id") var sessionId: UUID?

    init() {}

    init(userID: UUID, sample: MetricSample) {
        self.id = sample.id
        self.$user.id = userID
        self.kind = sample.kind.rawValue
        self.value = sample.value
        self.date = sample.date
        self.isBaseline = sample.isBaseline
        self.exerciseId = sample.exerciseId
        self.sessionId = sample.sessionId
    }

    var sample: MetricSample? {
        MetricKind(rawValue: kind).map {
            MetricSample(id: id ?? UUID(), kind: $0, value: value, date: date, isBaseline: isBaseline, exerciseId: exerciseId, sessionId: sessionId)
        }
    }

    static func samples(for userID: UUID, on db: Database) async throws -> [MetricSample] {
        try await query(on: db).filter(\.$user.$id == userID).sort(\.$date).all().compactMap(\.sample)
    }
}

final class SymptomReportModel: Model, @unchecked Sendable {
    static let schema = "symptom_reports"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @OptionalField(key: "session_id") var sessionId: UUID?
    @Field(key: "category") var category: String
    @OptionalField(key: "severity") var severity: Int?
    @Field(key: "reported_at") var reportedAt: Date
    @Field(key: "payload") var report: SymptomReport
    @OptionalField(key: "reviewed_at") var reviewedAt: Date?
    @OptionalField(key: "reviewed_by") var reviewedBy: String?

    init() {}

    init(userID: UUID, sessionId: UUID?, report: SymptomReport) {
        self.id = report.id
        self.$user.id = userID
        self.sessionId = sessionId
        self.category = report.category.rawValue
        self.severity = report.severity
        self.reportedAt = report.timestamp
        self.report = report
    }
}

struct CreateSessions: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(SessionModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("started_at", .datetime, .required)
            .field("payload", .json, .required)
            .create()
        try await database.schema(MetricSampleModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("value", .double, .required)
            .field("date", .datetime, .required)
            .field("is_baseline", .bool, .required)
            .field("exercise_id", .string)
            .field("session_id", .uuid)
            .create()
        try await database.schema(SymptomReportModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("session_id", .uuid)
            .field("category", .string, .required)
            .field("severity", .int)
            .field("reported_at", .datetime, .required)
            .field("payload", .json, .required)
            .field("reviewed_at", .datetime)
            .field("reviewed_by", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(SymptomReportModel.schema).delete()
        try await database.schema(MetricSampleModel.schema).delete()
        try await database.schema(SessionModel.schema).delete()
    }
}

/// Stores a finished session and everything derived from it, in one place so the demo
/// seeder, the API and tests all go through the same path.
struct SessionRecorder {
    let db: Database
    let library: ExerciseLibrary
    let ledger: RewardsLedger

    func record(_ summary: SessionSummary, userID: UUID, now: Date = Date()) async throws -> API.SessionSubmitResponse {
        guard try await SessionModel.find(summary.id, on: db) == nil else {
            throw Abort(.conflict, reason: "Session already submitted.")
        }
        try await SessionModel(userID: userID, summary: summary).create(on: db)

        // Metrics + achievements (PBs, milestones) against this user's history.
        let history = try await MetricSampleModel.samples(for: userID, on: db)
        let newSamples = MetricExtractor.samples(from: summary, library: library)
        for sample in newSamples { try await MetricSampleModel(userID: userID, sample: sample).create(on: db) }
        let mode = ledger.user.mode
        let achievements = ProgressAnalyzer.achievements(adding: newSamples, to: history, milestones: Milestone.defaults(for: mode))

        for report in summary.symptoms {
            try await SymptomReportModel(userID: userID, sessionId: summary.id, report: report).create(on: db)
        }

        // Rewards: one movement record, plus a PB bonus when earned.
        let activityKind: ActivityKind = switch summary.kind {
        case .baseline: .baseline
        case .stream: .stream
        case .snack: summary.isStretchOnly ? .stretch : .snack
        case .program, .workout: .session
        }
        let rewardHistory = try await ledger.history()
        var extras: [ActivityRecord] = []
        let today = ledger.engine.today(summary.endedAt)
        if achievements.contains(where: { if case .personalBest = $0 { return true }; return false }) {
            extras.append(ActivityRecord(day: today, kind: .bonus, xp: 30, at: summary.endedAt, refId: "pb-\(summary.id)", note: "Personal best"))
        }
        let movement = ledger.engine.recordMovement(kind: activityKind, reps: summary.verifiedReps, refId: summary.id.uuidString,
                                                   now: summary.endedAt, history: rewardHistory, extraBonuses: extras)
        try await ledger.append(movement.records)
        let rewards = ledger.engine.summary(now: now, history: rewardHistory + movement.records)
        return API.SessionSubmitResponse(movement: movement, achievements: achievements, summary: rewards)
    }
}

struct SessionsFeature: LaileFeature {
    let name = "sessions"
    var migrations: [any Migration] { [CreateSessions()] }

    func boot(_ app: Application) async throws {
        let sessions = app.protected.grouped("sessions")
        sessions.post { req async throws -> API.SessionSubmitResponse in
            let user = try req.user
            let summary = try req.content.decode(SessionSummary.self)
            let recorder = SessionRecorder(db: req.db, library: req.laile.library, ledger: req.ledger(for: user))
            return try await recorder.record(summary, userID: user.requireID())
        }
        sessions.get { req async throws -> [SessionSummary] in
            let limit = min(req.query[Int.self, at: "limit"] ?? 20, 100)
            return try await SessionModel.query(on: req.db).filter(\.$user.$id == req.user.requireID())
                .sort(\.$startedAt, .descending).limit(limit).all().map(\.summary)
        }
    }
}

struct ProgressFeature: LaileFeature {
    let name = "progress"

    func boot(_ app: Application) async throws {
        app.protected.get("progress") { req async throws -> API.ProgressOverview in
            let user = try req.user
            let samples = try await MetricSampleModel.samples(for: user.requireID(), on: req.db)
            let recent = try await SessionModel.query(on: req.db).filter(\.$user.$id == user.requireID())
                .sort(\.$startedAt, .descending).limit(10).all().map(\.summary)
            return API.ProgressOverview(trends: ProgressOverviewBuilder.trends(samples: samples, mode: user.mode), recentSessions: recent)
        }
    }
}

enum ProgressOverviewBuilder {
    static func trends(samples: [MetricSample], mode: AppMode) -> [MetricTrend] {
        let kinds = MetricKind.allCases.filter { kind in samples.contains { $0.kind == kind } }
        return kinds.map { ProgressAnalyzer.trend(kind: $0, samples: samples, milestones: Milestone.defaults(for: mode)) }
    }
}
