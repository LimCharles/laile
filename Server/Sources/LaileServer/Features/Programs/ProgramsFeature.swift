import Fluent
import LaileCore
import Vapor

/// Every program version is its own row; signing a new version archives the previous one.
final class ProgramModel: Model, @unchecked Sendable {
    static let schema = "programs"

    @ID(key: .id) var id: UUID?
    @Parent(key: "patient_id") var patient: PatientProfileModel
    @Field(key: "status") var status: String
    @Field(key: "version") var version: Int
    @Field(key: "payload") var program: Program
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(patientID: UUID, program: Program) {
        self.id = program.id
        self.$patient.id = patientID
        self.status = program.status.rawValue
        self.version = program.version
        self.program = program
    }

    func update(_ program: Program) {
        self.program = program
        self.status = program.status.rawValue
        self.version = program.version
    }

    static func activeSigned(for patientID: UUID, on db: Database) async throws -> ProgramModel? {
        try await query(on: db).filter(\.$patient.$id == patientID).filter(\.$status == ProgramStatus.signed.rawValue)
            .sort(\.$version, .descending).first()
    }

    static func all(for patientID: UUID, on db: Database) async throws -> [ProgramModel] {
        try await query(on: db).filter(\.$patient.$id == patientID).sort(\.$version, .descending).all()
    }
}

struct CreatePrograms: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(ProgramModel.schema)
            .id()
            .field("patient_id", .uuid, .required, .references(PatientProfileModel.schema, "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("version", .int, .required)
            .field("payload", .json, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(ProgramModel.schema).delete()
    }
}

/// Drafts programs with the LLM, falling back to the rule-based template. Either way the
/// output is sanitised by `ContraindicationChecker` and saved as an unsigned draft.
struct ProgramDraftService {
    let llm: any LLMProvider
    let library: ExerciseLibrary
    let logger: Logger

    func draft(for profile: PatientProfileModel, latestKneeFlexion: Double?) async throws -> Program {
        var context = profile.context
        context.latestKneeFlexion = latestKneeFlexion
        let patientID = try profile.requireID()

        if llm.isLive {
            do {
                let messages = Prompts.programDraft(context: context, library: library)
                let reply = try await llm.complete(messages: messages, tools: [], temperature: 0.2)
                let json = Prompts.extractJSON(reply.content ?? "")
                let response = try LaileJSON.decoder().decode(ProgramDraftResponse.self, from: Data(json.utf8))
                var program = response.toProgram(context: context, patientId: patientID, draftedBy: llm.name, library: library)
                program.painStopSetAbove = profile.painStopSetAbove
                if !program.items.isEmpty { return program }
                logger.warning("LLM draft had no usable items; using template")
            } catch {
                logger.warning("LLM program draft failed (\(error)); using rule-based template")
            }
        }
        var program = TemplateDrafter.draft(context: context, patientId: patientID, library: library)
        program.painStopSetAbove = profile.painStopSetAbove
        return program
    }
}

struct ProgramsFeature: LaileFeature {
    let name = "programs"
    var migrations: [any Migration] { [CreatePrograms()] }

    func boot(_ app: Application) async throws {
        // Patients read their signed program via /v1/today; clinicians manage programs in the portal.
        app.protected.get("programs", "active") { req async throws -> Program in
            guard let profile = try await req.user.patientProfile(on: req.db),
                  let model = try await ProgramModel.activeSigned(for: profile.requireID(), on: req.db) else {
                throw Abort(.notFound, reason: "No signed program yet.")
            }
            return model.program
        }
        app.get("v1", "exercises") { req -> [ExerciseSpec] in req.laile.library.all }
    }
}
