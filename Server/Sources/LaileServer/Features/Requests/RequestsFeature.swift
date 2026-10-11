import Fluent
import LaileCore
import Vapor

/// A supervised person asking their physio to add a catalog program, or to approve a plan Lele
/// drafted from their new goals (`program` holds the draft, `catalogId` is `ProgramRequest.lelePlanId`).
final class ProgramRequestModel: Model, @unchecked Sendable {
    static let schema = "program_requests"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Parent(key: "patient_profile_id") var patientProfile: PatientProfileModel
    @Field(key: "catalog_id") var catalogId: String
    @Field(key: "title") var title: String
    @Field(key: "status") var status: String
    @OptionalField(key: "note") var note: String?
    @Field(key: "created_at") var createdAt: Date
    @OptionalField(key: "decided_at") var decidedAt: Date?
    @OptionalField(key: "program") var programJSON: String?

    init() {}

    init(userID: UUID, profileID: UUID, draft program: Program, at: Date) {
        self.$user.id = userID
        self.$patientProfile.id = profileID
        self.catalogId = ProgramRequest.lelePlanId
        self.title = program.title
        self.status = ProgramRequest.Status.pending.rawValue
        self.createdAt = at
        self.programJSON = (try? LaileJSON.encoder().encode(program)).flatMap { String(data: $0, encoding: .utf8) }
    }

    var draftProgram: Program? {
        programJSON.flatMap { try? LaileJSON.decoder().decode(Program.self, from: Data($0.utf8)) }
    }

    init(userID: UUID, profileID: UUID, template: SessionTemplate, at: Date) {
        self.$user.id = userID
        self.$patientProfile.id = profileID
        self.catalogId = template.id
        self.title = template.title
        self.status = ProgramRequest.Status.pending.rawValue
        self.createdAt = at
    }

    var request: ProgramRequest {
        ProgramRequest(id: id ?? UUID(), catalogId: catalogId, title: title, status: ProgramRequest.Status(rawValue: status) ?? .pending,
                       note: note, createdAt: createdAt, decidedAt: decidedAt)
    }
}

struct CreateProgramRequests: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ProgramRequestModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("patient_profile_id", .uuid, .required, .references(PatientProfileModel.schema, "id", onDelete: .cascade))
            .field("catalog_id", .string, .required)
            .field("title", .string, .required)
            .field("status", .string, .required)
            .field("note", .string)
            .field("created_at", .datetime, .required)
            .field("decided_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ProgramRequestModel.schema).delete()
    }
}

struct AddDraftProgramToRequests: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ProgramRequestModel.schema).field("program", .string).update()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ProgramRequestModel.schema).deleteField("program").update()
    }
}

struct RequestStore {
    let db: Database

    /// The person's requests, newest first.
    func all(for userID: UUID) async throws -> [ProgramRequest] {
        try await ProgramRequestModel.query(on: db).filter(\.$user.$id == userID).sort(\.$createdAt, .descending).limit(20).all().map(\.request)
    }

    func pending(forProfile profileID: UUID) async throws -> [ProgramRequest] {
        try await ProgramRequestModel.query(on: db).filter(\.$patientProfile.$id == profileID)
            .filter(\.$status == ProgramRequest.Status.pending.rawValue).all().map(\.request)
    }

    /// Asks the physio. Returns what Lele tells the person.
    func ask(_ template: SessionTemplate, user: UserModel, profile: PatientProfileModel, now: Date = Date()) async throws -> LeleMessage {
        let userID = try user.requireID()
        let physio = CallName.plain(profile.clinician.displayName)
        if try await ProgramRequestModel.query(on: db).filter(\.$user.$id == userID).filter(\.$catalogId == template.id)
            .filter(\.$status == ProgramRequest.Status.pending.rawValue).first() != nil {
            return LeleMessage(createdAt: now, kind: .chat, text: "I've already asked \(physio) about \(template.title). I'll tell you as soon as they answer.")
        }
        try await ProgramRequestModel(userID: userID, profileID: profile.requireID(), template: template, at: now).create(on: db)
        return LeleMessage(createdAt: now, kind: .chat,
                           text: "I've asked \(physio) whether you can add \(template.title) alongside your program. I'll tell you as soon as they answer.")
    }
}

struct RequestsFeature: LaileFeature {
    let name = "requests"
    var migrations: [any Migration] { [CreateProgramRequests(), AddDraftProgramToRequests()] }

    func boot(_ app: Application) async throws {
        app.protected.post("requests") { req async throws -> API.LeleTurnResponse in
            let body = try req.content.decode(API.JoinProgramRequest.self)
            guard let template = SessionTemplate.catalogPrograms.first(where: { $0.id == body.catalogId }) else { throw Abort(.notFound) }
            let user = try req.user
            let service = LeleService(app: req.application, db: req.db, logger: req.logger)
            guard let profile = try await service.activePatientProfile(for: user.requireID()) else {
                throw Abort(.badRequest, reason: "You can join this one yourself from Programs.")
            }
            let message = try await RequestStore(db: req.db).ask(template, user: user, profile: profile)
            try await service.save(message, userID: user.requireID())
            return API.LeleTurnResponse(messages: [message], careNotes: [])
        }

        let clinician = app.grouped("portal").grouped(UserModel.sessionAuthenticator()).grouped(ClinicianOnlyMiddleware())
        clinician.post("requests", ":requestID", "approve") { req async throws -> Response in
            try await decide(req, approve: true)
        }
        clinician.post("requests", ":requestID", "decline") { req async throws -> Response in
            try await decide(req, approve: false)
        }
    }

    struct DecisionForm: Content {
        var note: String?
        var back: String?
    }

    /// The physio's answer. Approving joins the program for them (their limits still apply);
    /// either way Lele tells the person.
    func decide(_ req: Request, approve: Bool) async throws -> Response {
        let clinician = try req.user
        guard let id = req.parameters.get("requestID", as: UUID.self),
              let model = try await ProgramRequestModel.query(on: req.db).filter(\.$id == id).with(\.$patientProfile).first(),
              model.patientProfile.$clinician.id == (try clinician.requireID()) else { throw Abort(.notFound) }
        let form = try req.content.decode(DecisionForm.self)
        let back = form.back.flatMap { $0.hasPrefix("/portal") && !$0.contains("//") ? $0 : nil } ?? "/portal"
        guard model.status == ProgramRequest.Status.pending.rawValue else { return req.redirect(to: back) }

        let now = Date()
        let note = form.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        model.status = (approve ? ProgramRequest.Status.approved : .declined).rawValue
        model.note = note
        model.decidedAt = now
        try await model.save(on: req.db)

        let userID = model.$user.id
        let physio = CallName.plain(clinician.displayName)
        var message: LeleMessage
        if approve, var program = model.draftProgram {
            // A plan Lele drafted from new goals: it starts as the physio's approved plan.
            program.signedBy = clinician.displayName
            program.signedAt = now
            let store = EnrollmentStore(db: req.db)
            let created = try await store.createPersonal(program, userID: userID)
            created.subtitle = "Built by Lele, approved by \(physio)"
            try await created.save(on: req.db)
            var text = "Good news: \(physio) approved the plan I drafted from your new goals, \(program.title)."
            if let note { text += " Their note: \"\(note)\"" }
            text += " It runs alongside your program with them, inside their limits. The first session is a quick check-in."
            message = LeleMessage(createdAt: now, kind: .clinician, text: text,
                                  actions: [LeleAction(id: "start", label: "Start check-in", kind: .startSession, value: try created.requireID().uuidString)])
        } else if approve, let template = SessionTemplate.builtIn(model.catalogId) {
            let store = EnrollmentStore(db: req.db)
            let enrollment = try await store.joinCatalog(template, userID: userID, joinedAt: now)
            var text = "Good news: \(physio) says yes to \(template.title)."
            if let note { text += " Their note: \"\(note)\"" }
            text += " Your limits from them carry over to it. The first session is a quick check-in."
            message = LeleMessage(createdAt: now, kind: .clinician, text: text,
                                  actions: [LeleAction(id: "start", label: "Start check-in", kind: .startSession, value: try enrollment.requireID().uuidString)])
        } else {
            var text = "\(physio) would rather you hold off on \(model.title) for now."
            if let note { text += " Their note: \"\(note)\"" }
            text += " Keep going with your program with them for now."
            message = LeleMessage(createdAt: now, kind: .clinician, text: text)
        }
        try await LeleService(app: req.application, db: req.db, logger: req.logger).save(message, userID: userID)
        return req.redirect(to: back)
    }
}
