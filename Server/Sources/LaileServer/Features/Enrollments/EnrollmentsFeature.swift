import Fluent
import LaileCore
import Vapor

/// A person in a program. Clinical enrollments point at the patient record, so the program they
/// run is always the clinician's current signed version; catalog and personal ones carry theirs.
final class EnrollmentModel: Model, @unchecked Sendable {
    static let schema = "enrollments"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "kind") var kind: String
    @Field(key: "status") var status: String
    @Field(key: "title") var title: String
    @Field(key: "subtitle") var subtitle: String
    @OptionalField(key: "catalog_id") var catalogId: String?
    @OptionalParent(key: "patient_profile_id") var patientProfile: PatientProfileModel?
    @OptionalField(key: "program") var program: Program?
    @Field(key: "joined_at") var joinedAt: Date
    @OptionalField(key: "completed_at") var completedAt: Date?
    @OptionalField(key: "completion_note") var completionNote: String?
    @OptionalField(key: "follow_on") var followOn: String?
    @OptionalField(key: "calibration") var calibration: Calibration?

    init() {}

    init(userID: UUID, kind: Enrollment.Kind, title: String, subtitle: String, catalogId: String? = nil,
         patientProfileID: UUID? = nil, program: Program? = nil, joinedAt: Date = Date()) {
        self.$user.id = userID
        self.kind = kind.rawValue
        self.status = Enrollment.Status.active.rawValue
        self.title = title
        self.subtitle = subtitle
        self.catalogId = catalogId
        self.$patientProfile.id = patientProfileID
        self.program = program
        self.joinedAt = joinedAt
    }

    var isActive: Bool { status == Enrollment.Status.active.rawValue }
}

final class HealthProfileModel: Model, @unchecked Sendable {
    static let schema = "health_profiles"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "payload") var profile: HealthProfile

    init() {}

    init(userID: UUID, profile: HealthProfile) {
        self.$user.id = userID
        self.profile = profile
    }
}

struct CreateEnrollments: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(EnrollmentModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("kind", .string, .required)
            .field("status", .string, .required)
            .field("title", .string, .required)
            .field("subtitle", .string, .required)
            .field("catalog_id", .string)
            .field("patient_profile_id", .uuid, .references(PatientProfileModel.schema, "id", onDelete: .setNull))
            .field("program", .json)
            .field("joined_at", .datetime, .required)
            .field("completed_at", .datetime)
            .field("completion_note", .string)
            .field("follow_on", .string)
            .field("calibration", .json)
            .create()
        try await database.schema(HealthProfileModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("payload", .json, .required)
            .unique(on: "user_id")
            .create()
        // Patient records gain a lifecycle: next appointment and discharge (SQLite adds one column at a time).
        try await database.schema(PatientProfileModel.schema).field("next_visit_at", .datetime).update()
        try await database.schema(PatientProfileModel.schema).field("discharged_at", .datetime).update()
        try await database.schema(PatientProfileModel.schema).field("discharge_note", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(HealthProfileModel.schema).delete()
        try await database.schema(EnrollmentModel.schema).delete()
    }
}

struct EnrollmentStore {
    let db: Database

    func models(for userID: UUID) async throws -> [EnrollmentModel] {
        try await EnrollmentModel.query(on: db).filter(\.$user.$id == userID).sort(\.$joinedAt, .descending).all()
    }

    /// Active first (supervised before self-guided), then finished ones.
    func all(for userID: UUID) async throws -> [Enrollment] {
        var result: [Enrollment] = []
        for model in try await models(for: userID) { result.append(try await resolve(model)) }
        return result.sorted { a, b in
            if a.isActive != b.isActive { return a.isActive }
            if a.isSupervised != b.isSupervised { return a.isSupervised }
            return a.joinedAt > b.joinedAt
        }
    }

    func active(for userID: UUID) async throws -> [Enrollment] { try await all(for: userID).filter(\.isActive) }

    func resolve(_ model: EnrollmentModel) async throws -> Enrollment {
        let kind = Enrollment.Kind(rawValue: model.kind) ?? .catalog
        var program = model.program ?? Program(title: model.title, items: [], precautions: .none, draftedBy: "")
        var supervisor: String?
        var title = model.title
        if kind == .clinical, let profileID = model.$patientProfile.id,
           let profile = try await PatientProfileModel.query(on: db).filter(\.$id == profileID).with(\.$clinician).first() {
            supervisor = profile.clinician.displayName
            if let signed = try await ProgramModel.activeSigned(for: profileID, on: db)?.program {
                program = signed
                title = signed.title
            } else {
                program = Program(title: "Waiting for \(profile.clinician.displayName)", items: [], precautions: profile.precautions, draftedBy: "")
                title = "Program from \(profile.clinician.displayName)"
            }
        }
        return Enrollment(id: try model.requireID(), kind: kind, status: Enrollment.Status(rawValue: model.status) ?? .active,
                          title: title, subtitle: model.subtitle, program: program, catalogId: model.catalogId,
                          supervisorName: supervisor, joinedAt: model.joinedAt, completedAt: model.completedAt,
                          completionNote: model.completionNote, followOnCatalogId: model.followOn, calibration: model.calibration)
    }

    /// Joining a physio's program with their code.
    @discardableResult
    func ensureClinical(profile: PatientProfileModel, userID: UUID, joinedAt: Date = Date()) async throws -> EnrollmentModel {
        let profileID = try profile.requireID()
        if let existing = try await EnrollmentModel.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$patientProfile.$id == profileID).filter(\.$status == Enrollment.Status.active.rawValue).first() {
            return existing
        }
        let clinicianName = try await UserModel.find(profile.$clinician.id, on: db)?.displayName ?? "your clinician"
        let model = EnrollmentModel(userID: userID, kind: .clinical, title: "Program from \(clinicianName)",
                                    subtitle: profile.procedure.label, patientProfileID: profileID, joinedAt: joinedAt)
        try await model.create(on: db)
        return model
    }

    func joinCatalog(_ template: SessionTemplate, userID: UUID, joinedAt: Date = Date()) async throws -> EnrollmentModel {
        if let existing = try await EnrollmentModel.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$catalogId == template.id).filter(\.$status == Enrollment.Status.active.rawValue).first() {
            return existing
        }
        let model = EnrollmentModel(userID: userID, kind: .catalog, title: template.title, subtitle: template.subtitle,
                                    catalogId: template.id, program: template.asProgram(), joinedAt: joinedAt)
        try await model.create(on: db)
        return model
    }

    /// A new plan from Lele replaces the previous personal one.
    func createPersonal(_ program: Program, userID: UUID) async throws -> EnrollmentModel {
        for old in try await EnrollmentModel.query(on: db).filter(\.$user.$id == userID)
            .filter(\.$kind == Enrollment.Kind.personal.rawValue).filter(\.$status == Enrollment.Status.active.rawValue).all() {
            old.status = Enrollment.Status.completed.rawValue
            old.completedAt = Date()
            try await old.save(on: db)
        }
        let model = EnrollmentModel(userID: userID, kind: .personal, title: program.title, subtitle: "Built by Lele from your goals", program: program)
        try await model.create(on: db)
        return model
    }

    func complete(_ model: EnrollmentModel, note: String?, followOn: String?, at date: Date = Date()) async throws {
        model.status = Enrollment.Status.completed.rawValue
        model.completedAt = date
        model.completionNote = note
        model.followOn = followOn
        try await model.save(on: db)
    }

    /// A finished check-in session sets the program's personal targets.
    func calibrate(from summary: SessionSummary, userID: UUID) async throws {
        guard summary.isBaseline, let id = summary.enrollmentId, let model = try await EnrollmentModel.find(id, on: db),
              model.$user.id == userID, !summary.exercises.isEmpty else { return }
        model.calibration = Calibration.from(summary)
        try await model.save(on: db)
    }
}

struct HealthStore {
    let db: Database

    func get(_ userID: UUID) async throws -> HealthProfile? {
        try await HealthProfileModel.query(on: db).filter(\.$user.$id == userID).first()?.profile
    }

    func save(_ profile: HealthProfile, userID: UUID) async throws {
        if let existing = try await HealthProfileModel.query(on: db).filter(\.$user.$id == userID).first() {
            existing.profile = profile
            try await existing.save(on: db)
        } else {
            try await HealthProfileModel(userID: userID, profile: profile).create(on: db)
        }
    }
}

struct EnrollmentsFeature: LaileFeature {
    let name = "enrollments"
    var migrations: [any Migration] { [CreateEnrollments()] }

    func boot(_ app: Application) async throws {
        let api = app.protected
        api.get("enrollments") { req async throws -> [Enrollment] in
            try await EnrollmentStore(db: req.db).all(for: req.user.requireID())
        }
        api.post("enrollments") { req async throws -> Enrollment in
            let body = try req.content.decode(API.JoinProgramRequest.self)
            guard let template = SessionTemplate.catalogPrograms.first(where: { $0.id == body.catalogId }) else { throw Abort(.notFound) }
            try await requireNotSupervised(req)
            let store = EnrollmentStore(db: req.db)
            return try await store.resolve(store.joinCatalog(template, userID: req.user.requireID()))
        }
        api.post("enrollments", ":id", "leave") { req async throws -> Enrollment in
            let store = EnrollmentStore(db: req.db)
            guard let id = req.parameters.get("id", as: UUID.self), let model = try await EnrollmentModel.find(id, on: req.db),
                  model.$user.id == (try req.user.requireID()) else { throw Abort(.notFound) }
            guard model.kind != Enrollment.Kind.clinical.rawValue else {
                throw Abort(.forbidden, reason: "Your physio ends this program when you're ready. Let them know how you're getting on.")
            }
            try await store.complete(model, note: nil, followOn: nil)
            return try await store.resolve(model)
        }
        api.put("health") { req async throws -> HealthProfile in
            var profile = try req.content.decode(HealthProfile.self)
            let userID = try req.user.requireID()
            // Carry-over limits from a clinician can't be removed by the patient.
            profile.clinicianPrecautions = try await HealthStore(db: req.db).get(userID)?.clinicianPrecautions
            profile.updatedAt = Date()
            try await HealthStore(db: req.db).save(profile, userID: userID)
            return profile
        }
        api.post("plan", use: plan)
    }

    /// While a physio supervises someone, anything added to their plan goes through the physio
    /// (the app offers to ask them via Lele instead).
    func requireNotSupervised(_ req: Request) async throws {
        if let profile = try await LeleService(app: req.application, db: req.db, logger: req.logger).activePatientProfile(for: req.user.requireID()) {
            throw Abort(.forbidden, reason: "You're in \(CallName.plain(profile.clinician.displayName))'s program. Tap Ask on the program and Lele will send them your request.")
        }
    }

    /// The goals conversation's result: Lele builds a personal program and explains it.
    func plan(req: Request) async throws -> API.PlanResponse {
        try await requireNotSupervised(req)
        let profile = try req.content.decode(API.PlanRequest.self).profile
        let outcome = try await LelePlanService(app: req.application, db: req.db, logger: req.logger).build(profile, user: req.user)
        guard case .enrolled(let enrollment, let messages) = outcome else { throw Abort(.conflict) }
        return API.PlanResponse(enrollment: enrollment, messages: messages)
    }
}

/// Lele's planner: the model drafts from the person's goals when available, the rule-based drafter
/// otherwise; both pass the same contraindication check.
struct LelePlanner {
    let llm: any LLMProvider
    let logger: Logger

    func plan(for profile: HealthProfile, name: String) async throws -> PersonalProgramDrafter.Draft {
        let fallback = PersonalProgramDrafter.draft(profile)
        guard llm.isLive else { return fallback }
        do {
            let reply = try await llm.complete(messages: Prompts.personalPlan(profile: profile, library: .standard), tools: [], temperature: 0.3)
            let json = Prompts.extractJSON(reply.content ?? "")
            let response = try LaileJSON.decoder().decode(ProgramDraftResponse.self, from: Data(json.utf8))
            let context = PatientContext(displayName: name, procedure: .other, precautions: profile.precautions, goals: profile.goals.map(\.label))
            var program = response.toProgram(context: context, patientId: nil, draftedBy: "Lele", library: .standard)
            guard program.items.count >= 2 else { return fallback }
            program.status = .signed
            return PersonalProgramDrafter.Draft(program: program, reasons: program.items.map(\.rationale).filter { !$0.isEmpty })
        } catch {
            logger.warning("Lele plan via model failed (\(error)); using rule-based plan")
            return fallback
        }
    }
}
