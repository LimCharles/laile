import Foundation
import Testing
@testable import LaileCore

@Suite struct ClassifierTests {
    @Test(arguments: [
        ("feels fine", SymptomCategory.normal),
        ("one two three four", .normal),
        ("no pain at all", .normal),
        ("it's pulling at the back of my knee", .expectedStretch),
        ("my thighs are burning", .effort),
        ("ow", .ambiguous),
        ("feels weird", .ambiguous),
        ("sharp pain on the inside of my knee", .pain),
        ("something clicked", .wrongSensation),
        ("my knee gave way", .wrongSensation),
        ("pins and needles in my foot", .wrongSensation),
        ("my calf is swollen and sore", .redFlag),
        ("I can't breathe properly", .redFlag),
    ])
    func classifies(_ text: String, _ expected: SymptomCategory) {
        #expect(UtteranceClassifier.classify(text).category == expected, "\(text)")
    }

    @Test func extractsDetails() {
        let r = UtteranceClassifier.classify("sharp pain inside my right knee, like a 6 out of 10")
        #expect(r.severity == 6)
        #expect(r.side == .right)
        #expect(r.quality == "sharp")
        #expect(r.bodyLocation == "inside of knee")
    }

    @Test func tiredCalfIsNotARedFlag() {
        // "tired" contains "red" — word-boundary matching must not trip the DVT rule.
        #expect(RedFlagDetector.detect("my calf feels tired") == nil)
    }

    @Test func severityParsing() {
        #expect(UtteranceClassifier.parseSeverity("about a six") == 6)
        #expect(UtteranceClassifier.parseSeverity("maybe 3") == 3)
        #expect(UtteranceClassifier.parseSeverity("one more rep") == nil)
    }

    @Test func medicationBoundary() {
        #expect(MedicationBoundary.isDoseQuestion("should I take another tablet before exercising?"))
        #expect(!MedicationBoundary.isDoseQuestion("what is this tablet for?"))
    }
}

@Suite struct SymptomRuleTests {
    @Test func painThresholdsFollowPolicy() {
        let policy = SymptomPolicy.rehabDefault
        func action(_ severity: Int) -> SymptomAction {
            SymptomRules.decide(SymptomReport(category: .pain, utterance: "pain", severity: severity, source: .tapped), policy: policy).action
        }
        #expect(action(3) == .continueExercise)
        #expect(action(5) == .stopSet)
        #expect(action(8) == .stopExercise)
    }

    @Test func moveModeIsStricter() {
        let r = SymptomReport(category: .pain, utterance: "pain", severity: 3, source: .tapped)
        #expect(SymptomRules.decide(r, policy: .moveDefault).action == .stopSet)
    }
}

@Suite struct ProgramSafetyTests {
    let library = ExerciseLibrary.standard

    @Test func nonWeightBearingBlocksSquats() {
        let precautions = Precautions(weightBearing: .none)
        let items = ["squat", "quad-set"].map { ProgramItem(exerciseId: $0, dose: Dose(sets: 2, reps: 10), source: .aiDraft) }
        let (kept, blocked) = ContraindicationChecker.sanitize(items: items, precautions: precautions)
        #expect(kept.map(\.exerciseId) == ["quad-set"])
        #expect(blocked.contains { $0.exerciseId == "squat" && $0.rule == "weight-bearing" })
    }

    @Test func hipPrecautionsBlockDeepHipFlexion() {
        let precautions = Precautions(maxHipFlexion: 90)
        #expect(!ContraindicationChecker.violations(spec: library.spec("deep-squat-hold")!, precautions: precautions).isEmpty)
        #expect(ContraindicationChecker.violations(spec: library.spec("glute-bridge")!, precautions: precautions).isEmpty)
    }

    @Test func unknownExercisesAndWildDosesAreCleaned() {
        let items = [
            ProgramItem(exerciseId: "backflip", dose: Dose(sets: 1, reps: 1), source: .aiDraft),
            ProgramItem(exerciseId: "heel-slide", dose: Dose(sets: 12, reps: 500), source: .aiDraft),
        ]
        let (kept, blocked) = ContraindicationChecker.sanitize(items: items, precautions: .none)
        #expect(blocked.map(\.exerciseId) == ["backflip"])
        #expect(kept[0].dose.sets == 3)
        #expect(kept[0].dose.reps == 20)
    }

    @Test func kneeCapLowersRepTargetNeverRaisesIt() {
        let heel = library.spec("heel-slide")!
        // Clinician goal 110°, but the precaution cap is 60°.
        let program = Program(title: "t", items: [ProgramItem(exerciseId: heel.id, dose: Dose(sets: 1, reps: 5), targetKneeFlexion: 110, source: .clinician)],
                              precautions: Precautions(maxKneeFlexion: 60), draftedBy: "test")
        let planned = program.plan()[0]
        #expect(planned.repRule?.target == 120) // interior 120° = 60° flexion

        let noCap = Program(title: "t", items: [ProgramItem(exerciseId: heel.id, dose: Dose(sets: 1, reps: 5), targetKneeFlexion: 110, source: .clinician)],
                            precautions: .none, draftedBy: "test")
        #expect(noCap.plan()[0].repRule?.target == 110) // default kept; 110° is a goal, not a rep bar
    }

    @Test func templateDraftForEarlyKneeReplacementIsSafe() {
        let context = PatientContext(displayName: "Test", procedure: .totalKneeReplacement,
                                     procedureDate: Date().addingTimeInterval(-10 * 86_400),
                                     precautions: Precautions(weightBearing: .partial, maxImpact: .low, affectedSide: .right))
        let program = TemplateDrafter.draft(context: context, patientId: nil)
        #expect(program.status == .draft)
        #expect(program.items.contains { $0.exerciseId == "heel-slide" })
        #expect(ContraindicationChecker.violations(program: program).isEmpty)
        #expect(program.title.contains("phase 1"))
    }

    @Test func llmDraftIsValidated() throws {
        let json = """
        {"title":"AI plan","summary":"s","items":[
          {"exerciseId":"heel-slide","sets":2,"reps":10,"targetKneeFlexion":130,"rationale":"bend"},
          {"exerciseId":"jumping-jacks","sets":2,"reps":20,"rationale":"cardio"},
          {"exerciseId":"made-up","sets":1,"reps":1,"rationale":"?"}]}
        """
        let draft = try LaileJSON.decoder().decode(ProgramDraftResponse.self, from: Data(json.utf8))
        let context = PatientContext(displayName: "T", procedure: .totalKneeReplacement,
                                     precautions: Precautions(maxKneeFlexion: 90, maxImpact: .low))
        let program = draft.toProgram(context: context, patientId: nil, draftedBy: "hunyuan")
        #expect(program.items.map(\.exerciseId) == ["heel-slide"])
        #expect(program.items[0].targetKneeFlexion == 90)
        #expect(Set(program.blockedSuggestions.map(\.exerciseId)) == ["jumping-jacks", "made-up"])
        #expect(program.status == .draft)
    }
}

@Suite struct InviteCodeTests {
    @Test func normalisesSmartDashesAndCase() {
        #expect(InviteCode.normalize("lai–demo42") == "LAI-DEMO42")
        #expect(InviteCode.normalize(" LAI — DEMO42 ") == "LAI-DEMO42")
        #expect(InviteCode.normalize("LAI-DEMO42") == "LAI-DEMO42")
    }
}

@Suite struct CueCatalogTests {
    /// Everything the conductor says in a scripted session should be pre-generatable,
    /// so a session plays entirely from high-quality bundled audio.
    @Test func conductorLinesAreAllInTheCatalog() {
        let catalog = Set(CueCatalog.all().map(\.audioKey))
        let plan = SessionTemplate.builtIn.flatMap { $0.plan() }
        var h = ConductorHarness(plan: Array(plan.prefix(3)))
        h.getReady()
        for _ in 0..<3 { h.rep() }
        let spoken = h.events.compactMap { event -> CueLine? in if case .say(let line) = event { return line }; return nil }
        let missing = spoken.filter { !catalog.contains($0.audioKey) }.map(\.text)
        #expect(missing.isEmpty, "Not pre-generatable: \(missing)")
    }

    @Test func keysAreStableAndDistinct() {
        #expect(CueLine("Hold it there.").audioKey == CueLine.holdIt.audioKey)
        #expect(CueLine.count(3).audioKey != CueLine.count(4).audioKey)
        let all = CueCatalog.all()
        #expect(all.count > 150)
    }
}

@Suite struct VoiceSubsetTests {
    @Test func sessionSubsetCoversWhatTheConductorSays() {
        let plan = Array(SessionTemplate.builtIn("knee-rehab-early")!.plan().prefix(3))
        let subset = Set(CueCatalog.lines(for: plan).map(\.audioKey))
        var h = ConductorHarness(plan: plan)
        h.getReady()
        for _ in 0..<3 { h.rep() }
        let spoken = h.events.compactMap { e -> CueLine? in if case .say(let l) = e { return l }; return nil }
        let missing = spoken.filter { !subset.contains($0.audioKey) }.map(\.text)
        #expect(missing.isEmpty, "Not prefetched: \(missing)")
        #expect(subset.count < CueCatalog.all().count)
    }
}
