import Fluent
import LaileCore
import Vapor

/// Seeds fictional demo accounts and two weeks of history so the portal and app have
/// something to show. Runs only when the database has no users and SEED_DEMO_DATA is on
/// (the default outside production).
///
/// Demo accounts (all fictional; password for each is `DemoSeed.password`):
///   clinician@laile.demo — clinician portal
///   patient@laile.demo   — rehab patient with a signed knee program and 14 days of history
///   mover@laile.demo     — everyday Move-mode user
/// Unclaimed invite code for linking a fresh app install: DemoSeed.inviteCode
enum DemoSeed {
    static let password = "laile-demo-2026"
    static let inviteCode = "LAI-DEMO42"
    static let timeZone = "Asia/Singapore"
}

struct DemoSeedFeature: LaileFeature {
    let name = "demo-seed"

    func boot(_ app: Application) async throws {
        guard app.laile.config.seedDemoData, app.environment != .testing else { return }
        guard try await UserModel.query(on: app.db).count() == 0 else { return }
        try await seed(app)
        app.logger.info("Seeded demo data (clinician@laile.demo, patient@laile.demo, mover@laile.demo)")
    }

    func seed(_ app: Application) async throws {
        let db = app.db
        let hash = try Bcrypt.hash(DemoSeed.password)
        let clinician = UserModel(email: "clinician@laile.demo", passwordHash: hash, displayName: "Dr. Priya Nair (demo)",
                                  role: .clinician, mode: .move, timeZone: DemoSeed.timeZone)
        let patient = UserModel(email: "patient@laile.demo", passwordHash: hash, displayName: "Mdm Tan (demo)",
                                role: .patient, mode: .rehab, timeZone: DemoSeed.timeZone)
        let mover = UserModel(email: "mover@laile.demo", passwordHash: hash, displayName: "Alex (demo)",
                              role: .mover, mode: .move, timeZone: DemoSeed.timeZone)
        for user in [clinician, patient, mover] { try await user.create(on: db) }

        let now = Date()
        let day: TimeInterval = 86_400
        let medications = [
            Medication(name: "Paracetamol", doseText: "2 tablets", purpose: "Pain relief.",
                       howToTake: "As prescribed. Your physio may suggest timing a dose before exercise — check with them.",
                       times: [TimeOfDay(8), TimeOfDay(14), TimeOfDay(20)], prescribedBy: clinician.displayName),
            Medication(name: "Rivaroxaban", doseText: "1 tablet", purpose: "A blood thinner that lowers the risk of clots after surgery.",
                       howToTake: "Once a day at the same time. Don't stop without talking to your doctor.",
                       times: [TimeOfDay(9)], prescribedBy: clinician.displayName, endsOn: DayKey(now.addingTimeInterval(20 * day), timeZone: TimeZone(identifier: DemoSeed.timeZone)!)),
        ]
        let precautions = Precautions(weightBearing: .full, maxImpact: .low, affectedSide: .right, notes: "Walking frame outdoors for now.")
        let profile = PatientProfileModel(
            clinicianID: try clinician.requireID(), displayName: "Mdm Tan (demo)", age: 68, procedure: .totalKneeReplacement,
            procedureDate: now.addingTimeInterval(-16 * day), precautions: precautions, painStopSetAbove: 4,
            comorbidities: ["Hypertension (controlled)"], goals: ["Climb the stairs to the temple", "Walk to the hawker centre"],
            clinicalNotes: "Right TKA. Good early extension; flexion progressing. Lives with daughter.", medications: medications
        )
        profile.$user.id = try patient.requireID()
        profile.consentedAt = now.addingTimeInterval(-15 * day)
        try await profile.create(on: db)

        var program = TemplateDrafter.draft(context: profile.context, patientId: try profile.requireID(), now: now.addingTimeInterval(-15 * day))
        program.status = .signed
        program.signedAt = now.addingTimeInterval(-15 * day)
        program.signedBy = clinician.displayName
        program.painStopSetAbove = 4
        try await ProgramModel(patientID: profile.requireID(), program: program).create(on: db)

        // A second, unclaimed record so a fresh phone can link with the demo invite code.
        let unclaimed = PatientProfileModel(
            clinicianID: try clinician.requireID(), displayName: "Demo patient (unclaimed)", age: 64, procedure: .totalKneeReplacement,
            procedureDate: now.addingTimeInterval(-9 * day), precautions: Precautions(weightBearing: .partial, maxImpact: .low, affectedSide: .left),
            painStopSetAbove: 4, comorbidities: [], goals: ["Get back to gardening"], clinicalNotes: "", medications: medications
        )
        unclaimed.inviteCode = DemoSeed.inviteCode
        try await unclaimed.create(on: db)
        var unclaimedProgram = TemplateDrafter.draft(context: unclaimed.context, patientId: try unclaimed.requireID(), now: now)
        unclaimedProgram.status = .signed
        unclaimedProgram.signedAt = now
        unclaimedProgram.signedBy = clinician.displayName
        try await ProgramModel(patientID: unclaimed.requireID(), program: unclaimedProgram).create(on: db)

        try await seedPatientHistory(app: app, patient: patient, program: program, now: now)
        try await seedMoverHistory(app: app, mover: mover, now: now)
    }

    func seedPatientHistory(app: Application, patient: UserModel, program: Program, now: Date) async throws {
        let db = app.db
        let ledger = RewardsLedger(user: patient, db: db, engine: app.laile.rewardEngine(timeZone: patient.timeZone))
        let recorder = SessionRecorder(db: db, library: app.laile.library, ledger: ledger)
        // Knee flexion climbs, then plateaus in the last few sessions (shows the plateau flag).
        let flexion: [Double] = [62, 64, 67, 70, 72, 75, 77, 80, 82, 84, 85, 84, 85, 86]
        let extensionDeficit: [Double] = [12, 12, 11, 10, 10, 9, 8, 8, 7, 7, 6, 6, 5, 5]

        for (i, flex) in flexion.enumerated() {
            let daysAgo = Double(flexion.count - i)
            let start = now.addingTimeInterval(-daysAgo * 86_400 + 9.5 * 3600 - 12 * 3600)
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
            _ = try await recorder.record(summary, userID: patient.requireID(), now: summary.endedAt)
        }
    }

    func seedMoverHistory(app: Application, mover: UserModel, now: Date) async throws {
        let db = app.db
        let ledger = RewardsLedger(user: mover, db: db, engine: app.laile.rewardEngine(timeZone: mover.timeZone))
        let recorder = SessionRecorder(db: db, library: app.laile.library, ledger: ledger)
        let pushUps = [6, 7, 7, 9, 10, 11]
        for (i, reps) in pushUps.enumerated() {
            let start = now.addingTimeInterval(-Double(pushUps.count - i) * 86_400 + 12.5 * 3600 - 12 * 3600)
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
            _ = try await recorder.record(summary, userID: mover.requireID(), now: summary.endedAt)
        }
    }
}
