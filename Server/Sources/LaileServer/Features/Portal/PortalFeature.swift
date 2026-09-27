import Fluent
import LaileCore
import Leaf
import Vapor

/// Clinician portal: server-rendered (Leaf), session-cookie auth, clinician role only.
struct PortalFeature: LaileFeature {
    let name = "portal"

    func boot(_ app: Application) async throws {
        let web = app.grouped("portal").grouped(UserModel.sessionAuthenticator())
        web.get("login") { req in try await req.view.render("login", LoginContext(error: nil, email: "")) }
        web.post("login", use: login)
        web.post("logout") { req -> Response in
            req.auth.logout(UserModel.self)
            req.session.destroy()
            return req.redirect(to: "/portal/login")
        }

        let clinician = web.grouped(ClinicianOnlyMiddleware())
        clinician.get(use: dashboard)
        clinician.get("patients", "new") { req in try await req.view.render("patient-new", NewPatientContext.make(error: nil)) }
        clinician.post("patients", use: createPatient)
        clinician.get("patients", ":patientID", use: patientDetail)
        clinician.get("patients", ":patientID", "report", use: report)
        clinician.post("patients", ":patientID", "programs", "draft", use: draftProgram)
        clinician.get("programs", ":programID", use: editProgram)
        clinician.post("programs", ":programID", use: saveProgram)
        clinician.post("programs", ":programID", "sign", use: signProgram)
        clinician.post("programs", ":programID", "revise", use: reviseProgram)
        clinician.post("symptoms", ":symptomID", "review", use: reviewSymptom)
        clinician.get("streams", use: streams)
        clinician.post("streams", use: createStream)
    }

    // MARK: - Auth

    struct LoginContext: Encodable { var error: String?; var email: String }
    struct LoginForm: Content { var email: String; var password: String }

    func login(req: Request) async throws -> Response {
        let form = try req.content.decode(LoginForm.self)
        guard let user = try await UserModel.query(on: req.db).filter(\.$email == form.email.lowercased()).first(),
              try user.verify(password: form.password), user.role == .clinician || user.role == .admin else {
            return try await req.view.render("login", LoginContext(error: "Email or password is incorrect, or this isn't a clinician account.", email: form.email)).encodeResponse(for: req)
        }
        req.auth.login(user)
        return req.redirect(to: "/portal")
    }

    // MARK: - Dashboard

    struct PatientRow: Encodable {
        var id: String, name: String, procedure: String, dayLabel: String, linked: Bool, inviteCode: String
        var lastSession: String, adherence: String, kneeFlexion: String, flagCount: Int, programStatus: String
    }

    struct DashboardContext: Encodable {
        var clinicianName: String
        var patients: [PatientRow]
        var llmName: String
    }

    func dashboard(req: Request) async throws -> View {
        let clinician = try req.user
        let profiles = try await PatientProfileModel.query(on: req.db).filter(\.$clinician.$id == clinician.requireID())
            .sort(\.$createdAt, .descending).all()
        var rows: [PatientRow] = []
        for profile in profiles {
            let snapshot = try await PatientSnapshot.load(profile, on: req.db)
            rows.append(PatientRow(
                id: try profile.requireID().uuidString, name: profile.displayName, procedure: profile.procedure.label,
                dayLabel: profile.context.daysSinceProcedure(now: Date()).map { "Day \($0)" } ?? "—",
                linked: profile.$user.id != nil, inviteCode: profile.inviteCode,
                lastSession: snapshot.sessions.first.map { Formatters.relative($0.endedAt) } ?? "No sessions yet",
                adherence: snapshot.adherenceLabel,
                kneeFlexion: snapshot.trend(.kneeFlexion)?.latest.map { MetricKind.kneeFlexion.format($0.value) } ?? "—",
                flagCount: snapshot.flags.count,
                programStatus: snapshot.programs.first.map { "v\($0.version) \($0.status.rawValue)" } ?? "No program"
            ))
        }
        return try await req.view.render("dashboard", DashboardContext(clinicianName: clinician.displayName, patients: rows, llmName: req.laile.llm.name))
    }

    // MARK: - Create patient

    struct NewPatientContext: Encodable {
        struct Option: Encodable { var value: String; var label: String }
        var clinicianName = ""
        var error: String?
        var procedures: [Option]
        var weightBearing: [Option]
        var impacts: [Option]

        static func make(error: String?) -> NewPatientContext {
            NewPatientContext(
                error: error,
                procedures: Procedure.allCases.map { Option(value: $0.rawValue, label: $0.label) },
                weightBearing: WeightBearingStatus.allCases.map { Option(value: $0.rawValue, label: $0.label) },
                impacts: ImpactLevel.allCases.map { Option(value: "\($0.rawValue)", label: $0.label) }
            )
        }
    }

    struct NewPatientForm: Content {
        var displayName: String
        var age: String?
        var procedure: String
        var procedureDate: String?
        var affectedSide: String?
        var weightBearing: String
        var maxImpact: String
        var maxKneeFlexion: String?
        var maxHipFlexion: String?
        var painStopSetAbove: String?
        var comorbidities: String?
        var goals: String?
        var clinicalNotes: String?
        var medications: String?
    }

    func createPatient(req: Request) async throws -> Response {
        let clinician = try req.user
        let form = try req.content.decode(NewPatientForm.self)
        guard !form.displayName.trimmingCharacters(in: .whitespaces).isEmpty else {
            return try await req.view.render("patient-new", NewPatientContext.make(error: "Please enter the patient's name.")).encodeResponse(for: req)
        }
        let precautions = Precautions(
            maxKneeFlexion: form.maxKneeFlexion.flatMap(Double.init),
            maxHipFlexion: form.maxHipFlexion.flatMap(Double.init),
            weightBearing: WeightBearingStatus(rawValue: form.weightBearing) ?? .full,
            maxImpact: Int(form.maxImpact).flatMap(ImpactLevel.init(rawValue:)) ?? .low,
            affectedSide: form.affectedSide.flatMap(Side.init(rawValue:))
        )
        let profile = PatientProfileModel(
            clinicianID: try clinician.requireID(),
            displayName: form.displayName,
            age: form.age.flatMap { Int($0) },
            procedure: Procedure(rawValue: form.procedure) ?? .other,
            procedureDate: form.procedureDate.flatMap(Formatters.parseISODate),
            precautions: precautions,
            painStopSetAbove: form.painStopSetAbove.flatMap { Int($0) }.map { min(9, max(0, $0)) } ?? 4,
            comorbidities: Formatters.list(form.comorbidities),
            goals: Formatters.list(form.goals),
            clinicalNotes: form.clinicalNotes ?? "",
            medications: MedicationParser.parse(form.medications ?? "", prescribedBy: clinician.displayName)
        )
        try await profile.create(on: req.db)
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    // MARK: - Patient detail

    struct ChartVM: Encodable { var title: String; var svg: String; var latest: String; var change: String; var next: String }
    struct SymptomVM: Encodable {
        var id: String, when: String, summary: String, category: String, verbatim: String, action: String
        var severity: String, reviewed: Bool, needsReview: Bool, isRedFlag: Bool
    }
    struct ProgramRowVM: Encodable { var id: String; var title: String; var version: Int; var status: String; var draftedBy: String; var date: String }
    struct MedicationVM: Encodable { var name: String; var dose: String; var purpose: String; var times: String }
    struct SessionVM: Encodable { var when: String; var title: String; var reps: Int; var duration: String; var pain: String; var symptoms: Int }
    struct PatientContextVM: Encodable {
        var clinicianName: String
        var id: String, name: String, procedure: String, dayLabel: String, age: String, inviteCode: String, linked: Bool
        var precautions: [String], goals: String, comorbidities: String, notes: String, painStop: Int
        var charts: [ChartVM], symptoms: [SymptomVM], flags: [String], programs: [ProgramRowVM]
        var medications: [MedicationVM], sessions: [SessionVM], adherence: String
    }

    func patientDetail(req: Request) async throws -> View {
        let profile = try await ownedPatient(req)
        let snapshot = try await PatientSnapshot.load(profile, on: req.db)
        let vm = PatientContextVM(
            clinicianName: try req.user.displayName,
            id: try profile.requireID().uuidString, name: profile.displayName, procedure: profile.procedure.label,
            dayLabel: profile.context.daysSinceProcedure(now: Date()).map { "Day \($0) after procedure" } ?? "",
            age: profile.age.map { "\($0)" } ?? "—", inviteCode: profile.inviteCode, linked: profile.$user.id != nil,
            precautions: Formatters.precautions(profile.precautions),
            goals: profile.goals.joined(separator: " · "), comorbidities: profile.comorbidities.joined(separator: ", "),
            notes: profile.clinicalNotes, painStop: profile.painStopSetAbove,
            charts: snapshot.trends.map(Self.chart),
            symptoms: snapshot.symptoms.map(Self.symptomVM),
            flags: snapshot.flags,
            programs: snapshot.programs.map { ProgramRowVM(id: $0.id.uuidString, title: $0.title, version: $0.version, status: $0.status.rawValue, draftedBy: $0.draftedBy, date: SVGChart.date($0.signedAt ?? $0.createdAt)) },
            medications: profile.medications.map { MedicationVM(name: $0.name, dose: $0.doseText, purpose: $0.purpose, times: $0.times.map(\.label).joined(separator: ", ")) },
            sessions: snapshot.sessions.prefix(12).map(Self.sessionVM),
            adherence: snapshot.adherenceLabel
        )
        return try await req.view.render("patient", vm)
    }

    static func chart(_ trend: MetricTrend) -> ChartVM {
        let change = trend.improvementFromBaseline.map { delta -> String in
            let sign = delta >= 0 ? "+" : "−"
            return "\(sign)\(trend.kind.format(abs(delta))) vs baseline"
        } ?? ""
        return ChartVM(title: trend.kind.displayName, svg: SVGChart.trend(trend),
                       latest: trend.latest.map { trend.kind.format($0.value) } ?? "—", change: change,
                       next: trend.nextMilestone.map { "Next goal: \($0.title)" } ?? "")
    }

    static func symptomVM(_ model: SymptomReportModel) -> SymptomVM {
        let r = model.report
        return SymptomVM(id: model.id?.uuidString ?? "", when: Formatters.dateTime(r.timestamp), summary: r.clinicalSummary,
                         category: r.category.rawValue, verbatim: r.utterance, action: r.action?.label ?? "",
                         severity: r.severity.map { "\($0)/10" } ?? "", reviewed: model.reviewedAt != nil,
                         needsReview: r.category.needsClinicianReview && model.reviewedAt == nil, isRedFlag: r.category == .redFlag)
    }

    static func sessionVM(_ s: SessionSummary) -> SessionVM {
        SessionVM(when: Formatters.dateTime(s.startedAt), title: s.title, reps: s.verifiedReps, duration: Formatters.duration(s.durationSeconds),
                  pain: [s.painBefore.map { "before \($0)" }, s.painAfter.map { "after \($0)" }].compactMap { $0 }.joined(separator: " · "),
                  symptoms: s.symptoms.filter { $0.category.needsClinicianReview }.count)
    }

    // MARK: - Report

    struct ReportVM: Encodable {
        var name: String, procedure: String, dayLabel: String, generated: String, clinicianName: String
        var adherence: String, headline: [String], charts: [ChartVM], symptoms: [SymptomVM], flags: [String]
        var program: String, sessionsCount: Int, totalReps: Int
    }

    func report(req: Request) async throws -> View {
        let profile = try await ownedPatient(req)
        let snapshot = try await PatientSnapshot.load(profile, on: req.db)
        let recent = snapshot.sessions.filter { $0.startedAt > Date().addingTimeInterval(-14 * 86_400) }
        let headline = snapshot.trends.compactMap { t -> String? in
            guard let latest = t.latest else { return nil }
            let change = t.improvementFromBaseline.map { " (\($0 >= 0 ? "+" : "−")\(t.kind.format(abs($0))) since baseline)" } ?? ""
            return "\(t.kind.displayName): \(t.kind.format(latest.value))\(change)"
        }
        let vm = ReportVM(
            name: profile.displayName, procedure: profile.procedure.label,
            dayLabel: profile.context.daysSinceProcedure(now: Date()).map { "Day \($0)" } ?? "",
            generated: Formatters.dateTime(Date()), clinicianName: try req.user.displayName,
            adherence: snapshot.adherenceLabel, headline: headline, charts: snapshot.trends.map(Self.chart),
            symptoms: snapshot.symptoms.filter { $0.report.category.needsClinicianReview }.map(Self.symptomVM),
            flags: snapshot.flags,
            program: snapshot.programs.first(where: { $0.status == .signed }).map { "\($0.title) (v\($0.version))" } ?? "No signed program",
            sessionsCount: recent.count, totalReps: recent.reduce(0) { $0 + $1.verifiedReps }
        )
        return try await req.view.render("report", vm)
    }

    // MARK: - Programs

    func draftProgram(req: Request) async throws -> Response {
        let profile = try await ownedPatient(req)
        let latestFlexion: Double? = try await {
            guard let userID = profile.$user.id else { return nil }
            return try await MetricSampleModel.samples(for: userID, on: req.db).last { $0.kind == .kneeFlexion }?.value
        }()
        var program = try await ProgramDraftService(llm: req.laile.llm, library: req.laile.library, logger: req.logger)
            .draft(for: profile, latestKneeFlexion: latestFlexion)
        let existing = try await ProgramModel.all(for: profile.requireID(), on: req.db)
        program.version = (existing.map(\.version).max() ?? 0) + 1
        let model = ProgramModel(patientID: try profile.requireID(), program: program)
        try await model.create(on: req.db)
        return req.redirect(to: "/portal/programs/\(program.id)")
    }

    struct ItemVM: Encodable {
        var id: String, name: String, category: String, isHold: Bool, sets: Int, reps: Int, hold: Int, rest: Int, times: Int
        var target: String, tracksKnee: Bool, rationale: String, source: String, limits: String
    }
    struct Option: Encodable { var value: String; var label: String }
    struct ProgramVM: Encodable {
        var clinicianName: String
        var id: String, patientId: String, patientName: String, title: String, summary: String, draftedBy: String
        var version: Int, status: String, isDraft: Bool, signedLine: String, painStop: Int
        var items: [ItemVM], blocked: [String], violations: [String], precautions: [String], addOptions: [Option]
    }

    func editProgram(req: Request) async throws -> View {
        let (model, profile) = try await ownedProgram(req)
        let program = model.program
        let library = req.laile.library
        let vm = ProgramVM(
            clinicianName: try req.user.displayName,
            id: program.id.uuidString, patientId: try profile.requireID().uuidString, patientName: profile.displayName,
            title: program.title, summary: program.summary, draftedBy: program.draftedBy, version: program.version,
            status: program.status.rawValue, isDraft: program.status == .draft,
            signedLine: program.signedAt.map { "Signed by \(program.signedBy ?? "clinician") on \(Formatters.dateTime($0))" } ?? "",
            painStop: program.painStopSetAbove,
            items: program.items.compactMap { item in
                guard let spec = library.spec(item.exerciseId) else { return nil }
                let l = spec.limits
                let limits = ["sets \(l.sets.lowerBound)–\(l.sets.upperBound)",
                              l.reps.map { "reps \($0.lowerBound)–\($0.upperBound)" },
                              l.holdSeconds.map { "hold \($0.lowerBound)–\($0.upperBound)s" }].compactMap { $0 }.joined(separator: ", ")
                return ItemVM(id: item.id.uuidString, name: spec.name, category: spec.category.rawValue, isHold: spec.kind.isHold,
                              sets: item.dose.sets, reps: item.dose.reps ?? 0, hold: item.dose.holdSeconds ?? 0, rest: item.dose.restSeconds,
                              times: item.timesPerDay, target: item.targetKneeFlexion.map { "\(Int($0))" } ?? "",
                              tracksKnee: spec.tracksKneeFlexion, rationale: item.rationale, source: item.source.rawValue, limits: limits)
            },
            blocked: program.blockedSuggestions.map { "\(library.spec($0.exerciseId)?.name ?? $0.exerciseId): \($0.message)" },
            violations: ContraindicationChecker.violations(program: program, library: library).map(\.message),
            precautions: Formatters.precautions(program.precautions),
            addOptions: library.all.filter { spec in !program.items.contains { $0.exerciseId == spec.id } }
                .filter { ContraindicationChecker.violations(spec: $0, precautions: program.precautions).isEmpty }
                .map { Option(value: $0.id, label: "\($0.name) (\($0.category.rawValue))") }
        )
        return try await req.view.render("program-edit", vm)
    }

    func saveProgram(req: Request) async throws -> Response {
        let (model, _) = try await ownedProgram(req)
        var program = model.program
        guard program.status == .draft else { throw Abort(.badRequest, reason: "Signed programs can't be edited — create a revision.") }
        let form = try req.content.decode([String: String].self)
        func int(_ key: String) -> Int? { form[key].flatMap { Int($0.trimmingCharacters(in: .whitespaces)) } }

        var items: [ProgramItem] = []
        for var item in program.items {
            let key = item.id.uuidString
            if form["remove_\(key)"] == "on" { continue }
            item.dose.sets = int("sets_\(key)") ?? item.dose.sets
            if item.dose.reps != nil { item.dose.reps = int("reps_\(key)") ?? item.dose.reps }
            if item.dose.holdSeconds != nil { item.dose.holdSeconds = int("hold_\(key)") ?? item.dose.holdSeconds }
            item.dose.restSeconds = int("rest_\(key)") ?? item.dose.restSeconds
            item.timesPerDay = int("times_\(key)") ?? item.timesPerDay
            if let target = form["target_\(key)"] { item.targetKneeFlexion = Double(target) }
            if let rationale = form["rationale_\(key)"] { item.rationale = rationale }
            if item.source != .clinician { item.source = .clinician }
            items.append(item)
        }
        if let add = form["add_exercise"], !add.isEmpty, let spec = req.laile.library.spec(add) {
            items.append(ProgramItem(exerciseId: spec.id, dose: spec.defaultDose, rationale: "Added by clinician.", source: .clinician))
        }
        let (kept, blocked) = ContraindicationChecker.sanitize(items: items, precautions: program.precautions, library: req.laile.library)
        program.items = kept
        program.blockedSuggestions += blocked
        if let title = form["title"], !title.isEmpty { program.title = title }
        if let summary = form["summary"] { program.summary = summary }
        if let pain = int("pain_stop") { program.painStopSetAbove = min(9, max(0, pain)) }
        model.update(program)
        try await model.save(on: req.db)
        return req.redirect(to: "/portal/programs/\(program.id)")
    }

    func signProgram(req: Request) async throws -> Response {
        let (model, profile) = try await ownedProgram(req)
        var program = model.program
        guard program.status == .draft else { return req.redirect(to: "/portal/programs/\(program.id)") }
        guard !program.items.isEmpty, ContraindicationChecker.violations(program: program, library: req.laile.library).isEmpty else {
            throw Abort(.badRequest, reason: "This program has no exercises or still violates a precaution.")
        }
        // Archive the previously signed version.
        for old in try await ProgramModel.all(for: profile.requireID(), on: req.db) where old.program.status == .signed {
            var archived = old.program
            archived.status = .archived
            old.update(archived)
            try await old.save(on: req.db)
        }
        program.status = .signed
        program.signedAt = Date()
        program.signedBy = try req.user.displayName
        model.update(program)
        try await model.save(on: req.db)
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    func reviseProgram(req: Request) async throws -> Response {
        let (model, profile) = try await ownedProgram(req)
        var revision = model.program
        revision.id = UUID()
        revision.status = .draft
        revision.signedAt = nil
        revision.signedBy = nil
        revision.blockedSuggestions = []
        revision.createdAt = Date()
        revision.version = (try await ProgramModel.all(for: profile.requireID(), on: req.db).map(\.version).max() ?? 0) + 1
        revision.draftedBy = try req.user.displayName
        try await ProgramModel(patientID: profile.requireID(), program: revision).create(on: req.db)
        return req.redirect(to: "/portal/programs/\(revision.id)")
    }

    func reviewSymptom(req: Request) async throws -> Response {
        guard let id = req.parameters.get("symptomID", as: UUID.self), let symptom = try await SymptomReportModel.find(id, on: req.db) else {
            throw Abort(.notFound)
        }
        // Only the patient's own clinician may review.
        guard let profile = try await PatientProfileModel.query(on: req.db).filter(\.$user.$id == symptom.$user.id).first(),
              profile.$clinician.id == (try req.user.id) else { throw Abort(.forbidden) }
        symptom.reviewedAt = Date()
        symptom.reviewedBy = try req.user.displayName
        try await symptom.save(on: req.db)
        return req.redirect(to: "/portal/patients/\(try profile.requireID())")
    }

    // MARK: - Streams

    struct StreamVM: Encodable { var title: String; var host: String; var when: String; var minutes: Int; var intensity: Int; var tags: String; var status: String }
    struct StreamsVM: Encodable { var clinicianName: String; var streams: [StreamVM]; var formats: [Option] }

    func streams(req: Request) async throws -> View {
        let now = Date()
        let list = try await StreamsFeature.schedule(on: req.db, now: now).prefix(20).map { s -> StreamVM in
            let status: String = switch StreamClock.phase(of: s, at: now) {
            case .live: "Live"
            case .lobby: "Lobby open"
            case .upcoming: "Upcoming"
            case .ended: "Ended"
            }
            return StreamVM(title: s.title, host: s.hostName, when: Formatters.dateTime(s.scheduledStart), minutes: s.minutes,
                            intensity: s.intensity, tags: s.tags.joined(separator: ", "), status: status)
        }
        let formats = SessionTemplate.builtIn.filter { $0.mode == .move }.map { Option(value: $0.id, label: "\($0.title) — \($0.minutes) min") }
        return try await req.view.render("streams", StreamsVM(clinicianName: try req.user.displayName, streams: Array(list), formats: formats))
    }

    struct StreamForm: Content { var title: String; var template: String; var start: String; var host: String? }

    func createStream(req: Request) async throws -> Response {
        let form = try req.content.decode(StreamForm.self)
        guard let template = SessionTemplate.builtIn(form.template), let start = Formatters.parseLocalDateTime(form.start) else {
            throw Abort(.badRequest, reason: "Pick a routine and a start time.")
        }
        let segments = template.items.flatMap { item -> [StreamSegment] in
            let per = item.dose.holdSeconds ?? max(30, (item.dose.reps ?? 10) * 3)
            return [StreamSegment(exerciseId: item.exerciseId, durationSeconds: per * item.dose.sets), .rest(15)]
        }.dropLast()
        let hostName = try form.host?.nonEmpty ?? req.user.displayName
        let stream = StreamEvent(title: form.title.isEmpty ? template.title : form.title, hostName: hostName,
                                 summary: template.subtitle, kind: .live, scheduledStart: start, segments: Array(segments),
                                 intensity: template.items.compactMap { req.laile.library.spec($0.exerciseId)?.intensity }.max() ?? 2,
                                 tags: [template.isSnack ? "quick" : "workout"])
        try await StreamModel(stream: stream).create(on: req.db)
        return req.redirect(to: "/portal/streams")
    }

    // MARK: - Helpers

    func ownedPatient(_ req: Request) async throws -> PatientProfileModel {
        guard let id = req.parameters.get("patientID", as: UUID.self),
              let profile = try await PatientProfileModel.find(id, on: req.db),
              profile.$clinician.id == (try req.user.id) else { throw Abort(.notFound) }
        return profile
    }

    func ownedProgram(_ req: Request) async throws -> (ProgramModel, PatientProfileModel) {
        guard let id = req.parameters.get("programID", as: UUID.self),
              let model = try await ProgramModel.find(id, on: req.db),
              let profile = try await PatientProfileModel.find(model.$patient.id, on: req.db),
              profile.$clinician.id == (try req.user.id) else { throw Abort(.notFound) }
        return (model, profile)
    }
}

struct ClinicianOnlyMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        guard let user = request.auth.get(UserModel.self), user.role == .clinician || user.role == .admin else {
            return request.redirect(to: "/portal/login")
        }
        return try await next.respond(to: request)
    }
}

/// Everything the portal shows about one patient, loaded once.
struct PatientSnapshot {
    var sessions: [SessionSummary]
    var samples: [MetricSample]
    var trends: [MetricTrend]
    var symptoms: [SymptomReportModel]
    var programs: [Program]
    var flags: [String]
    var adherenceLabel: String

    func trend(_ kind: MetricKind) -> MetricTrend? { trends.first { $0.kind == kind } }

    static func load(_ profile: PatientProfileModel, on db: Database) async throws -> PatientSnapshot {
        let programs = try await ProgramModel.all(for: profile.requireID(), on: db).map(\.program)
        guard let userID = profile.$user.id else {
            return PatientSnapshot(sessions: [], samples: [], trends: [], symptoms: [], programs: programs,
                                   flags: ["Not linked yet — give the patient invite code \(profile.inviteCode)."], adherenceLabel: "—")
        }
        let sessions = try await SessionModel.query(on: db).filter(\.$user.$id == userID).sort(\.$startedAt, .descending).all().map(\.summary)
        let samples = try await MetricSampleModel.samples(for: userID, on: db)
        let trends = ProgressOverviewBuilder.trends(samples: samples, mode: .rehab)
        let symptoms = try await SymptomReportModel.query(on: db).filter(\.$user.$id == userID).sort(\.$reportedAt, .descending).all()

        var flags: [String] = []
        for s in symptoms where s.reviewedAt == nil && s.report.category == .redFlag {
            flags.append("RED FLAG \(Formatters.relative(s.reportedAt)): \(s.report.redFlagReason ?? s.report.utterance)")
        }
        let unreviewed = symptoms.filter { $0.reviewedAt == nil && $0.report.category.needsClinicianReview && $0.report.category != .redFlag }
        if !unreviewed.isEmpty { flags.append("\(unreviewed.count) pain/symptom report\(unreviewed.count == 1 ? "" : "s") to review") }
        for trend in trends { flags += trend.flags.map(\.message) }

        let signed = programs.first { $0.status == .signed }
        let perDay = signed.map { $0.items.map(\.timesPerDay).max() ?? 1 } ?? 1
        let weekAgo = Date().addingTimeInterval(-7 * 86_400)
        let done = sessions.filter { $0.startedAt > weekAgo && ($0.kind == .program || $0.kind == .baseline) }.count
        let adherence = signed == nil ? "No signed program" : "\(done) of \(perDay * 7) prescribed sessions (7 days)"
        if signed != nil, let last = sessions.first, Date().timeIntervalSince(last.endedAt) > 2 * 86_400 {
            flags.append("No session in \(Int(Date().timeIntervalSince(last.endedAt) / 86_400)) days")
        }
        return PatientSnapshot(sessions: sessions, samples: samples, trends: trends, symptoms: symptoms, programs: programs,
                               flags: flags, adherenceLabel: adherence)
    }
}

enum Formatters {
    static let zone = TimeZone(identifier: "Asia/Singapore")!

    static func dateTime(_ d: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "d MMM, h:mm a"
        f.timeZone = zone
        return f.string(from: d)
    }

    static func relative(_ d: Date) -> String {
        let f = RelativeDateTimeFormatter()
        f.unitsStyle = .full
        return f.localizedString(for: d, relativeTo: Date())
    }

    static func duration(_ seconds: Int) -> String { seconds >= 60 ? "\(seconds / 60) min" : "\(seconds)s" }

    static func list(_ text: String?) -> [String] {
        (text ?? "").split(whereSeparator: { $0 == "," || $0 == "\n" }).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    static func parseISODate(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        f.timeZone = zone
        return f.date(from: s)
    }

    static func parseLocalDateTime(_ s: String) -> Date? {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd'T'HH:mm"
        f.timeZone = zone
        return f.date(from: s)
    }

    static func precautions(_ p: Precautions) -> [String] {
        var out = [p.weightBearing.label, "Max: \(p.maxImpact.label.lowercased())"]
        if let k = p.maxKneeFlexion { out.append("Knee flexion ≤ \(Int(k))°") }
        if let h = p.maxHipFlexion { out.append("Hip flexion ≤ \(Int(h))°") }
        if p.noWristLoading { out.append("No wrist loading") }
        if let side = p.affectedSide { out.append("Affected side: \(side.rawValue)") }
        if !p.notes.isEmpty { out.append(p.notes) }
        return out
    }
}

/// "Name | dose | purpose | how to take | 08:00, 20:00" per line.
enum MedicationParser {
    static func parse(_ text: String, prescribedBy: String) -> [Medication] {
        text.split(separator: "\n").compactMap { line in
            let parts = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count >= 2, !parts[0].isEmpty else { return nil }
            let times = (parts.count > 4 ? parts[4] : "08:00").split(separator: ",").compactMap { t -> TimeOfDay? in
                let hm = t.trimmingCharacters(in: .whitespaces).split(separator: ":").compactMap { Int($0) }
                guard let h = hm.first, (0..<24).contains(h) else { return nil }
                return TimeOfDay(h, hm.count > 1 ? hm[1] : 0)
            }
            return Medication(name: parts[0], doseText: parts[1], purpose: parts.count > 2 ? parts[2] : "",
                              howToTake: parts.count > 3 ? parts[3] : "As prescribed.", times: times.isEmpty ? [TimeOfDay(8)] : times,
                              prescribedBy: prescribedBy)
        }
    }
}
