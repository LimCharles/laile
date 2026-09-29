import Fluent
import LaileCore
import Vapor

/// Lele's memory: what was sore or felt wrong, what was eased because of it, and notes from the
/// clinician. Kept here (not in the model provider) so the patient, the clinician and every
/// session read the same record.
final class CareNoteModel: Model, @unchecked Sendable {
    static let schema = "care_notes"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "status") var status: String
    @OptionalField(key: "exercise_id") var exerciseId: String?
    @Field(key: "updated_at") var updatedAt: Date
    @Field(key: "payload") var note: CareNote

    init() {}

    init(userID: UUID, note: CareNote) {
        self.id = note.id
        self.$user.id = userID
        apply(note)
    }

    func apply(_ note: CareNote) {
        status = note.status.rawValue
        exerciseId = note.exerciseId
        updatedAt = note.updatedAt
        self.note = note
    }
}

struct CreateCareNotes: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(CareNoteModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("status", .string, .required)
            .field("exercise_id", .string)
            .field("updated_at", .datetime, .required)
            .field("payload", .json, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(CareNoteModel.schema).delete()
    }
}

struct CareNoteStore {
    let db: Database

    /// Active notes first, then the most recently changed.
    func all(for userID: UUID) async throws -> [CareNote] {
        try await CareNoteModel.query(on: db).filter(\.$user.$id == userID).sort(\.$updatedAt, .descending).all()
            .map(\.note).sorted { ($0.isActive ? 0 : 1) < ($1.isActive ? 0 : 1) }
    }

    func active(for userID: UUID) async throws -> [CareNote] {
        try await CareNoteModel.query(on: db).filter(\.$user.$id == userID).filter(\.$status == CareNote.Status.active.rawValue)
            .sort(\.$updatedAt, .descending).all().map(\.note)
    }

    func save(_ note: CareNote, userID: UUID) async throws {
        if let existing = try await CareNoteModel.find(note.id, on: db) {
            existing.apply(note)
            try await existing.save(on: db)
        } else {
            try await CareNoteModel(userID: userID, note: note).create(on: db)
        }
    }

    /// Applies a finished session to Lele's notes. Returns the notes with something new to say
    /// about this session (new sore spots, exercises eased back), for the result screen.
    func record(after summary: SessionSummary, userID: UUID) async throws -> [CareNote] {
        let changed = CareMemory.update(try await active(for: userID), after: summary)
        for note in changed { try await save(note, userID: userID) }
        return changed.filter { ($0.events.last?.date ?? .distantPast) >= summary.startedAt }
    }

    func note(_ id: UUID) async throws -> CareNoteModel? {
        try await CareNoteModel.find(id, on: db)
    }
}

struct CareNotesFeature: LaileFeature {
    let name = "care-notes"
    var migrations: [any Migration] { [CreateCareNotes()] }

    func boot(_ app: Application) async throws {
        // Patient app.
        let api = app.protected.grouped("care-notes")
        api.get { req async throws -> [CareNote] in
            try await CareNoteStore(db: req.db).all(for: req.user.requireID())
        }
        api.post(":noteID", "better") { req async throws -> CareNote in
            let userID = try req.user.requireID()
            guard let id = req.parameters.get("noteID", as: UUID.self), let model = try await CareNoteStore(db: req.db).note(id),
                  model.$user.id == userID else { throw Abort(.notFound) }
            guard let better = CareMemory.markBetter(model.note, at: Date()) else {
                throw Abort(.conflict, reason: "Your clinician asked to keep this one as it is. Let them know it feels better.")
            }
            model.apply(better)
            try await model.save(on: req.db)
            return better
        }

        // Clinician portal.
        let portal = app.grouped("portal").grouped(UserModel.sessionAuthenticator()).grouped(ClinicianOnlyMiddleware())
        portal.post("patients", ":patientID", "care-notes", use: addClinicianNote)
        portal.post("care-notes", ":noteID", "keep", use: toggleKeep)
        portal.post("care-notes", ":noteID", "resolve", use: resolve)
    }

    struct NoteForm: Content { var text: String }

    func addClinicianNote(req: Request) async throws -> Response {
        let clinician = try req.user
        guard let patientID = req.parameters.get("patientID", as: UUID.self),
              let profile = try await PatientProfileModel.find(patientID, on: req.db),
              profile.$clinician.id == clinician.id else { throw Abort(.notFound) }
        let text = try req.content.decode(NoteForm.self).text.trimmingCharacters(in: .whitespacesAndNewlines)
        if let userID = profile.$user.id, !text.isEmpty {
            let now = Date()
            let note = CareNote(createdAt: now, kind: .clinicianNote, source: .clinician, text: String(text.prefix(500)),
                                author: clinician.displayName, events: [.init(date: now, text: "Written by \(clinician.displayName).")])
            try await CareNoteStore(db: req.db).save(note, userID: userID)
        }
        return req.redirect(to: "/portal/patients/\(patientID)")
    }

    func toggleKeep(req: Request) async throws -> Response {
        let (model, profile) = try await ownedNote(req)
        var note = model.note
        if var adjustment = note.adjustment, note.isActive {
            adjustment.keptByClinician.toggle()
            note.adjustment = adjustment
            note.updatedAt = Date()
            note.events.append(.init(date: note.updatedAt, text: adjustment.keptByClinician
                ? "\(try req.user.displayName) asked to keep this easier until they change it."
                : "\(try req.user.displayName) let Lele ease it back after comfortable sessions."))
            model.apply(note)
            try await model.save(on: req.db)
        }
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    func resolve(req: Request) async throws -> Response {
        let (model, profile) = try await ownedNote(req)
        var note = model.note
        if note.isActive {
            note.status = .resolved
            note.adjustment = nil
            note.updatedAt = Date()
            note.events.append(.init(date: note.updatedAt, text: "Closed by \(try req.user.displayName)."))
            model.apply(note)
            try await model.save(on: req.db)
        }
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    /// The note, and the patient record it belongs to, if the patient is this clinician's.
    func ownedNote(_ req: Request) async throws -> (CareNoteModel, PatientProfileModel) {
        guard let id = req.parameters.get("noteID", as: UUID.self), let model = try await CareNoteStore(db: req.db).note(id),
              let profile = try await PatientProfileModel.query(on: req.db).filter(\.$user.$id == model.$user.id).first(),
              profile.$clinician.id == (try req.user.id) else { throw Abort(.notFound) }
        return (model, profile)
    }
}
