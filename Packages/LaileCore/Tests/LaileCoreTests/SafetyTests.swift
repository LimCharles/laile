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

// MARK: - Negation

/// A denied symptom is not a symptom. These used to be escalated: "no chest pain" told the
/// person to call an ambulance, which is both frightening and the fastest way to make them
/// ignore the warning the next time it is real.
@Suite struct RedFlagNegationTests {
    @Test(arguments: [
        "no chest pain",
        "I don't have chest pain",
        "no, no chest pain, my knee's fine",
        "not dizzy",
        "I'm not dizzy",
        "no shortness of breath",
        "no fever",
        "my calf isn't swollen",
        "not passing out",
        "chest pain is gone",
        "no trouble breathing",
        "the wound isn't leaking",
    ])
    func denialIsNotARedFlag(_ text: String) {
        #expect(RedFlagDetector.detect(text) == nil, "\(text)")
    }

    /// Doubt must fall on keeping the flag. A negator that is not sitting right next to the
    /// symptom is not read as a denial.
    @Test(arguments: [
        "I had chest pain last week but I'm fine now",
        "the chest pain went away after I sat down, then my leg started hurting",
    ])
    func distantNegationKeepsTheRedFlag(_ text: String) {
        #expect(RedFlagDetector.detect(text) != nil, "\(text)")
    }

    /// A negator only counts when nothing but filler sits between it and the symptom, so an
    /// answer like "not good" in front of a real report does not cancel it.
    @Test(arguments: [
        "not good, chest pain",
        "not great, my chest is tight",
        "chest pain stopped me from finishing",
        "no idea why but my chest hurts",
    ])
    func unrelatedNegatorKeepsTheRedFlag(_ text: String) {
        #expect(RedFlagDetector.detect(text) != nil, "\(text)")
    }

    /// The clarify flow stitches the question and the answer into one utterance
    /// (SessionConductor.report), so a denial has to survive being appended to an earlier "ow".
    @Test func denialSurvivesTheMergedUtterance() {
        #expect(RedFlagDetector.detect("ow → no, no chest pain, it's just a pulled muscle") == nil)
    }

    /// "can't" is not a negator here on purpose: this sentence means the opposite of a denial.
    @Test func cantStopThePainStillEscalates() {
        #expect(RedFlagDetector.detect("I can't stop the pain in my chest")?.level == .emergency)
    }
}

// MARK: - Coverage

/// Phrasings that used to slip past the net. Everything here is a real report said a different way.
@Suite struct RedFlagCoverageTests {
    @Test(arguments: [
        // Chest: an inserted adverb or a different word form used to defeat the exact phrases.
        "my chest is really tight",
        "chest tightness",
        "my chest feels tight",
        "chest getting tight",
        "my chest is hurting",
        "pain in chest",
        "pain in the chest",
        "chest pressure",
        "my chest is heavy",
        // Fainting
        "I feel faint",
        "I feel like I'm going to pass out",
        "I might black out",
        // Breathing: apostrophe dropped by speech recognition, and non-"can't breathe" wordings.
        "cant breathe",
        "I can't catch my breath",
        // Stroke, bleeding
        "sudden severe headache",
        "my face is drooping",
        "I'm vomiting blood",
    ])
    func emergencyWordingIsEscalated(_ text: String) {
        #expect(RedFlagDetector.detect(text)?.level == .emergency, "\(text)")
    }

    @Test(arguments: [
        // Swelling: plurals used to be missed entirely.
        "my legs are swollen",
        "both legs swelling",
        "my calves are swollen",
        // Surgical site: people say incision, scar or stitches, not "wound".
        "my incision is leaking",
        "my scar is oozing",
        "my stitches opened",
        // Weight bearing: "can't bear weight" was the stated reason but never the matched phrase.
        "I can't bear weight on it",
        "I can't stand on my leg",
        // Other wordings
        "I've got vertigo",
        "I have a temperature",
        "my leg is cold and pale",
        // Falls
        "I just fell over",
        "I fell down the stairs",
    ])
    func careTeamTodayWordingIsEscalated(_ text: String) {
        #expect(RedFlagDetector.detect(text)?.level == .contactCareTeamToday, "\(text)")
    }

    /// Guards the proximity rules: word-boundary and synonym matching must not start firing on
    /// ordinary exercise talk. "tired" must not reach the "red" DVT rule, and a working muscle
    /// is not a swollen one.
    @Test(arguments: [
        "my calf feels tired",
        "my thighs are burning",
        "my legs are heavy",
        "pins and needles in my foot",
        "it's pulling at the back of my knee",
        "let me catch my breath",
        "I'm breathing hard",
        "I heard a faint click in my knee",
        // Normal after jumping jacks or high knees.
        "my heart is racing",
        "my heart is pounding",
        "I'm a bit breathless",
        "I'm gasping",
        // Muscles that worked, not a clot.
        "my legs feel warm",
        "my thighs are tender",
        // Not falls.
        "I fell asleep before my session",
        "my foot slipped a bit",
        "my knee keeps falling in",
    ])
    func ordinaryExerciseTalkIsStillNotARedFlag(_ text: String) {
        #expect(RedFlagDetector.detect(text) == nil, "\(text)")
    }
}

// MARK: - Wrong sensations vs. a denial of pain

/// A denial of pain used to short-circuit the whole classifier, so numbness, clicking and
/// giving way were answered with "carry on". Mechanical and neurological signs come first now.
@Suite struct WrongSensationOutranksDenialTests {
    @Test(arguments: [
        "no pain but my foot is numb",
        "no pain, my knee gave way",
        "not sore, just numb",
        "no pain but I have pins and needles",
    ])
    func denialDoesNotHideAWrongSensation(_ text: String) {
        let report = UtteranceClassifier.classify(text)
        #expect(report.category == .wrongSensation, "\(text) → \(report.category)")
        #expect(SymptomRules.decide(report, policy: .rehabDefault).action == .stopExercise, "\(text)")
    }

    /// "has gone numb" is also caught by the new loss-of-sensation red flag, which lands one
    /// step higher than stopping the exercise. Numbness reaching the care team today is the
    /// better outcome, so this is asserted rather than treated as a regression.
    @Test func newNumbnessIsEscalatedFurtherThanStoppingTheExercise() {
        let report = UtteranceClassifier.classify("no pain but my foot has gone numb")
        #expect(report.category == .redFlag)
        #expect(SymptomRules.decide(report, policy: .rehabDefault).action == .endSession(.contactCareTeamToday))
    }

    @Test func plainDenialIsStillNormal() {
        #expect(UtteranceClassifier.classify("no pain at all").category == .normal)
        #expect(UtteranceClassifier.classify("my knee gave way").category == .wrongSensation)
    }
}

// MARK: - Escalation level

@Suite struct RedFlagEscalationTests {
    /// A classifier can call something a red flag in wording our keyword net does not carry.
    /// It must still be able to reach the emergency level rather than being capped at
    /// "contact the care team today".
    @Test(arguments: [
        "there's a pressure on my chest",
        "my chest feels like an elephant is sitting on it",
        "a tightness across my chest and into my jaw",
    ])
    func classifierRedFlagReachesEmergency(text: String) {
        let report = SymptomReport(category: .redFlag, utterance: text, source: .voiceLLM)
        let decision = SymptomRules.decide(report, policy: .rehabDefault)
        #expect(decision.action == .endSession(.emergency), "\(text)")
    }

    /// A red flag that is not about an emergency subject stays a same-day matter.
    @Test func classifierRedFlagOnACalfStaysSameDay() {
        let report = SymptomReport(category: .redFlag, utterance: "it's throbbing and hot behind my knee", source: .voiceLLM)
        #expect(SymptomRules.decide(report, policy: .rehabDefault).action == .endSession(.contactCareTeamToday))
    }
}

// MARK: - Pain thresholds

@Suite struct PainThresholdTests {
    /// A clinician can set painStopSetAbove to 9. Without clamping, the server built a policy
    /// whose stop-exercise threshold was 11 — unreachable on a 0-10 scale — so the worst pain
    /// a person can report only stopped the set.
    @Test func maximumPainStopsTheExerciseOnBothPaths() {
        let report = SymptomReport(category: .pain, utterance: "pain", severity: 10, source: .tapped)

        let server = SymptomPolicy(painStopSetAbove: 9, painStopExerciseAt: min(10, max(9 + 2, 6)), mode: .rehab)
        #expect(server.painStopExerciseAt <= 10)
        #expect(SymptomRules.decide(report, policy: server).action == .stopExercise)

        let client = Program(title: "t", items: [], precautions: .none, painStopSetAbove: 9, draftedBy: "test").symptomPolicy
        #expect(SymptomRules.decide(report, policy: client).action == .stopExercise)
    }
}

// MARK: - Known limitations

/// Pinned so the gaps stay visible in the test run. These are findings from the safety audit
/// that were not part of this change; the tests should be deleted as each one is fixed.
@Suite struct KnownLimitationTests {
    /// The rating parser takes the first 0-10 number and only skips "more/rep/reps/second/
    /// seconds", so a set count spoken before the rating wins.
    @Test(arguments: [
        ("I've done three sets and the pain is about eight", 3),
        ("two sets in, it's a 9", 2),
        ("I'd say three, no wait it's an eight", 3),
    ])
    func leadingSetCountIsMistakenForTheRating(_ text: String, _ parsed: Int) {
        #expect(UtteranceClassifier.parseSeverity(text) == parsed, "\(text)")
    }

    /// The `wrong` word list carries "click/clicking/clicked" but not the third-person forms,
    /// so "it clicks" is still heard as a denial of pain.
    @Test(arguments: ["doesn't hurt but it clicks", "no pain, it pops"])
    func inflectedWrongSensationVerbsAreStillMissed(_ text: String) {
        #expect(UtteranceClassifier.classify(text).category == .normal, "\(text)")
    }

    /// A rating the parser does get right.
    @Test(arguments: [("about a six", 6), ("maybe 3", 3), ("my knee hurts at 8", 8)])
    func ratingsThatParseCorrectly(_ text: String, _ expected: Int) {
        #expect(UtteranceClassifier.parseSeverity(text) == expected, "\(text)")
    }

    /// A "pulling" report has no stop-exercise tier, so 10/10 only ever stops the set.
    @Test func expectedStretchNeverStopsTheExercise() {
        let report = SymptomReport(category: .expectedStretch, utterance: "it is pulling", severity: 10, source: .tapped)
        #expect(SymptomRules.decide(report, policy: .rehabDefault).action == .stopSet)
    }

    /// Repeated reports are judged one at a time; there is no cumulative escalation yet.
    @Test func repeatedPainDoesNotEscalateOnItsOwn() {
        let report = SymptomReport(category: .pain, utterance: "it hurts", severity: 4, source: .tapped)
        #expect(SymptomRules.decide(report, policy: .rehabDefault).action == .continueExercise)
    }

    /// The keyword net is English-only and Chinese has no spaces to tokenise, so a Chinese
    /// utterance cannot match anything at all. Needs a CJK pattern set.
    @Test(arguments: ["胸痛", "我胸口疼", "我喘不过气", "头晕"])
    func chineseIsNotDetectedYet(_ text: String) {
        #expect(RedFlagDetector.detect(text) == nil, "\(text)")
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
