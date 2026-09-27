import Foundation
import Testing
@testable import LaileCore

/// Drives a conductor with synthetic frames at 20 fps.
struct ConductorHarness {
    var conductor: SessionConductor
    var t: TimeInterval = 0
    var events: [ConductorEvent] = []

    init(plan: [PlannedExercise], policy: SymptomPolicy = .rehabDefault) {
        conductor = SessionConductor(plan: plan, kind: .program, title: "Test", mode: .rehab,
                                     config: ConductorConfig(symptomPolicy: policy), startDate: Date(timeIntervalSince1970: 0), startTime: 0)
        events += conductor.start(at: 0)
    }

    mutating func feed(seconds: Double, angle: (Double) -> Double) {
        let end = t + seconds
        while t < end {
            t += 0.05
            events += conductor.process(sideFrame(t: t, kneeAngle: angle(t)))
        }
    }

    mutating func hold(_ angle: Double, seconds: Double) { feed(seconds: seconds) { _ in angle } }

    /// Hold still until setup + countdown finish and counting is live.
    mutating func getReady(angle: Double = 170) {
        var waited = 0.0
        while conductor.phase != .active && waited < 15 {
            hold(angle, seconds: 0.5)
            waited += 0.5
        }
    }

    /// One heel-slide style rep: straight → bent → straight over `duration` seconds.
    mutating func rep(from start: Double = 170, to bottom: Double = 100, duration: Double = 2) {
        let t0 = t
        feed(seconds: duration) { now in
            let phase = (now - t0) / duration
            let depth = phase < 0.5 ? phase * 2 : (1 - phase) * 2
            return start - (start - bottom) * depth
        }
    }

    var said: [String] { events.compactMap { if case .say(let line) = $0 { return line.text }; return nil } }
}

@Suite struct ConductorTests {
    let library = ExerciseLibrary.standard

    @Test func fullRepSessionProducesVerifiedSummary() throws {
        let heel = library.spec("heel-slide")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: heel, dose: Dose(sets: 2, reps: 3, restSeconds: 5))])
        h.getReady() // setup stabilises, countdown runs
        #expect(h.conductor.phase == .active)
        for _ in 0..<3 { h.rep() }
        // Now resting before set 2.
        if case .rest = h.conductor.phase {} else { Issue.record("expected rest, got \(h.conductor.phase)") }
        h.getReady()
        #expect(h.conductor.phase == .active)
        for _ in 0..<3 { h.rep(to: 95) }
        #expect(h.conductor.isFinished)

        let summary = h.conductor.summary()
        #expect(summary.exercises.count == 1)
        #expect(summary.exercises[0].repsPerSet == [3, 3])
        #expect(summary.verifiedReps == 6)
        let minAngle = try #require(summary.exercises[0].minAngle)
        #expect(minAngle < 105) // EMA smoothing trims the true 95° peak slightly
        #expect(h.said.contains("Two"))
        let samples = MetricExtractor.samples(from: summary, library: library)
        let flexion = try #require(samples.first { $0.kind == .kneeFlexion })
        #expect(flexion.value >= 75)
    }

    @Test func holdExerciseCountsAndRelaxes() {
        let quad = library.spec("quad-set")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: quad, dose: Dose(sets: 1, holdSeconds: 5, restSeconds: 5))])
        h.getReady(angle: 172)
        #expect(h.conductor.phase == .active)
        h.hold(172, seconds: 6)
        #expect(h.conductor.isFinished)
        #expect(h.conductor.summary().exercises[0].holdSecondsPerSet == [5])
        #expect(h.said.contains("And relax."))
    }

    @Test func holdPausesWhenKneeBends() {
        let quad = library.spec("quad-set")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: quad, dose: Dose(sets: 1, holdSeconds: 10, restSeconds: 5))])
        h.getReady(angle: 172)
        h.hold(172, seconds: 2)
        h.hold(140, seconds: 3) // knee bent → timer paused
        let held = h.conductor.snapshot.holdSeconds
        #expect(held < 3)
        #expect(h.said.contains { $0.contains("Press the back of your knee") })
    }

    @Test func ambiguousThenSharpPainStopsSet() {
        let heel = library.spec("heel-slide")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: heel, dose: Dose(sets: 2, reps: 10, restSeconds: 20))])
        h.getReady()
        h.rep()
        h.rep()

        h.events += h.conductor.report(UtteranceClassifier.classify("ow"), at: h.t)
        #expect(h.conductor.isClarifying)
        h.events += h.conductor.report(UtteranceClassifier.classify("sharp, inside of my knee"), at: h.t)
        #expect(h.conductor.isAwaitingPainRating)
        h.events += h.conductor.report(UtteranceClassifier.classify("about a six", awaitingRating: true), at: h.t)

        // 6 > rehab default 4 → set stopped, resting before set 2.
        if case .rest = h.conductor.phase {} else { Issue.record("expected rest, got \(h.conductor.phase)") }
        let summary = h.conductor.summary()
        let pain = summary.symptoms.last!
        #expect(pain.category == .pain)
        #expect(pain.severity == 6)
        #expect(pain.action == .stopSet)
        #expect(pain.exerciseId == "heel-slide")
        // "ow" → "sharp, inside of my knee" → "about a six" merge into one clinical event.
        #expect(summary.symptoms.count == 1)
        #expect(pain.bodyLocation == "inside of knee")
        #expect(pain.utterance.contains("ow") && pain.utterance.contains("six"))
        #expect(pain.clinicalSummary.contains("knee bent to"))
        #expect(h.conductor.snapshot.exerciseIndex == 0)
    }

    @Test func stretchSensationContinues() {
        let heel = library.spec("heel-slide")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: heel, dose: Dose(sets: 1, reps: 5))])
        h.getReady()
        h.events += h.conductor.report(UtteranceClassifier.classify("it's pulling behind my knee"), at: h.t)
        #expect(h.conductor.phase == .active)
        #expect(h.said.contains(SymptomResponses.acknowledgeStretch.text))
    }

    @Test func redFlagEndsSessionEvenIfMislabelled() {
        let heel = library.spec("heel-slide")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: heel, dose: Dose(sets: 1, reps: 5))])
        h.getReady()
        // Pretend the LLM wrongly called it "effort".
        let mislabelled = SymptomReport(category: .effort, utterance: "my chest hurts and I'm short of breath", source: .voiceLLM)
        h.events += h.conductor.report(mislabelled, at: h.t)
        #expect(h.conductor.isFinished)
        #expect(h.conductor.escalation == .emergency)
        #expect(h.said.contains { $0.contains("995") })
    }

    @Test func setupGuidanceSpokenWhenAnkleMissing() {
        let heel = library.spec("heel-slide")!
        var h = ConductorHarness(plan: [PlannedExercise(spec: heel, dose: Dose(sets: 1, reps: 5))])
        let end = h.t + 6
        while h.t < end {
            h.t += 0.05
            var frame = sideFrame(t: h.t, kneeAngle: 170)
            frame.landmarks[.leftAnkle] = nil
            h.events += h.conductor.process(frame)
        }
        #expect(h.conductor.phase == .setup)
        #expect(h.said.contains { $0.contains("can't see your ankle") })
        #expect(CueCatalog.all().contains { $0.text == CueCatalog.missing([.ankle]).text })
    }

    @Test func skipAndEnd() {
        let plan = ["heel-slide", "quad-set"].map { PlannedExercise(spec: library.spec($0)!, dose: Dose(sets: 1, reps: 5, holdSeconds: 5)) }
        var h = ConductorHarness(plan: plan)
        h.getReady()
        h.rep()
        h.events += h.conductor.skipExercise(at: h.t)
        #expect(h.conductor.snapshot.exerciseIndex == 1)
        h.events += h.conductor.endSession(at: h.t)
        let summary = h.conductor.summary()
        #expect(summary.exercises.map(\.stopReason) == [.skipped, .userEnded])
        #expect(summary.exercises[0].repsPerSet == [1])
    }
}
