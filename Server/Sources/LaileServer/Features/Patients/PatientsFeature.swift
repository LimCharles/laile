import Fluent
import LaileCore
import Vapor

/// A patient record owned by a clinician. It exists before the patient installs the app;
/// the patient claims it with the invite code (and consents to share their data).
final class PatientProfileModel: Model, @unchecked Sendable {
    static let schema = "patient_profiles"

    @ID(key: .id) var id: UUID?
    @Parent(key: "clinician_id") var clinician: UserModel
    @OptionalParent(key: "user_id") var user: UserModel?
    @Field(key: "display_name") var displayName: String
    @OptionalField(key: "age") var age: Int?
    @Field(key: "procedure") var procedureRaw: String
    @OptionalField(key: "procedure_date") var procedureDate: Date?
    @Field(key: "precautions") var precautions: Precautions
    @Field(key: "pain_stop_above") var painStopSetAbove: Int
    @Field(key: "comorbidities") var comorbidities: [String]
    @Field(key: "goals") var goals: [String]
    @Field(key: "clinical_notes") var clinicalNotes: String
    @Field(key: "medications") var medications: [Medication]
    @Field(key: "invite_code") var inviteCode: String
    @OptionalField(key: "consented_at") var consentedAt: Date?
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(clinicianID: UUID, displayName: String, age: Int?, procedure: Procedure, procedureDate: Date?, precautions: Precautions,
         painStopSetAbove: Int, comorbidities: [String], goals: [String], clinicalNotes: String, medications: [Medication]) {
        self.$clinician.id = clinicianID
        self.displayName = displayName
        self.age = age
        self.procedureRaw = procedure.rawValue
        self.procedureDate = procedureDate
        self.precautions = precautions
        self.painStopSetAbove = painStopSetAbove
        self.comorbidities = comorbidities
        self.goals = goals
        self.clinicalNotes = clinicalNotes
        self.medications = medications
        self.inviteCode = Self.makeInviteCode()
    }

    var procedure: Procedure { Procedure(rawValue: procedureRaw) ?? .other }

    var context: PatientContext {
        PatientContext(displayName: displayName, age: age, procedure: procedure, procedureDate: procedureDate,
                       precautions: precautions, comorbidities: comorbidities, goals: goals, clinicalNotes: clinicalNotes)
    }

    static func makeInviteCode() -> String {
        let alphabet = Array("ABCDEFGHJKLMNPQRSTUVWXYZ23456789")
        let body = (0..<6).map { _ in String(alphabet.randomElement()!) }.joined()
        return "LAI-" + body
    }
}

final class MedicationLogModel: Model, @unchecked Sendable {
    static let schema = "medication_logs"

    @ID(key: .id) var id: UUID?
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "medication_id") var medicationId: UUID
    @Field(key: "day") var day: String
    @Field(key: "scheduled") var scheduled: TimeOfDay
    @Field(key: "taken_at") var takenAt: Date

    init() {}

    init(userID: UUID, entry: MedicationLogEntry) {
        self.id = entry.id
        self.$user.id = userID
        self.medicationId = entry.medicationId
        self.day = entry.day.description
        self.scheduled = entry.scheduled
        self.takenAt = entry.takenAt
    }

    var entry: MedicationLogEntry? {
        DayKey(day).map { MedicationLogEntry(id: id ?? UUID(), medicationId: medicationId, day: $0, scheduled: scheduled, takenAt: takenAt) }
    }
}

struct CreatePatientProfiles: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(PatientProfileModel.schema)
            .id()
            .field("clinician_id", .uuid, .required, .references(UserModel.schema, "id"))
            .field("user_id", .uuid, .references(UserModel.schema, "id", onDelete: .setNull))
            .field("display_name", .string, .required)
            .field("age", .int)
            .field("procedure", .string, .required)
            .field("procedure_date", .datetime)
            .field("precautions", .json, .required)
            .field("pain_stop_above", .int, .required)
            .field("comorbidities", .json, .required)
            .field("goals", .json, .required)
            .field("clinical_notes", .string, .required)
            .field("medications", .json, .required)
            .field("invite_code", .string, .required)
            .field("consented_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "invite_code")
            .create()
        try await database.schema(MedicationLogModel.schema)
            .id()
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("medication_id", .uuid, .required)
            .field("day", .string, .required)
            .field("scheduled", .json, .required)
            .field("taken_at", .datetime, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(MedicationLogModel.schema).delete()
        try await database.schema(PatientProfileModel.schema).delete()
    }
}

extension UserModel {
    func patientProfile(on db: Database) async throws -> PatientProfileModel? {
        try await PatientProfileModel.query(on: db).filter(\.$user.$id == requireID()).with(\.$clinician).first()
    }

    func profileWithClinician(on db: Database) async throws -> API.UserProfile {
        let clinician = try await patientProfile(on: db)?.clinician.displayName
        return try profile(clinicianName: clinician)
    }
}

struct PatientsFeature: LaileFeature {
    let name = "patients"
    var migrations: [any Migration] { [CreatePatientProfiles()] }

    func boot(_ app: Application) async throws {
        let api = app.protected
        api.post("patients", "link", use: link)
        api.get("today", use: today)
        api.post("medications", "taken", use: medicationTaken)
    }

    /// Patient claims a clinician-created record with its invite code.
    func link(req: Request) async throws -> API.UserProfile {
        let user = try req.user
        let body = try req.content.decode(API.LinkClinicianRequest.self)
        let code = InviteCode.normalize(body.inviteCode)
        if code == DemoSeed.inviteCode, req.laile.config.seedDemoData {
            let profile = try await req.db.transaction { db in try await DemoWorld(app: req.application, db: db).linkWithDemoCode(user: user) }
            user.role = .patient
            user.mode = .rehab
            try await user.save(on: req.db)
            return try user.profile(clinicianName: profile.clinician.displayName)
        }
        guard let profile = try await PatientProfileModel.query(on: req.db).filter(\.$inviteCode == code).with(\.$clinician).first() else {
            throw Abort(.notFound, reason: "That invite code wasn't found. Check it with your clinician.")
        }
        if let existing = profile.$user.id, existing != (try user.requireID()) {
            throw Abort(.conflict, reason: "That invite code has already been used.")
        }
        profile.$user.id = try user.requireID()
        profile.consentedAt = Date()
        try await profile.save(on: req.db)
        user.role = .patient
        user.mode = .rehab
        try await user.save(on: req.db)
        return try user.profile(clinicianName: profile.clinician.displayName)
    }

    func today(req: Request) async throws -> API.TodayPlan {
        let user = try req.user
        let templates = SessionTemplate.builtIn.filter { $0.mode == .move || user.mode == .rehab }
        guard user.mode == .rehab, let profile = try await user.patientProfile(on: req.db) else {
            return API.TodayPlan(mode: .move, program: nil, clinicianName: nil, templates: templates, medicationDoses: [])
        }
        let program = try await ProgramModel.activeSigned(for: profile.requireID(), on: req.db)?.program
        let timeZone = TimeZone(identifier: user.timeZone) ?? .current
        let day = DayKey(Date(), timeZone: timeZone)
        let log = try await MedicationLogModel.query(on: req.db).filter(\.$user.$id == user.requireID())
            .filter(\.$day == day.description).all().compactMap(\.entry)
        return API.TodayPlan(mode: .rehab, program: program, clinicianName: profile.clinician.displayName, templates: templates,
                             medicationDoses: MedicationSchedule.doses(for: profile.medications, on: day, log: log))
    }

    func medicationTaken(req: Request) async throws -> HTTPStatus {
        let user = try req.user
        let body = try req.content.decode(API.MedicationTakenRequest.self)
        let day = DayKey(Date(), timeZone: TimeZone(identifier: user.timeZone) ?? .current)
        let entry = MedicationLogEntry(medicationId: body.medicationId, day: day, scheduled: body.scheduled, takenAt: Date())
        try await MedicationLogModel(userID: user.requireID(), entry: entry).create(on: req.db)
        return .created
    }
}
