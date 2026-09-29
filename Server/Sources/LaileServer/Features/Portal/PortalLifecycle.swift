import Fluent
import LaileCore
import Vapor

/// The parts of a patient's record about where they are in their care: live now, check-in
/// results, their conversation with Lele, the next appointment, and discharge.
struct LifecycleVM: Encodable {
    struct Option: Encodable { var value: String; var label: String; var selected: Bool }
    struct MessageVM: Encodable { var when: String; var who: String; var text: String; var answer: String; var isLele: Bool }

    var linked: Bool
    var discharged: Bool
    var dischargedOn: String
    var dischargeNote: String
    var nextVisit: String
    var nextVisitInput: String
    var followOnOptions: [Option]
    var suggestedFollowOn: String
    var calibration: [String]
    var calibratedOn: String
    var otherPrograms: [String]
    var conversation: [MessageVM]

    static func load(_ profile: PatientProfileModel, on db: Database) async throws -> LifecycleVM {
        let suggested = FollowOn.catalogId(for: profile.procedure)
        var calibration: [String] = []
        var calibratedOn = ""
        var others: [String] = []
        var conversation: [MessageVM] = []
        if let userID = profile.$user.id {
            let enrollments = try await EnrollmentStore(db: db).all(for: userID)
            if let clinical = enrollments.first(where: { $0.isSupervised }), let c = clinical.calibration {
                calibration = c.exercises.map(\.summary)
                calibratedOn = Formatters.dateTime(c.measuredAt)
            }
            others = enrollments.filter { !$0.isSupervised && $0.isActive }.map { "\($0.title) (\($0.kind == .personal ? "built by Lele" : "Laile catalog"))" }
            let messages = try await LeleMessageModel.query(on: db).filter(\.$user.$id == userID).sort(\.$createdAt, .descending).limit(12).all().map(\.message)
            conversation = messages.map { m in
                MessageVM(when: Formatters.dateTime(m.createdAt), who: m.author == .person ? "Patient" : (m.author == .clinician ? "Clinician" : "Lele"),
                          text: m.text, answer: m.answer ?? "", isLele: m.author == .lele)
            }
        }
        let local = DateFormatter()
        local.dateFormat = "yyyy-MM-dd'T'HH:mm"
        local.timeZone = Formatters.zone
        return LifecycleVM(
            linked: profile.$user.id != nil, discharged: profile.dischargedAt != nil,
            dischargedOn: profile.dischargedAt.map(Formatters.dateTime) ?? "", dischargeNote: profile.dischargeNote ?? "",
            nextVisit: profile.nextVisitAt.map(Formatters.dateTime) ?? "", nextVisitInput: profile.nextVisitAt.map(local.string) ?? "",
            followOnOptions: SessionTemplate.catalogPrograms.map { Option(value: $0.id, label: "\($0.title): \($0.subtitle)", selected: $0.id == suggested) },
            suggestedFollowOn: SessionTemplate.builtIn(suggested)?.title ?? "",
            calibration: calibration, calibratedOn: calibratedOn, otherPrograms: others, conversation: conversation
        )
    }
}

extension PortalFeature {
    struct DischargeForm: Content {
        var note: String?
        var follow_on: String?
        var carry_precautions: String?
    }

    /// Only the physician ends physio. The patient keeps their history, gets a note from Lele with
    /// what's next, and (if chosen) their precautions follow them into every program.
    func discharge(req: Request) async throws -> Response {
        let profile = try await ownedPatient(req)
        let clinician = try req.user
        let form = try req.content.decode(DischargeForm.self)
        let note = form.note?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        let followOn = form.follow_on.flatMap { id in SessionTemplate.catalogPrograms.first { $0.id == id } }
        let now = Date()
        profile.dischargedAt = now
        profile.dischargeNote = note
        try await profile.save(on: req.db)

        if let userID = profile.$user.id {
            let store = EnrollmentStore(db: req.db)
            for model in try await EnrollmentModel.query(on: req.db).filter(\.$patientProfile.$id == profile.requireID())
                .filter(\.$status == Enrollment.Status.active.rawValue).all() {
                try await store.complete(model, note: note, followOn: followOn?.id, at: now)
            }
            if let user = try await UserModel.find(userID, on: req.db) {
                user.mode = .move
                try await user.save(on: req.db)
            }
            if form.carry_precautions == "on" {
                var health = try await HealthStore(db: req.db).get(userID) ?? HealthProfile()
                health.clinicianPrecautions = profile.precautions
                health.updatedAt = now
                try await HealthStore(db: req.db).save(health, userID: userID)
            }
            var text = "Great news: \(clinician.displayName) has signed off your physio program. 🎉"
            if let note { text += " Their note: \"\(note)\"" }
            if let followOn {
                text += " To keep your progress going, \(clinician.displayName) suggests \(followOn.title): \(followOn.subtitle.lowercased())."
            }
            if form.carry_precautions == "on" { text += " Your precautions still apply in every program, and I'll keep an eye on them." }
            let message = LeleMessage(createdAt: now, kind: .discharge, text: text,
                                      actions: followOn.map { [LeleAction(id: "join", label: "Join \($0.title)", kind: .joinProgram, value: $0.id)] } ?? [])
            try await LeleMessageModel(userID: userID, message: message).create(on: req.db)
        }
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    struct VisitForm: Content { var next_visit: String? }

    func setNextVisit(req: Request) async throws -> Response {
        let profile = try await ownedPatient(req)
        let form = try req.content.decode(VisitForm.self)
        profile.nextVisitAt = form.next_visit.flatMap(Formatters.parseLocalDateTime)
        try await profile.save(on: req.db)
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    struct AskLeleForm: Content { var instruction: String }

    /// The physician tells Lele what to change in plain words. Lele edits a draft (creating one from
    /// the signed version if needed); nothing reaches the patient until the physician signs it.
    func askLele(req: Request) async throws -> Response {
        let (model, profile) = try await ownedProgram(req)
        let instruction = try req.content.decode(AskLeleForm.self).instruction.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !instruction.isEmpty else { return req.redirect(to: "/portal/programs/\(model.program.id)") }
        let clinician = try req.user.displayName

        var draftModel = model
        if model.program.status != .draft {
            var revision = model.program
            revision.id = UUID()
            revision.status = .draft
            revision.signedAt = nil
            revision.signedBy = nil
            revision.blockedSuggestions = []
            revision.createdAt = Date()
            revision.version = (try await ProgramModel.all(for: profile.requireID(), on: req.db).map(\.version).max() ?? 0) + 1
            draftModel = ProgramModel(patientID: try profile.requireID(), program: revision)
            try await draftModel.create(on: req.db)
        }
        var program = draftModel.program
        var changes: [String] = []
        var usedModel = false
        if req.laile.llm.isLive {
            do {
                let messages = Prompts.programRevise(program: program, instruction: instruction, context: profile.context, library: req.laile.library)
                let reply = try await req.laile.llm.complete(messages: messages, tools: [], temperature: 0.2)
                let response = try LaileJSON.decoder().decode(ProgramDraftResponse.self, from: Data(Prompts.extractJSON(reply.content ?? "").utf8))
                let revised = response.toProgram(context: profile.context, patientId: try profile.requireID(), draftedBy: "Lele", library: req.laile.library)
                if !revised.items.isEmpty {
                    program.items = revised.items
                    program.blockedSuggestions += revised.blockedSuggestions
                    changes = [response.summary]
                    usedModel = true
                }
            } catch {
                req.logger.warning("Lele revision via model failed (\(error)); using rules")
            }
        }
        if !usedModel {
            let revision = ProgramReviser.revise(program, instruction: instruction, library: req.laile.library)
            program.items = revision.items
            changes = revision.understood ? revision.changes : ["I couldn't work out that change on my own; please edit the exercises below directly."]
            if revision.understood && revision.changes.isEmpty { changes = ["No changes were needed for that."] }
        }
        program.summary = "Lele (asked by \(clinician): \"\(instruction)\"): " + changes.joined(separator: "; ")
        program.draftedBy = "Lele, asked by \(clinician)"
        draftModel.update(program)
        try await draftModel.save(on: req.db)
        return req.redirect(to: "/portal/programs/\(program.id)")
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
