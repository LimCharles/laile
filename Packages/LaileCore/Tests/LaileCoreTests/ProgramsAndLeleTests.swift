import Foundation
import Testing
@testable import LaileCore

@Suite struct ProgramModelTests {
    let library = ExerciseLibrary.standard

    @Test func stricterPrecautionWinsWhenMerged() {
        let mine = Precautions(maxImpact: .moderate, noWristLoading: true)
        let clinician = Precautions(maxKneeFlexion: 90, maxShoulderElevation: 100, maxImpact: .low, avoidExerciseIds: ["squat"])
        let merged = mine.merged(with: clinician)
        #expect(merged.maxImpact == .low)
        #expect(merged.noWristLoading)
        #expect(merged.maxKneeFlexion == 90 && merged.maxShoulderElevation == 100)
        #expect(merged.avoidExerciseIds == ["squat"])
    }

    @Test func shoulderLimitCapsArmLiftsAndBlocksJumpingJacks() {
        let limits = Precautions(maxShoulderElevation: 100)
        let plan = SessionTemplate.builtIn("shoulder-mobility")!.plan() + SessionTemplate.builtIn("lunch-blast")!.plan()
        let (kept, removed) = ContraindicationChecker.filter(plan, precautions: limits)
        #expect(kept.first { $0.spec.id == "shoulder-flexion" }?.repRule?.target == 100)
        #expect(removed.contains { $0.exerciseId == "jumping-jacks" && $0.rule == "shoulder-elevation" })
    }

    @Test func checkInSetsPersonalTargets() throws {
        let program = SessionTemplate.builtIn("first-push-up")!.asProgram()
        var enrollment = Enrollment(kind: .catalog, title: program.title, program: program, catalogId: "first-push-up")
        #expect(enrollment.needsCalibration)
        let checkIn = enrollment.calibrationPlan()
        #expect(checkIn.allSatisfy { $0.dose.sets == 1 })
        #expect(checkIn.first { $0.spec.id == "incline-push-up" }?.dose.reps == 20)

        var push = ExerciseResult(exerciseId: "incline-push-up", side: .left, plannedSets: 1)
        push.repsPerSet = [14]
        var plank = ExerciseResult(exerciseId: "plank", side: .left, plannedSets: 1)
        plank.holdSecondsPerSet = [40]
        let summary = SessionSummary(kind: .baseline, title: "Check-in", mode: .move, startedAt: Date(), endedAt: Date(), exercises: [push, plank])
        enrollment.calibration = Calibration.from(summary)
        let plan = enrollment.sessionPlan().plan
        #expect(plan.first { $0.spec.id == "incline-push-up" }?.dose.reps == 10) // 70% of 14
        #expect(plan.first { $0.spec.id == "plank" }?.dose.holdSeconds == 30)   // 70% of 40, to the nearest 5
        #expect(!enrollment.needsCalibration)
    }

    @Test func checkInOnlyMakesSupervisedProgramsEasierAndCountsRepsAtTheirRange() throws {
        var item = ProgramItem(exerciseId: "heel-slide", dose: Dose(sets: 2, reps: 10), source: .clinician)
        item.targetKneeFlexion = nil
        let program = Program(title: "Knee", items: [item], precautions: .none, status: .signed, draftedBy: "Dr")
        let calibration = Calibration(measuredAt: Date(), exercises: [ExerciseCalibration(exerciseId: "heel-slide", maxReps: 20, peakAngle: 130)])
        let enrollment = Enrollment(kind: .clinical, title: "Knee", program: program, calibration: calibration)
        let planned = try #require(enrollment.sessionPlan().plan.first)
        #expect(planned.dose.reps == 10) // 70% of 20 is 14, but a clinician's 10 is never exceeded
        // Reached 160 → 130 (30° of the usual 50°): a rep counts at 90% of that.
        #expect(abs((planned.repRule?.target ?? 0) - 133) < 0.01)
    }

    @Test func personalDrafterRespectsWhatTheyToldLele() {
        let profile = HealthProfile(goals: [.getStronger], minutesPerDay: 10, experience: .some, sensitiveAreas: [.knees, .wrists])
        let draft = PersonalProgramDrafter.draft(profile)
        let ids = draft.program.items.map(\.exerciseId)
        #expect(ids.contains("sit-to-stand"))
        #expect(!ids.contains("squat"))
        #expect(!ids.contains { ExerciseLibrary.standard.spec($0)?.loads.loadsWrists == true })
        #expect(draft.program.draftedBy == "Lele")
        #expect(!draft.reasons.isEmpty)
    }

    @Test func injuryGoalSuggestsAClinician() {
        #expect(HealthProfile(goals: [.recoverInjury]).shouldSeeClinician)
        #expect(!HealthProfile(goals: [.getStronger]).shouldSeeClinician)
    }

    @Test func followOnFromPhysio() {
        #expect(FollowOn.catalogId(for: .totalKneeReplacement) == "strong-knees")
        #expect(FollowOn.catalogId(for: .stiffShoulder) == "shoulder-mobility")
        #expect(SessionTemplate.catalogPrograms.contains { $0.id == "strong-knees" })
    }

    @Test func armLiftIsMeasured() throws {
        var result = ExerciseResult(exerciseId: "shoulder-flexion", side: .right, plannedSets: 1)
        result.repsPerSet = [8]
        result.maxAngle = 141
        let summary = SessionSummary(kind: .program, title: "Shoulder", mode: .rehab, startedAt: Date(), endedAt: Date(), exercises: [result])
        let sample = try #require(MetricExtractor.samples(from: summary, library: library).first { $0.kind == .shoulderElevation })
        #expect(sample.value == 141)
    }
}

@Suite struct LeleRoundTests {
    let tz = TimeZone(identifier: "Asia/Singapore")!

    func at(_ hour: Int, day: Int = 30) -> Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = tz
        return c.date(from: DateComponents(year: 2026, month: 9, day: day, hour: hour))!
    }

    var knee: Enrollment {
        let program = Program(title: "Knee program", items: [ProgramItem(exerciseId: "heel-slide", dose: Dose(sets: 2, reps: 10), source: .clinician)],
                              precautions: .none, status: .signed, draftedBy: "Dr")
        return Enrollment(kind: .clinical, title: "Knee program", program: program, supervisorName: "Dr Nair",
                          calibration: Calibration(measuredAt: Date(), exercises: []))
    }

    @Test func morningCheckInForSupervisedPrograms() throws {
        let messages = LeleRound.decide(LeleRoundInput(now: at(8), timeZone: tz, firstName: "Mdm Tan", enrollments: [knee],
                                                       lastSessionAt: at(9, day: 29), sessionsToday: 0))
        let checkIn = try #require(messages.first { $0.kind == .morningCheckIn })
        #expect(checkIn.text.contains("knee"))
        #expect(checkIn.actions.map(\.id).contains("worse"))
    }

    @Test func quietHoursAndNoRepeats() {
        let input = LeleRoundInput(now: at(22), timeZone: tz, firstName: "Sam", enrollments: [knee], lastSessionAt: nil, sessionsToday: 0)
        #expect(LeleRound.decide(input).isEmpty)
        let first = LeleRound.decide(LeleRoundInput(now: at(8), timeZone: tz, firstName: "Sam", enrollments: [knee], lastSessionAt: at(9, day: 29), sessionsToday: 0))
        let again = LeleRound.decide(LeleRoundInput(now: at(9), timeZone: tz, firstName: "Sam", enrollments: [knee], lastSessionAt: at(9, day: 29),
                                                    sessionsToday: 0, recentMessages: first))
        #expect(!first.isEmpty)
        #expect(again.isEmpty)
    }

    @Test func missedDaysNudgeThenAskWhy() throws {
        let nudge = LeleRound.decide(LeleRoundInput(now: at(17), timeZone: tz, firstName: "Sam", enrollments: [knee], lastSessionAt: at(9, day: 28), sessionsToday: 0))
        #expect(nudge.contains { $0.kind == .nudge && $0.text.contains("never missing twice") })
        let barrier = LeleRound.decide(LeleRoundInput(now: at(12), timeZone: tz, firstName: "Sam", enrollments: [knee], lastSessionAt: at(9, day: 26), sessionsToday: 0))
        let ask = try #require(barrier.first { $0.kind == .barrier })
        #expect(ask.actions.map(\.id) == Barrier.allCases.map(\.rawValue))
    }

    @Test func newProgramStartsWithACheckIn() throws {
        let program = SessionTemplate.builtIn("first-push-up")!.asProgram()
        let fresh = Enrollment(kind: .catalog, title: "First push-up", program: program)
        let messages = LeleRound.decide(LeleRoundInput(now: at(12), timeZone: tz, firstName: "Sam", enrollments: [fresh], lastSessionAt: nil, sessionsToday: 0))
        let message = try #require(messages.first { $0.kind == .calibration })
        #expect(message.actions.first?.value == fresh.id.uuidString)
    }

    @Test func dailyLimitButRemindersStillCome() {
        let med = Medication(name: "Paracetamol", doseText: "2 tablets", purpose: "Pain relief.", howToTake: "", times: [TimeOfDay(12)], prescribedBy: "Dr")
        let dose = MedicationDose(medication: med, scheduled: TimeOfDay(12), taken: false)
        let earlier = (0..<3).map { i in LeleMessage(createdAt: at(8), kind: .nudge, text: "n\(i)", dedupeKey: "old-\(i)") }
        let messages = LeleRound.decide(LeleRoundInput(now: at(12).addingTimeInterval(600), timeZone: tz, firstName: "Sam", enrollments: [knee],
                                                       lastSessionAt: at(9, day: 26), sessionsToday: 0, dosesToday: [dose], recentMessages: earlier))
        #expect(messages.count == 1)
        #expect(messages.first?.kind == .reminder)
    }

    @Test func worseMorningMakesTodayGentler() throws {
        let flare = CareMemory.flare(at: Date(), reply: "Worse")
        let plan = [PlannedExercise(spec: ExerciseLibrary.standard.spec("heel-slide")!, dose: Dose(sets: 2, reps: 10))]
        let eased = CareMemory.adjust(plan, notes: [flare])[0]
        #expect(eased.repRule!.target > 110)
        #expect(eased.careCue?.text.hasPrefix("You said things were worse this morning") == true)
        // One comfortable session closes the flare.
        var heel = ExerciseResult(exerciseId: "heel-slide", side: .right, plannedSets: 2)
        heel.repsPerSet = [10, 10]
        let changed = CareMemory.update([flare], after: SessionSummary(kind: .program, title: "Knee", mode: .rehab, startedAt: Date(), endedAt: Date(), exercises: [heel]))
        #expect(changed.first?.status == .resolved)
    }
}

@Suite struct ProgramReviserTests {
    var program: Program {
        TemplateDrafter.draft(context: PatientContext(displayName: "Test", procedure: .totalKneeReplacement, procedureDate: Date().addingTimeInterval(-20 * 86_400),
                                                      precautions: Precautions(maxImpact: .low)), patientId: nil)
    }

    @Test func gentlerScalesDosesDownWithinLimits() throws {
        let revision = ProgramReviser.revise(program, instruction: "Make it gentler, she had a flare this week")
        #expect(revision.understood)
        let before = try #require(program.items.first { $0.exerciseId == "heel-slide" })
        let after = try #require(revision.items.first { $0.exerciseId == "heel-slide" })
        #expect((after.dose.reps ?? 0) < (before.dose.reps ?? 0))
        #expect(revision.changes.contains { $0.hasPrefix("Eased Heel slides") })
    }

    @Test func focusAddsExercisesAndDropRemoves() {
        let revision = ProgramReviser.revise(program, instruction: "Focus on hip strength and drop the mini squat")
        #expect(!revision.items.contains { $0.exerciseId == "mini-squat" })
        #expect(revision.items.contains { $0.exerciseId == "glute-bridge" })
        #expect(revision.changes.contains("Removed Mini squat"))
    }

    @Test func precautionsStillApply() {
        let revision = ProgramReviser.revise(program, instruction: "Add jumping jacks")
        #expect(!revision.items.contains { $0.exerciseId == "jumping-jacks" })
        #expect(revision.changes.contains { $0.hasPrefix("Left out Jumping jacks") })
    }
}

@Suite struct ClinicianBriefTests {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let tz = TimeZone(identifier: "Asia/Singapore")!

    @Test func redFlagsComeFirstThenTodayThenFYI() {
        let flare = CareNote(createdAt: now.addingTimeInterval(-3600), kind: .flare, source: .lele, text: "Worse this morning")
        let request = ProgramRequest(catalogId: "core-foundations", title: "Core foundations", createdAt: now.addingTimeInterval(-7200))
        let items = ClinicianBrief.items(for: BriefInput(
            now: now, timeZone: tz, redFlags: [(now.addingTimeInterval(-60), "calf swollen and hot")],
            careNotes: [flare], lastSessionAt: now.addingTimeInterval(-86_400), checkIns: [("Strong knees", now.addingTimeInterval(-600))],
            requests: [request], progressFlags: ["Arm lift hasn't improved over the last 4 sessions."]
        ))
        #expect(items.first?.kind == .redFlag)
        #expect(items.map(\.priority) == items.map(\.priority).sorted())
        #expect(items.contains { $0.kind == .request && $0.requestId == request.id })
        #expect(items.contains { $0.kind == .worse })
        #expect(items.last?.priority == .fyi)
    }

    @Test func missedDaysAndOldNotesAreFiltered() {
        let oldFlare = CareNote(createdAt: now.addingTimeInterval(-3 * 86_400), kind: .flare, source: .lele, text: "Worse")
        let answered = ProgramRequest(catalogId: "desk-reset", title: "Desk reset", status: .approved, createdAt: now)
        let items = ClinicianBrief.items(for: BriefInput(now: now, timeZone: tz, careNotes: [oldFlare],
                                                         lastSessionAt: now.addingTimeInterval(-4 * 86_400), requests: [answered]))
        #expect(items.map(\.kind) == [.missed])
        #expect(items.first?.text.contains("4 days") == true)
        #expect(ClinicianBrief.items(for: BriefInput(now: now, timeZone: tz, lastSessionAt: now)).isEmpty)
    }
}
