import Fluent
import LaileCore
import Vapor

final class ActivityRecordModel: Model, @unchecked Sendable {
    static let schema = "activity_records"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "day") var day: String
    @Field(key: "kind") var kind: String
    @Field(key: "xp") var xp: Int
    @Field(key: "at") var at: Date
    @Field(key: "reps") var reps: Int
    @OptionalField(key: "ref_id") var refId: String?
    @OptionalField(key: "note") var note: String?

    init() {}

    init(userID: UUID, record: ActivityRecord) {
        self.id = record.id
        self.$user.id = userID
        self.day = record.day.description
        self.kind = record.kind.rawValue
        self.xp = record.xp
        self.at = record.at
        self.reps = record.reps
        self.refId = record.refId
        self.note = record.note
    }

    var record: ActivityRecord? {
        guard let day = DayKey(day), let kind = ActivityKind(rawValue: kind) else { return nil }
        return ActivityRecord(id: id ?? UUID(), day: day, kind: kind, xp: xp, at: at, reps: reps, refId: refId, note: note)
    }
}

struct CreateActivityRecords: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ActivityRecordModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("day", .string, .required)
            .field("kind", .string, .required)
            .field("xp", .int, .required)
            .field("at", .datetime, .required)
            .field("reps", .int, .required)
            .field("ref_id", .string)
            .field("note", .string)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ActivityRecordModel.schema).delete()
    }
}

/// The ledger for one user, plus helpers to append to it.
struct RewardsLedger {
    let user: UserModel
    let db: Database
    let engine: RewardEngine

    func history() async throws -> [ActivityRecord] {
        try await ActivityRecordModel.query(on: db).filter(\.$user.$id == user.requireID()).all().compactMap(\.record)
    }

    func append(_ records: [ActivityRecord]) async throws {
        let userID = try user.requireID()
        for record in records { try await ActivityRecordModel(userID: userID, record: record).create(on: db) }
    }

    func summary(now: Date = Date()) async throws -> RewardsSummary {
        engine.summary(now: now, history: try await history())
    }
}

extension Request {
    func ledger(for user: UserModel) -> RewardsLedger {
        RewardsLedger(user: user, db: db, engine: laile.rewardEngine(timeZone: user.timeZone))
    }
}

struct RewardsFeature: LaileFeature {
    let name = "rewards"
    var migrations: [any Migration] { [CreateActivityRecords()] }

    func boot(_ app: Application) async throws {
        let rewards = app.protected.grouped("rewards")
        rewards.get("summary") { req async throws -> RewardsSummary in
            try await req.ledger(for: req.user).summary()
        }
        rewards.post("check-in") { req async throws -> API.CheckInResponse in
            let ledger = req.ledger(for: try req.user)
            let now = Date()
            let history = try await ledger.history()
            let outcome = ledger.engine.checkIn(now: now, history: history)
            try await ledger.append(outcome.records)
            return API.CheckInResponse(outcome: outcome, summary: ledger.engine.summary(now: now, history: history + outcome.records))
        }
    }
}
