import Foundation
import Testing
@testable import LaileCore

@Suite struct CareMemoryTests {
    let library = ExerciseLibrary.standard
    let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    func session(_ day: Int, exercises: [String], symptoms: [SymptomReport] = []) -> SessionSummary {
        let start = t0.addingTimeInterval(Double(day) * 86_400)
        let results = exercises.map { id -> ExerciseResult in
            var r = ExerciseResult(exerciseId: id, side: .right, plannedSets: 2)
            if library.spec(id)!.kind.isHold { r.holdSecondsPerSet = [5, 5] } else { r.repsPerSet = [10, 10] }
            return r
        }
        return SessionSummary(kind: .program, title: "Knee program", mode: .rehab, startedAt: start, endedAt: start.addingTimeInterval(900),
                              exercises: results, symptoms: symptoms)
    }

    func pain(_ severity: Int?, on exerciseId: String = "heel-slide", day: Int = 0, category: SymptomCategory = .pain) -> SymptomReport {
        SymptomReport(timestamp: t0.addingTimeInterval(Double(day) * 86_400 + 300), category: category,
                      utterance: "It's sore on the inside of my knee", bodyLocation: "inside of knee", side: .right,
                      quality: "sore", severity: severity, source: .voiceLLM, exerciseId: exerciseId, angle: 100)
    }

    @Test func soreExerciseGetsANoteAndAnEasierTargetNextTime() throws {
        let notes = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(6)]))
        let note = try #require(notes.first)
        #expect(notes.count == 1)
        #expect(note.kind == .soreSpot && note.exerciseId == "heel-slide" && note.severity == 6)
        #expect(note.adjustment?.rangeEase == 15)
        #expect(note.plainSummary == "Sore on the inside of your right knee (6/10)")

        let plan = [PlannedExercise(spec: library.spec("heel-slide")!, dose: Dose(sets: 2, reps: 10, restSeconds: 30))]
        let eased = CareMemory.adjust(plan, notes: notes)[0]
        #expect(eased.repRule?.target == 125) // 110 + 15: less bend needed to count a rep
        #expect(eased.careCue?.text.contains("inside of your right knee") == true)
    }

    @Test func mildPainIsRecordedButDoesNotChangeTheExercise() {
        #expect(CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(2)])).isEmpty)
        #expect(CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(nil, category: .effort)])).isEmpty)
    }

    @Test func holdsGetShorterNotRangeSmaller() throws {
        let notes = CareMemory.update([], after: session(0, exercises: ["plank"], symptoms: [pain(4, on: "plank")]))
        let plan = [PlannedExercise(spec: library.spec("plank")!, dose: Dose(sets: 2, holdSeconds: 40, restSeconds: 30))]
        let eased = CareMemory.adjust(plan, notes: notes)[0]
        #expect(eased.dose.holdSeconds == 30) // 75% of 40
        #expect(eased.repTargetOverride == nil)
    }

    @Test func easingNeverTakesMoreThanHalfTheRange() {
        var note = CareNote(createdAt: t0, kind: .soreSpot, source: .session, exerciseId: "mini-squat", text: "Sore",
                            adjustment: ExerciseAdjustment(rangeEase: 25, holdScale: 1))
        note.severity = 5
        let plan = [PlannedExercise(spec: library.spec("mini-squat")!, dose: Dose(sets: 2, reps: 10, restSeconds: 30))]
        // Mini squat range is 165 → 135 (30°), so at most 15° of ease.
        #expect(CareMemory.adjust(plan, notes: [note])[0].repRule?.target == 150)
    }

    @Test func recurringSorenessEasesMoreInsteadOfDuplicating() throws {
        let first = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(4)]))
        #expect(first[0].adjustment?.rangeEase == 10)
        let second = CareMemory.update(first, after: session(1, exercises: ["heel-slide"], symptoms: [pain(5, day: 1)]))
        let note = try #require(second.first)
        #expect(second.count == 1 && note.id == first[0].id)
        #expect(note.adjustment?.rangeEase == 15)
        #expect(note.severity == 5)
        #expect(note.events.count == 2)
    }

    @Test func comfortableSessionsEaseBackThenResolve() throws {
        var notes = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(4)]))
        var day = 1
        func run() {
            let changed = CareMemory.update(notes, after: session(day, exercises: ["heel-slide", "quad-set"]))
            for c in changed { notes.removeAll { $0.id == c.id }; notes.append(c) }
            day += 1
        }
        run()
        #expect(notes[0].comfortableSessions == 1 && notes[0].adjustment?.rangeEase == 10)
        run()
        #expect(notes[0].adjustment?.rangeEase == 5 && notes[0].comfortableSessions == 0)
        run(); run()
        #expect(notes[0].status == .resolved)
        #expect(notes[0].adjustment == nil)
        #expect(notes[0].events.last?.text.contains("back to the full heel slides") == true)
    }

    @Test func skippedOrStoppedExercisesDoNotCountAsComfortable() {
        let notes = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(4)]))
        #expect(CareMemory.update(notes, after: session(1, exercises: ["quad-set"])).isEmpty)
        var stopped = session(1, exercises: ["heel-slide"])
        stopped.exercises[0].stopReason = .skipped
        #expect(CareMemory.update(notes, after: stopped).isEmpty)
    }

    @Test func clinicianCanKeepAnExerciseEased() {
        var notes = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(4)]))
        notes[0].adjustment?.keptByClinician = true
        for day in 1...4 { #expect(CareMemory.update(notes, after: session(day, exercises: ["heel-slide"])).isEmpty) }
        #expect(CareMemory.markBetter(notes[0], at: t0) == nil)
    }

    @Test func feelsWrongIsItsOwnKind() throws {
        let report = pain(nil, category: .wrongSensation)
        let note = try #require(CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [report])).first)
        #expect(note.kind == .feelsWrong)
        #expect(CareMemory.cue(for: note).text.hasPrefix("Last time something felt wrong with this one"))
    }

    @Test func careCueIsSpokenAfterTheIntroduction() {
        let notes = CareMemory.update([], after: session(0, exercises: ["heel-slide"], symptoms: [pain(6)]))
        let plan = CareMemory.adjust([PlannedExercise(spec: library.spec("heel-slide")!, dose: Dose(sets: 1, reps: 5))], notes: notes)
        var conductor = SessionConductor(plan: plan, kind: .program, title: "Test", mode: .rehab, config: ConductorConfig(symptomPolicy: .rehabDefault),
                                         startDate: t0, startTime: 0)
        let said = conductor.start(at: 0).compactMap { event -> String? in
            if case .say(let line) = event { return line.text }
            return nil
        }
        #expect(said.count >= 3)
        #expect(said[1].hasPrefix("Last time this one was sore"))
        #expect(CueCatalog.lines(for: plan).contains(plan[0].careCue!))
    }
}
