import Foundation

/// The vetted exercise catalog. Programs — whether written by a clinician, drafted by the AI,
/// or built from a template — may only reference exercises that exist here.
public struct ExerciseLibrary: Sendable {
    public let all: [ExerciseSpec]
    private let byId: [String: ExerciseSpec]

    public init(_ specs: [ExerciseSpec]) {
        all = specs
        byId = Dictionary(specs.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    public func spec(_ id: String) -> ExerciseSpec? { byId[id] }

    public func specs(for mode: AppMode) -> [ExerciseSpec] { all.filter { $0.modes.contains(mode) } }

    public func family(_ name: String) -> [ExerciseSpec] {
        all.filter { $0.family == name }.sorted { ($0.familyLevel ?? 0) < ($1.familyLevel ?? 0) }
    }

    public static let standard = ExerciseLibrary(BuiltInExercises.all)
}

enum BuiltInExercises {
    static let all: [ExerciseSpec] = rehab + move

    // MARK: Rehab (knee/hip replacement home programs)

    static let rehab: [ExerciseSpec] = [
        ExerciseSpec(
            id: "ankle-pumps", name: "Ankle pumps", modes: [.rehab], category: .circulation,
            posture: .supine, cameraView: .any, kind: .hold(.presenceOnly),
            defaultDose: Dose(sets: 1, holdSeconds: 45, restSeconds: 10),
            limits: DoseLimits(sets: 1...3, holdSeconds: 20...120),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0),
            cues: ExerciseCues(
                purpose: "Pumping your ankles keeps blood moving in your legs, which helps prevent clots after surgery.",
                setup: "Lie on your back with your legs straight.",
                go: "Point your toes away, then pull them back towards you. Keep a steady rhythm."
            ),
            intensity: 1
        ),
        ExerciseSpec(
            id: "quad-set", name: "Quad set", modes: [.rehab], category: .strength,
            posture: .supine, cameraView: .side,
            kind: .hold(HoldRule(angle: .knee, condition: .atLeast(165), correction: "Press the back of your knee down into the bed to keep the timer going.")),
            defaultDose: Dose(sets: 10, holdSeconds: 5, restSeconds: 5),
            limits: DoseLimits(sets: 3...15, holdSeconds: 3...10, restSeconds: 3...30),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0),
            cues: ExerciseCues(
                purpose: "Tightening your thigh muscle wakes it up and helps your knee get fully straight again.",
                setup: "Lie on your back, legs straight, with your side facing the phone.",
                go: "Tighten your thigh and push the back of your knee down."
            ),
            metric: MetricBinding(.kneeExtensionDeficit, .extensionDeficitFromMaxAngle),
            intensity: 1
        ),
        ExerciseSpec(
            id: "heel-slide", name: "Heel slides", modes: [.rehab], category: .mobility,
            posture: .supine, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 160, target: 110)),
            defaultDose: Dose(sets: 2, reps: 10, restSeconds: 30),
            limits: DoseLimits(sets: 1...3, reps: 5...20),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 60),
            cues: ExerciseCues(
                purpose: "Sliding your heel towards you gently stretches your new knee so it can bend enough for chairs and stairs.",
                setup: "Lie on your back with the side of your operated leg facing the phone.",
                go: "Slide your heel up towards your bottom, as far as is comfortable, then slide it back."
            ),
            metric: MetricBinding(.kneeFlexion, .peakFlexionFromMinAngle),
            intensity: 1
        ),
        ExerciseSpec(
            id: "straight-leg-raise", name: "Straight-leg raise", modes: [.rehab], category: .strength,
            posture: .supine, cameraView: .side,
            kind: .reps(RepRule(angle: .hip, start: 170, target: 145)),
            formChecks: [FormCheck(id: "knee-straight", angle: .knee, condition: .atLeast(155), cue: "Keep your knee straight as you lift.")],
            defaultDose: Dose(sets: 2, reps: 10, restSeconds: 30),
            limits: DoseLimits(sets: 1...3, reps: 5...15),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 40),
            cues: ExerciseCues(
                purpose: "Lifting a straight leg strengthens your thigh so your knee feels steady when you walk.",
                setup: "Lie on your back. Bend your other knee and keep the operated leg straight.",
                go: "Tighten your thigh, lift the straight leg to the height of your other knee, then lower slowly."
            ),
            metric: MetricBinding(.straightLegRaiseReps, .bestSetReps),
            intensity: 2
        ),
        ExerciseSpec(
            id: "long-arc-quad", name: "Seated knee straightening", modes: [.rehab], category: .strength,
            posture: .seated, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 110, target: 160)),
            defaultDose: Dose(sets: 2, reps: 10, restSeconds: 30),
            limits: DoseLimits(sets: 1...3, reps: 5...15),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 90),
            cues: ExerciseCues(
                purpose: "Straightening your knee while seated builds the thigh strength you need to stand up.",
                setup: "Sit on a firm chair with your side facing the phone.",
                go: "Straighten your knee until your leg is level, pause, then lower slowly."
            ),
            intensity: 2
        ),
        ExerciseSpec(
            id: "sit-to-stand", name: "Sit-to-stand", modes: [.rehab, .move], category: .strength,
            posture: .seated, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 110, target: 155)),
            defaultDose: Dose(sets: 2, reps: 8, restSeconds: 45),
            limits: DoseLimits(sets: 1...4, reps: 5...20),
            loads: ExerciseLoads(weightBearing: true, impact: .low, peakKneeFlexion: 95, peakHipFlexion: 95),
            cues: ExerciseCues(
                purpose: "Standing up from a chair is the everyday strength move — it's what keeps you independent.",
                setup: "Sit near the front of a sturdy chair, side-on to the phone, feet flat.",
                go: "Lean forward, stand all the way up, then sit back down slowly."
            ),
            metric: MetricBinding(.sitToStandReps, .bestSetReps),
            intensity: 2
        ),
        ExerciseSpec(
            id: "mini-squat", name: "Mini squat", modes: [.rehab], category: .strength,
            posture: .standing, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 165, target: 135)),
            defaultDose: Dose(sets: 2, reps: 10, restSeconds: 45),
            limits: DoseLimits(sets: 1...3, reps: 5...15),
            loads: ExerciseLoads(weightBearing: true, impact: .low, peakKneeFlexion: 45, peakHipFlexion: 45),
            cues: ExerciseCues(
                purpose: "A small squat while holding a counter builds leg strength without asking too much of your knee.",
                setup: "Stand side-on to the phone holding a counter or sturdy chair back.",
                go: "Bend your knees a little, as if starting to sit, then stand tall."
            ),
            intensity: 2
        ),
    ]

    // MARK: Move (calisthenics + stretching for people with no time)

    static let move: [ExerciseSpec] = [
        ExerciseSpec(
            id: "squat", name: "Bodyweight squat", modes: [.move], category: .strength,
            posture: .standing, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 160, target: 100)),
            defaultDose: Dose(sets: 3, reps: 12, restSeconds: 45),
            limits: DoseLimits(sets: 1...5, reps: 5...40),
            loads: ExerciseLoads(weightBearing: true, impact: .low, peakKneeFlexion: 100, peakHipFlexion: 100),
            cues: ExerciseCues(
                purpose: "Squats train the biggest muscles you have — the fastest way to get strong legs.",
                setup: "Stand side-on to the phone, feet shoulder-width apart.",
                go: "Sit your hips back and down until your thighs are about level, then drive up."
            ),
            metric: MetricBinding(.squatReps, .bestSetReps),
            intensity: 2, family: "squat", familyLevel: 2
        ),
        ExerciseSpec(
            id: "incline-push-up", name: "Incline push-up", modes: [.move], category: .strength,
            posture: .plank, cameraView: .side,
            kind: .reps(RepRule(angle: .elbow, start: 150, target: 100)),
            formChecks: [FormCheck(id: "body-line", angle: .bodyLine, condition: .atLeast(155), cue: "Keep your hips in line with your shoulders.")],
            defaultDose: Dose(sets: 3, reps: 10, restSeconds: 45),
            limits: DoseLimits(sets: 1...5, reps: 5...30),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0, loadsWrists: true),
            cues: ExerciseCues(
                purpose: "Push-ups against a table or counter build chest and arm strength at an easier angle.",
                setup: "Hands on a counter or sturdy table, body straight, side-on to the phone.",
                go: "Lower your chest towards your hands, then push away."
            ),
            metric: MetricBinding(.pushUpReps, .bestSetReps),
            intensity: 1, family: "push-up", familyLevel: 1
        ),
        ExerciseSpec(
            id: "knee-push-up", name: "Knee push-up", modes: [.move], category: .strength,
            posture: .plank, cameraView: .side,
            kind: .reps(RepRule(angle: .elbow, start: 150, target: 100)),
            formChecks: [FormCheck(id: "body-line", angle: .hip, condition: .atLeast(150), cue: "Keep a straight line from your knees to your shoulders.")],
            defaultDose: Dose(sets: 3, reps: 8, restSeconds: 45),
            limits: DoseLimits(sets: 1...5, reps: 3...30),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 0, loadsWrists: true),
            cues: ExerciseCues(
                purpose: "Push-ups from your knees are the stepping stone to full push-ups.",
                setup: "Hands on the floor under your shoulders, knees down, side-on to the phone.",
                go: "Lower your chest to the floor, then press back up."
            ),
            metric: MetricBinding(.pushUpReps, .bestSetReps),
            intensity: 2, family: "push-up", familyLevel: 2
        ),
        ExerciseSpec(
            id: "push-up", name: "Push-up", modes: [.move], category: .strength,
            posture: .plank, cameraView: .side,
            kind: .reps(RepRule(angle: .elbow, start: 150, target: 95)),
            formChecks: [FormCheck(id: "body-line", angle: .bodyLine, condition: .atLeast(155), cue: "Keep your hips in line — no sagging.")],
            defaultDose: Dose(sets: 3, reps: 8, restSeconds: 60),
            limits: DoseLimits(sets: 1...5, reps: 3...50),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0, loadsWrists: true),
            cues: ExerciseCues(
                purpose: "The classic: chest, shoulders, arms and core in one move.",
                setup: "Hands under shoulders, body in a straight line, side-on to the phone.",
                go: "Lower until your elbows are at a right angle, then press up."
            ),
            metric: MetricBinding(.pushUpReps, .bestSetReps),
            intensity: 3, family: "push-up", familyLevel: 3
        ),
        ExerciseSpec(
            id: "plank", name: "Plank", modes: [.move], category: .strength,
            posture: .plank, cameraView: .side,
            kind: .hold(HoldRule(angle: .bodyLine, condition: .atLeast(155), correction: "Lift your hips back in line to keep the timer running.")),
            defaultDose: Dose(sets: 2, holdSeconds: 30, restSeconds: 30),
            limits: DoseLimits(sets: 1...4, holdSeconds: 10...180),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0, loadsWrists: true),
            cues: ExerciseCues(
                purpose: "Holding a plank builds the core strength that protects your back.",
                setup: "Forearms on the floor, body straight from head to heels, side-on to the phone.",
                go: "Brace your stomach and hold a straight line."
            ),
            metric: MetricBinding(.plankHoldSeconds, .bestSetHoldSeconds),
            intensity: 2
        ),
        ExerciseSpec(
            id: "glute-bridge", name: "Glute bridge", modes: [.move, .rehab], category: .strength,
            posture: .supine, cameraView: .side,
            kind: .reps(RepRule(angle: .hip, start: 135, target: 160)),
            defaultDose: Dose(sets: 3, reps: 12, restSeconds: 30),
            limits: DoseLimits(sets: 1...4, reps: 5...25),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 45),
            cues: ExerciseCues(
                purpose: "Bridges wake up your glutes, which take pressure off your knees and lower back.",
                setup: "Lie on your back, knees bent, feet flat, side-on to the phone.",
                go: "Squeeze your glutes and lift your hips until your body is straight, then lower."
            ),
            metric: MetricBinding(.gluteBridgeReps, .bestSetReps),
            intensity: 1
        ),
        ExerciseSpec(
            id: "wall-sit", name: "Wall sit", modes: [.move], category: .strength,
            posture: .seated, cameraView: .side,
            kind: .hold(HoldRule(angle: .knee, condition: .between(75, 120), correction: "Slide down until your knees are close to a right angle.")),
            defaultDose: Dose(sets: 2, holdSeconds: 30, restSeconds: 45),
            limits: DoseLimits(sets: 1...4, holdSeconds: 10...120),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 100, peakHipFlexion: 90),
            cues: ExerciseCues(
                purpose: "A wall sit builds leg endurance with zero impact.",
                setup: "Back against a wall, side-on to the phone.",
                go: "Slide down until your knees are about at a right angle, and hold."
            ),
            metric: MetricBinding(.wallSitSeconds, .bestSetHoldSeconds),
            intensity: 3
        ),
        ExerciseSpec(
            id: "reverse-lunge", name: "Reverse lunge", modes: [.move], category: .strength,
            posture: .standing, cameraView: .side,
            kind: .reps(RepRule(angle: .knee, start: 160, target: 105)),
            defaultDose: Dose(sets: 2, reps: 10, restSeconds: 45),
            limits: DoseLimits(sets: 1...4, reps: 4...20),
            loads: ExerciseLoads(weightBearing: true, impact: .low, peakKneeFlexion: 90, peakHipFlexion: 90),
            cues: ExerciseCues(
                purpose: "Lunges build single-leg strength and balance.",
                setup: "Stand tall, side-on to the phone.",
                go: "Step one foot back and lower until your front knee is bent to a right angle, then step back up."
            ),
            intensity: 3, perSide: true
        ),
        ExerciseSpec(
            id: "jumping-jacks", name: "Jumping jacks", modes: [.move], category: .cardio,
            posture: .standing, cameraView: .front,
            kind: .reps(RepRule(angle: .armRaise, start: 40, target: 140, partialFraction: 0.6)),
            defaultDose: Dose(sets: 2, reps: 20, restSeconds: 20),
            limits: DoseLimits(sets: 1...5, reps: 10...60),
            loads: ExerciseLoads(weightBearing: true, impact: .high, peakKneeFlexion: 20, peakHipFlexion: 10),
            cues: ExerciseCues(
                purpose: "A quick burst to get your heart rate up.",
                setup: "Face the phone, with your whole body in view.",
                go: "Jump your feet out and swing your arms overhead, then back in."
            ),
            metric: MetricBinding(.jumpingJackReps, .bestSetReps),
            intensity: 3
        ),
        ExerciseSpec(
            id: "high-knees", name: "High knees", modes: [.move], category: .cardio,
            posture: .standing, cameraView: .side,
            kind: .reps(RepRule(angle: .hip, start: 165, target: 115, partialFraction: 0.6)),
            defaultDose: Dose(sets: 2, reps: 20, restSeconds: 20),
            limits: DoseLimits(sets: 1...5, reps: 10...60),
            loads: ExerciseLoads(weightBearing: true, impact: .moderate, peakKneeFlexion: 90, peakHipFlexion: 80),
            cues: ExerciseCues(
                purpose: "Fast cardio you can do in a small space.",
                setup: "Stand side-on to the phone.",
                go: "March or jog on the spot, bringing your knees up high."
            ),
            intensity: 3
        ),
        ExerciseSpec(
            id: "deep-squat-hold", name: "Deep squat hold", modes: [.move], category: .mobility,
            posture: .standing, cameraView: .side,
            kind: .hold(HoldRule(angle: .knee, condition: .atMost(95), correction: "Sink a little lower, only as far as feels comfortable.")),
            defaultDose: Dose(sets: 2, holdSeconds: 30, restSeconds: 20),
            limits: DoseLimits(sets: 1...3, holdSeconds: 15...90),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 120, peakHipFlexion: 110),
            cues: ExerciseCues(
                purpose: "Resting in a deep squat undoes hours of sitting at a desk.",
                setup: "Stand side-on to the phone, feet a bit wider than your hips.",
                go: "Sink down into a comfortable deep squat and breathe."
            ),
            intensity: 2
        ),
        ExerciseSpec(
            id: "hamstring-stretch", name: "Hamstring stretch", modes: [.move, .rehab], category: .stretch,
            posture: .standing, cameraView: .any, kind: .hold(.presenceOnly),
            defaultDose: Dose(sets: 2, holdSeconds: 30, restSeconds: 10),
            limits: DoseLimits(sets: 1...3, holdSeconds: 15...60),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 70),
            cues: ExerciseCues(
                purpose: "Loosens the back of your thighs, which tighten up with sitting.",
                setup: "Put one heel on a low step with the leg straight.",
                go: "Lean forward from your hips until you feel a gentle stretch. Breathe."
            ),
            intensity: 1, perSide: true
        ),
        ExerciseSpec(
            id: "hip-flexor-stretch", name: "Hip flexor stretch", modes: [.move], category: .stretch,
            posture: .kneeling, cameraView: .any, kind: .hold(.presenceOnly),
            defaultDose: Dose(sets: 2, holdSeconds: 30, restSeconds: 10),
            limits: DoseLimits(sets: 1...3, holdSeconds: 15...60),
            loads: ExerciseLoads(weightBearing: true, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 90),
            cues: ExerciseCues(
                purpose: "Opens up the front of your hips after long hours in a chair.",
                setup: "Kneel on one knee with the other foot in front.",
                go: "Tuck your tailbone under and shift forward gently. Breathe."
            ),
            intensity: 1, perSide: true
        ),
        ExerciseSpec(
            id: "chest-opener", name: "Chest opener", modes: [.move, .rehab], category: .stretch,
            posture: .standing, cameraView: .any, kind: .hold(.presenceOnly),
            defaultDose: Dose(sets: 1, holdSeconds: 30, restSeconds: 10),
            limits: DoseLimits(sets: 1...3, holdSeconds: 15...60),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 0, peakHipFlexion: 0),
            cues: ExerciseCues(
                purpose: "Undoes the hunched-over-a-phone posture.",
                setup: "Stand or sit tall, hands clasped behind your back.",
                go: "Squeeze your shoulder blades together and lift your chest. Breathe."
            ),
            intensity: 1
        ),
        ExerciseSpec(
            id: "neck-shoulder-rolls", name: "Neck and shoulder rolls", modes: [.move, .rehab], category: .stretch,
            posture: .seated, cameraView: .any, kind: .hold(.presenceOnly),
            defaultDose: Dose(sets: 1, holdSeconds: 30, restSeconds: 5),
            limits: DoseLimits(sets: 1...2, holdSeconds: 15...60),
            loads: ExerciseLoads(weightBearing: false, impact: .none, peakKneeFlexion: 90, peakHipFlexion: 90),
            cues: ExerciseCues(
                purpose: "Releases desk tension in your neck and shoulders.",
                setup: "Sit tall in your chair, facing the phone.",
                go: "Roll your shoulders slowly backwards, then gently tilt your ear to each shoulder."
            ),
            intensity: 1
        ),
    ]
}
