import Fluent
import LaileCore
import Vapor

/// Fictional demo data for judging and demo day. Enabled by `SEED_DEMO_DATA` (default on outside
/// production; set it to `true` on the hackathon deployment).
///
/// - Fixed accounts (password `DemoSeed.password`) — signing in to the patient or mover account
///   resets it to the seeded story, so every demo run starts the same:
///     clinician@laile.demo — clinician portal
///     patient@laile.demo   — knee-replacement patient, day 16, 14 days of history
///     mover@laile.demo     — everyday Move-mode user, 6 days of history
/// - Guest demos (`POST /v1/demo/sessions`, the app's "Try the demo" buttons) — a fresh account per
///   tap with the same story, so several people can demo at once without resetting each other.
///   Guests are deleted after `DemoWorld.guestLifetime`.
/// - The invite code `DemoSeed.inviteCode` can be used by anyone, any number of times: each use
///   gets its own copy of the demo patient record under the demo clinician.
enum DemoSeed {
    static let password = "laile-demo-2026"
    static let inviteCode = "LAI-DEMO42"
    static let timeZone = "Asia/Singapore"
    static let clinicianEmail = "clinician@laile.demo"
    static let patientEmail = "patient@laile.demo"
    static let moverEmail = "mover@laile.demo"
}

struct DemoWorld {
    let app: Application
    let db: any Database

    init(app: Application, db: (any Database)? = nil) {
        self.app = app
        self.db = db ?? app.db
    }

    static let fixedDomain = "@laile.demo"
    static let guestDomain = "@guest.laile.app"
    static let guestLifetime: TimeInterval = 12 * 3600

    static func isDemo(email: String) -> Bool {
        email.hasSuffix(fixedDomain) || email.hasSuffix(guestDomain)
    }

    static func isGuest(_ user: UserModel) -> Bool { user.email.hasSuffix(guestDomain) }

    static func resetsOnLogin(_ user: UserModel) -> Bool {
        user.email == DemoSeed.patientEmail || user.email == DemoSeed.moverEmail
    }

    // MARK: Base accounts

    /// Creates any missing fixed accounts and the invite-code template. Idempotent.
    @discardableResult
    func ensureBase() async throws -> UserModel {
        let clinician = try await fixedUser(DemoSeed.clinicianEmail, name: "Dr. Priya Nair (demo)", role: .clinician, mode: .move)
        if try await PatientProfileModel.query(on: db).filter(\.$inviteCode == DemoSeed.inviteCode).first() == nil {
            try await createTemplate(clinician: clinician)
        }
        let patient = try await fixedUser(DemoSeed.patientEmail, name: "Mdm Tan (demo)", role: .patient, mode: .rehab)
        if try await PatientProfileModel.query(on: db).filter(\.$user.$id == patient.requireID()).first() == nil {
            try await seedPatientStory(user: patient, clinician: clinician, profileName: "Mdm Tan (demo)")
        }
        let mover = try await fixedUser(DemoSeed.moverEmail, name: "Alex (demo)", role: .mover, mode: .move)
        if try await SessionModel.query(on: db).filter(\.$user.$id == mover.requireID()).count() == 0 {
            try await seedMoverStory(user: mover)
        }
        return clinician
    }

    private func fixedUser(_ email: String, name: String, role: API.UserRole, mode: AppMode) async throws -> UserModel {
        if let existing = try await UserModel.query(on: db).filter(\.$email == email).first() { return existing }
        let user = UserModel(email: email, passwordHash: try Bcrypt.hash(DemoSeed.password), displayName: name,
                             role: role, mode: mode, timeZone: DemoSeed.timeZone)
        try await user.create(on: db)
        return user
    }

    // MARK: Reset / guests

    /// Back to the seeded story, keeping the account (and anyone's sign-in to it) intact.
    func reset(_ user: UserModel) async throws {
        // Ensure the base first: after the wipe, ensureBase would re-seed this very account.
        let clinician = try await ensureBase()
        try await wipe(user)
        if user.email == DemoSeed.patientEmail {
            user.role = .patient
            user.mode = .rehab
            try await user.save(on: db)
            try await seedPatientStory(user: user, clinician: clinician, profileName: "Mdm Tan (demo)")
        } else {
            user.role = .mover
            user.mode = .move
            try await user.save(on: db)
            try await seedMoverStory(user: user)
        }
    }

    /// A brand-new demo account with the persona's history.
    func startGuest(persona: API.DemoPersona, timeZone: String) async throws -> UserModel {
        let clinician = try await ensureBase()
        let tz = TimeZone(identifier: timeZone) != nil ? timeZone : DemoSeed.timeZone
        let suffix = String(UUID().uuidString.prefix(8)).lowercased()
        let user: UserModel
        switch persona {
        case .patient:
            user = UserModel(email: "patient-\(suffix)\(Self.guestDomain)", passwordHash: try Bcrypt.hash(UUID().uuidString),
                             displayName: "Mdm Tan (demo)", role: .patient, mode: .rehab, timeZone: tz)
            try await user.create(on: db)
            try await seedPatientStory(user: user, clinician: clinician, profileName: "Mdm Tan (demo guest \(clockLabel(tz)))")
        case .mover:
            user = UserModel(email: "mover-\(suffix)\(Self.guestDomain)", passwordHash: try Bcrypt.hash(UUID().uuidString),
                             displayName: "Alex (demo)", role: .mover, mode: .move, timeZone: tz)
            try await user.create(on: db)
            try await seedMoverStory(user: user)
        }
        return user
    }

    func deleteGuest(_ user: UserModel) async throws {
        guard Self.isGuest(user) else { return }
        try await wipe(user)
        try await UserTokenModel.query(on: db).filter(\.$user.$id == user.requireID()).delete()
        try await user.delete(on: db)
    }

    func cleanupGuests(now: Date = Date()) async throws {
        let cutoff = now.addingTimeInterval(-Self.guestLifetime)
        let stale = try await UserModel.query(on: db).filter(\.$email ~~ Self.guestDomain).filter(\.$createdAt < cutoff).all()
        for user in stale { try await deleteGuest(user) }
    }

    /// Removes everything a user has done, including their patient record and programs.
    func wipe(_ user: UserModel) async throws {
        let id = try user.requireID()
        try await ActivityRecordModel.query(on: db).filter(\.$user.$id == id).delete()
        try await SessionModel.query(on: db).filter(\.$user.$id == id).delete()
        try await MetricSampleModel.query(on: db).filter(\.$user.$id == id).delete()
        try await SymptomReportModel.query(on: db).filter(\.$user.$id == id).delete()
        try await MedicationLogModel.query(on: db).filter(\.$user.$id == id).delete()
        try await CareNoteModel.query(on: db).filter(\.$user.$id == id).delete()
        for profile in try await PatientProfileModel.query(on: db).filter(\.$user.$id == id).all() {
            try await ProgramModel.query(on: db).filter(\.$patient.$id == profile.requireID()).delete()
            try await profile.delete(on: db)
        }
    }

    // MARK: Demo invite code

    /// Links `user` to their own copy of the demo patient record, so the code never runs out.
    func linkWithDemoCode(user: UserModel) async throws -> PatientProfileModel {
        let clinician = try await ensureBase()
        guard let template = try await PatientProfileModel.query(on: db).filter(\.$inviteCode == DemoSeed.inviteCode).first() else {
            throw Abort(.notFound)
        }
        // Linking again replaces the previous demo record.
        for existing in try await PatientProfileModel.query(on: db).filter(\.$user.$id == user.requireID()).all() {
            try await ProgramModel.query(on: db).filter(\.$patient.$id == existing.requireID()).delete()
            try await existing.delete(on: db)
        }
        let copy = PatientProfileModel(
            clinicianID: try clinician.requireID(), displayName: user.displayName, age: template.age, procedure: template.procedure,
            procedureDate: template.procedureDate, precautions: template.precautions, painStopSetAbove: template.painStopSetAbove,
            comorbidities: template.comorbidities, goals: template.goals, clinicalNotes: template.clinicalNotes,
            medications: template.medications
        )
        copy.$user.id = try user.requireID()
        copy.consentedAt = Date()
        try await copy.create(on: db)
        if let program = try await ProgramModel.activeSigned(for: template.requireID(), on: db)?.program {
            var cloned = program
            cloned.id = UUID()
            cloned.patientId = try copy.requireID()
            cloned.items = cloned.items.map { var item = $0; item.id = UUID(); return item }
            try await ProgramModel(patientID: copy.requireID(), program: cloned).create(on: db)
        }
        copy.$clinician.value = clinician
        return copy
    }

    // MARK: Stories

    static func medications(prescribedBy: String, timeZone: TimeZone, now: Date) -> [Medication] {
        [
            Medication(name: "Paracetamol", doseText: "2 tablets", purpose: "Pain relief.",
                       howToTake: "As prescribed. Your physio may suggest timing a dose before exercise — check with them.",
                       times: [TimeOfDay(8), TimeOfDay(14), TimeOfDay(20)], prescribedBy: prescribedBy),
            Medication(name: "Rivaroxaban", doseText: "1 tablet", purpose: "A blood thinner that lowers the risk of clots after surgery.",
                       howToTake: "Once a day at the same time. Don't stop without talking to your doctor.",
                       times: [TimeOfDay(9)], prescribedBy: prescribedBy,
                       endsOn: DayKey(now.addingTimeInterval(20 * 86_400), timeZone: timeZone)),
        ]
    }

    private func createTemplate(clinician: UserModel) async throws {
        let now = Date()
        let tz = TimeZone(identifier: DemoSeed.timeZone)!
        let template = PatientProfileModel(
            clinicianID: try clinician.requireID(), displayName: "Demo invite template (LAI-DEMO42)", age: 64,
            procedure: .totalKneeReplacement, procedureDate: now.addingTimeInterval(-9 * 86_400),
            precautions: Precautions(weightBearing: .partial, maxImpact: .low, affectedSide: .left),
            painStopSetAbove: 4, comorbidities: [], goals: ["Get back to gardening"],
            clinicalNotes: "Template record: every use of the demo invite code gets its own copy.",
            medications: Self.medications(prescribedBy: clinician.displayName, timeZone: tz, now: now)
        )
        template.inviteCode = DemoSeed.inviteCode
        try await template.create(on: db)
        var program = TemplateDrafter.draft(context: template.context, patientId: try template.requireID(), now: now)
        program.status = .signed
        program.signedAt = now
        program.signedBy = clinician.displayName
        try await ProgramModel(patientID: template.requireID(), program: program).create(on: db)
    }

    /// Knee-replacement patient on day 16: signed program and 14 days of sessions, with knee bend
    /// climbing then plateauing (shows the plateau flag) and one sharp-pain report to review.
    func seedPatientStory(user: UserModel, clinician: UserModel, profileName: String) async throws {
        let now = Date()
        let tz = TimeZone(identifier: user.timeZone) ?? TimeZone(identifier: DemoSeed.timeZone)!
        let day: TimeInterval = 86_400
        let profile = PatientProfileModel(
            clinicianID: try clinician.requireID(), displayName: profileName, age: 68, procedure: .totalKneeReplacement,
            procedureDate: now.addingTimeInterval(-16 * day),
            precautions: Precautions(weightBearing: .full, maxImpact: .low, affectedSide: .right, notes: "Walking frame outdoors for now."),
            painStopSetAbove: 4, comorbidities: ["Hypertension (controlled)"],
            goals: ["Climb the stairs to the temple", "Walk to the hawker centre"],
            clinicalNotes: "Right TKA. Good early extension; flexion progressing. Lives with daughter.",
            medications: Self.medications(prescribedBy: clinician.displayName, timeZone: tz, now: now)
        )
        profile.$user.id = try user.requireID()
        profile.consentedAt = now.addingTimeInterval(-15 * day)
        try await profile.create(on: db)

        var program = TemplateDrafter.draft(context: profile.context, patientId: try profile.requireID(), now: now.addingTimeInterval(-15 * day))
        program.status = .signed
        program.signedAt = now.addingTimeInterval(-15 * day)
        program.signedBy = clinician.displayName
        program.painStopSetAbove = 4
        try await ProgramModel(patientID: profile.requireID(), program: program).create(on: db)

        let ledger = RewardsLedger(user: user, db: db, engine: app.laile.rewardEngine(timeZone: user.timeZone))
        let recorder = SessionRecorder(db: db, library: app.laile.library, ledger: ledger)
        let flexion: [Double] = [62, 64, 67, 70, 72, 75, 77, 80, 82, 84, 85, 84, 85, 86]
        let extensionDeficit: [Double] = [12, 12, 11, 10, 10, 9, 8, 8, 7, 7, 6, 6, 5, 5]

        for (i, flex) in flexion.enumerated() {
            let start = Self.pastDay(flexion.count - i, hour: 9.5, timeZone: tz, now: now)
            let checkIn = ledger.engine.checkIn(now: start.addingTimeInterval(-600), history: try await ledger.history())
            try await ledger.append(checkIn.records)

            var heel = ExerciseResult(exerciseId: "heel-slide", side: .right, plannedSets: 2)
            heel.repsPerSet = [10, i == 11 ? 7 : 10]
            heel.minAngle = 180 - flex
            heel.maxAngle = 180 - extensionDeficit[i]
            heel.repPeakAngles = Array(repeating: 180 - flex + 2, count: heel.repsPerSet.reduce(0, +))
            var quad = ExerciseResult(exerciseId: "quad-set", side: .right, plannedSets: 10)
            quad.holdSecondsPerSet = Array(repeating: 5, count: 10)
            quad.maxAngle = 180 - extensionDeficit[i]
            quad.minAngle = 160
            var slr = ExerciseResult(exerciseId: "straight-leg-raise", side: .right, plannedSets: 2)
            slr.repsPerSet = [min(10, 5 + i / 2), min(10, 4 + i / 2)]
            var ankle = ExerciseResult(exerciseId: "ankle-pumps", side: .right, plannedSets: 1)
            ankle.holdSecondsPerSet = [45]

            var symptoms: [SymptomReport] = []
            if i == 11 {
                symptoms.append(SymptomReport(timestamp: start.addingTimeInterval(420), category: .pain,
                                              utterance: "Ow — sharp, on the inside of my knee. About a six.",
                                              bodyLocation: "inside of knee", side: .right, quality: "sharp", severity: 6,
                                              source: .voiceLLM, exerciseId: "heel-slide", setIndex: 1, repIndex: 8, angle: 95,
                                              action: .stopSet))
            }
            if i == 6 {
                symptoms.append(SymptomReport(timestamp: start.addingTimeInterval(300), category: .expectedStretch,
                                              utterance: "It's pulling behind my knee", bodyLocation: "back of knee", side: .right,
                                              quality: "pulling", source: .voiceLLM, exerciseId: "heel-slide", setIndex: 0, repIndex: 4,
                                              angle: 104, action: .continueExercise))
            }
            let summary = SessionSummary(
                kind: i == 0 ? .baseline : .program, title: i == 0 ? "Knee check-in" : program.title, mode: .rehab,
                startedAt: start, endedAt: start.addingTimeInterval(14 * 60), programId: program.id,
                exercises: [ankle, quad, heel, slr], symptoms: symptoms, painBefore: max(1, 5 - i / 3), painAfter: max(1, 4 - i / 4)
            )
            _ = try await recorder.record(summary, userID: user.requireID(), now: summary.endedAt)
        }
    }

    /// Everyday user with six days of lunch-break sessions and improving push-ups.
    func seedMoverStory(user: UserModel) async throws {
        let now = Date()
        let tz = TimeZone(identifier: user.timeZone) ?? TimeZone(identifier: DemoSeed.timeZone)!
        let ledger = RewardsLedger(user: user, db: db, engine: app.laile.rewardEngine(timeZone: user.timeZone))
        let recorder = SessionRecorder(db: db, library: app.laile.library, ledger: ledger)
        let pushUps = [6, 7, 7, 9, 10, 11]
        for (i, reps) in pushUps.enumerated() {
            let start = Self.pastDay(pushUps.count - i, hour: 12.5, timeZone: tz, now: now)
            let checkIn = ledger.engine.checkIn(now: start.addingTimeInterval(-300), history: try await ledger.history())
            try await ledger.append(checkIn.records)
            var push = ExerciseResult(exerciseId: "push-up", side: .left, plannedSets: 1)
            push.repsPerSet = [reps]
            var squat = ExerciseResult(exerciseId: "squat", side: .left, plannedSets: 1)
            squat.repsPerSet = [15 + i * 2]
            var plank = ExerciseResult(exerciseId: "plank", side: .left, plannedSets: 1)
            plank.holdSecondsPerSet = [30 + i * 6]
            let summary = SessionSummary(kind: i == 0 ? .baseline : .snack, title: i == 0 ? "Fitness check" : "Lunch-break blast",
                                         mode: .move, startedAt: start, endedAt: start.addingTimeInterval(7 * 60),
                                         templateId: i == 0 ? "move-baseline" : "lunch-blast", exercises: [push, squat, plank])
            _ = try await recorder.record(summary, userID: user.requireID(), now: summary.endedAt)
        }
    }

    /// `hour` o'clock on the local calendar day `daysAgo` days before today, so streaks line up
    /// with the user's own days whatever time the demo starts.
    static func pastDay(_ daysAgo: Int, hour: Double, timeZone: TimeZone, now: Date) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: now)
        return calendar.date(byAdding: .day, value: -daysAgo, to: today)!.addingTimeInterval(hour * 3600)
    }

    private func clockLabel(_ timeZone: String) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        formatter.timeZone = TimeZone(identifier: timeZone)
        return formatter.string(from: Date())
    }
}

struct DemoFeature: LaileFeature {
    let name = "demo"

    func boot(_ app: Application) async throws {
        // Starts a fresh guest demo. If the caller is signed in as a guest, that guest is replaced.
        app.grouped("v1").grouped(UserTokenModel.authenticator()).post("demo", "sessions") { req async throws -> API.AuthResponse in
            guard req.laile.config.seedDemoData else { throw Abort(.notFound) }
            let body = try req.content.decode(API.DemoStartRequest.self)
            let previous = req.auth.get(UserModel.self)
            let user = try await req.db.transaction { db -> UserModel in
                let world = DemoWorld(app: req.application, db: db)
                try await world.cleanupGuests()
                if let previous, DemoWorld.isGuest(previous) { try await world.deleteGuest(previous) }
                return try await world.startGuest(persona: body.persona, timeZone: body.timeZone)
            }
            let token = try user.generateToken()
            try await token.save(on: req.db)
            return API.AuthResponse(token: token.value, user: try await user.profileWithClinician(on: req.db))
        }

        guard app.laile.config.seedDemoData, app.environment != .testing else { return }
        try await DemoWorld(app: app).ensureBase()
        app.logger.info("Demo accounts ready (\(DemoSeed.clinicianEmail), \(DemoSeed.patientEmail), \(DemoSeed.moverEmail)); invite code \(DemoSeed.inviteCode)")
    }
}

extension API.DemoStartRequest: @retroactive Content {}
