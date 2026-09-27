import Foundation
import Testing
@testable import LaileCore

/// Builds a side-view frame whose knee (hip-knee-ankle) angle is exactly `kneeAngle`.
func sideFrame(t: TimeInterval, kneeAngle: Double, hipAngle: Double = 175, side: Side = .left, aspect: Double = 1) -> PoseFrame {
    // Lying supine, body along x. Hip at (0.5, 0.6); shoulder to the left.
    let hip = Point2(0.5, 0.6)
    let shoulder = pointFrom(hip, length: 0.25, degrees: 180)
    // Thigh direction chosen so the shoulder-hip-knee angle equals hipAngle.
    let thighDirection = 180 - hipAngle
    let knee = pointFrom(hip, length: 0.2, degrees: thighDirection)
    // Shin: rotate from the knee→hip direction by kneeAngle.
    let kneeToHip = atan2(hip.y - knee.y, hip.x - knee.x) * 180 / .pi
    let ankle = pointFrom(knee, length: 0.2, degrees: kneeToHip + kneeAngle)
    var lm: [Joint: Landmark] = [:]
    func put(_ part: BodyPart, _ p: Point2) {
        lm[Joint(part, side)] = Landmark(Point2(p.x / aspect, p.y), confidence: 0.9)
    }
    put(.shoulder, shoulder)
    put(.hip, hip)
    put(.knee, knee)
    put(.ankle, ankle)
    put(.elbow, Point2(shoulder.x + 0.05, shoulder.y + 0.05))
    put(.wrist, Point2(shoulder.x + 0.1, shoulder.y + 0.05))
    return PoseFrame(timestamp: t, landmarks: lm, imageAspect: aspect)
}

func pointFrom(_ origin: Point2, length: Double, degrees: Double) -> Point2 {
    let r = degrees * .pi / 180
    return Point2(origin.x + length * cos(r), origin.y + length * sin(r))
}

@Suite struct GeometryTests {
    @Test func rightAngle() {
        #expect(abs(Geometry.angle(Point2(1, 0), vertex: Point2(0, 0), Point2(0, 1)) - 90) < 1e-9)
    }

    @Test func frameAngleMatchesConstruction() {
        for target in stride(from: 60.0, through: 175, by: 15) {
            let frame = sideFrame(t: 0, kneeAngle: target)
            let measured = frame.angle(.knee, side: .left)!
            #expect(abs(measured - target) < 0.01)
        }
    }

    @Test func aspectCorrectionPreservesAngle() {
        // Same body in a portrait (9:16) frame: normalized x is squashed, angle must not be.
        let frame = sideFrame(t: 0, kneeAngle: 100, aspect: 9.0 / 16.0)
        #expect(abs(frame.angle(.knee, side: .left)! - 100) < 0.01)
    }
}

@Suite struct RepCounterTests {
    let heelSlide = RepRule(angle: .knee, start: 160, target: 110)

    @Test func countsFullRepsAndPeak() {
        var counter = RepCounter(rule: heelSlide)
        var reps: [RepEvent] = []
        for _ in 0..<3 {
            for a in stride(from: 170.0, through: 100, by: -5) { if let e = counter.update(angle: a) { reps.append(e) } }
            for a in stride(from: 100.0, through: 170, by: 5) { if let e = counter.update(angle: a) { reps.append(e) } }
        }
        #expect(counter.count == 3)
        #expect(reps.last == .rep(count: 3, peakAngle: 100))
    }

    @Test func partialRepNotCounted() {
        var counter = RepCounter(rule: heelSlide)
        _ = counter.update(angle: 170)
        var events: [RepEvent] = []
        for a in [150.0, 135, 130, 135, 150, 165] { if let e = counter.update(angle: a) { events.append(e) } }
        #expect(counter.count == 0)
        #expect(counter.partials == 1)
        if case .partial(let peak, _) = events.first { #expect(peak == 130) } else { Issue.record("expected partial") }
    }

    @Test func worksForStraighteningDirection() {
        var counter = RepCounter(rule: RepRule(angle: .hip, start: 135, target: 160))
        for a in [130.0, 140, 150, 162, 150, 138, 130] { counter.update(angle: a) }
        #expect(counter.count == 1)
    }

    @Test func jitterAtStartDoesNotCount() {
        var counter = RepCounter(rule: heelSlide)
        for a in [170.0, 158, 166, 157, 168, 160, 170] { counter.update(angle: a) }
        #expect(counter.count == 0 && counter.partials == 0)
    }
}

@Suite struct HoldTimerTests {
    @Test func accumulatesAndCompletes() {
        var timer = HoldTimer(targetSeconds: 3)
        var crossed: [Int] = []
        var completed = false
        var t = 0.0
        while t <= 4 {
            let u = timer.update(satisfied: true, at: t)
            crossed += u.crossedSeconds
            completed = completed || u.completed
            t += 0.1
        }
        #expect(crossed == [1, 2, 3])
        #expect(completed)
    }

    @Test func briefDropoutIsForgiven() {
        var timer = HoldTimer(targetSeconds: 10)
        var t = 0.0
        for i in 0..<30 {
            // One 0.2s dropout in the middle.
            _ = timer.update(satisfied: !(i == 10 || i == 11), at: t)
            t += 0.1
        }
        #expect(timer.heldSeconds > 2.8)
    }

    @Test func longDropoutPauses() {
        var timer = HoldTimer(targetSeconds: 10)
        var t = 0.0
        for _ in 0..<10 { _ = timer.update(satisfied: true, at: t); t += 0.1 }
        let held = timer.heldSeconds
        for _ in 0..<20 { _ = timer.update(satisfied: false, at: t); t += 0.1 }
        #expect(timer.heldSeconds - held < 0.6)
    }
}

@Suite struct SetupCheckTests {
    @Test func readyWhenPartsVisibleSideOn() {
        let spec = ExerciseLibrary.standard.spec("heel-slide")!
        let status = SetupCheck.evaluate(sideFrame(t: 0, kneeAngle: 170), spec: spec, preferredSide: nil)
        #expect(status.isReady, "issues: \(status.issues)")
        #expect(status.side == .left)
    }

    @Test func reportsMissingAnkle() {
        let spec = ExerciseLibrary.standard.spec("heel-slide")!
        var frame = sideFrame(t: 0, kneeAngle: 170)
        frame.landmarks[.leftAnkle] = nil
        let status = SetupCheck.evaluate(frame, spec: spec, preferredSide: .left)
        #expect(!status.isReady)
        #expect(status.issues.contains(.partsNotVisible([.ankle])))
    }

    @Test func noPerson() {
        let spec = ExerciseLibrary.standard.spec("squat")!
        let status = SetupCheck.evaluate(PoseFrame(timestamp: 0, landmarks: [:], imageAspect: 1), spec: spec, preferredSide: nil)
        #expect(status.issues == [.noPerson])
    }
}
