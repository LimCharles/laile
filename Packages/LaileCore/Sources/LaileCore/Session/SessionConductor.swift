import Foundation

public enum PauseReason: Sendable, Equatable {
    case user
    /// Asked "stretching or sharp?" and waiting for the answer.
    case clarifying
    /// Asked for a 0–10 pain rating and waiting for the answer.
    case awaitingPainRating
}

public enum ConductorPhase: Sendable, Equatable {
    case setup
    case countdown(remaining: Int)
    case active
    case rest(until: TimeInterval)
    case paused(PauseReason)
    case finished
}

public enum ConductorEvent: Sendable, Equatable {
    case phaseChanged(ConductorPhase)
    case say(CueLine)
    case setupStatus(SetupStatus)
    case repCompleted(count: Int, peakAngle: Double)
    case partialRep(peakAngle: Double)
    case holdProgress(seconds: Int, target: Int)
    case formWarning(checkId: String, message: String)
    case trackingLost
    case setCompleted(exerciseIndex: Int, setIndex: Int)
    case exerciseCompleted(ExerciseResult)
    case symptomLogged(SymptomReport)
    case sessionCompleted(SessionSummary)
}

public struct ConductorConfig: Sendable {
    public var symptomPolicy: SymptomPolicy
    /// Default for `report(_:at:speakResponse:)`. Escalation lines are always spoken.
    public var speaksSymptomResponses: Bool
    public var setupStableSeconds: Double = 1.0
    public var trackingLostSeconds: Double = 2.0
    public var formCueCooldown: Double = 5.0
    public var setupCueCooldown: Double = 5.0
    public var minConfidence: Double = PoseFrame.defaultMinConfidence

    public init(symptomPolicy: SymptomPolicy, speaksSymptomResponses: Bool = true) {
        self.symptomPolicy = symptomPolicy
        self.speaksSymptomResponses = speaksSymptomResponses
    }
}

/// What the UI needs to render the current moment of a session.
public struct ConductorSnapshot: Sendable, Equatable {
    public var phase: ConductorPhase
    public var exerciseIndex: Int
    public var exerciseCount: Int
    public var exerciseId: String?
    public var exerciseName: String
    public var setIndex: Int
    public var totalSets: Int
    public var isHold: Bool
    public var reps: Int
    public var targetReps: Int?
    public var holdSeconds: Double
    public var targetHoldSeconds: Int?
    public var isHolding: Bool
    public var angle: Double?
    public var repProgress: Double
    public var setupIssues: [SetupIssue]
    public var side: Side?
    public var restRemaining: Int?
}

/// The deterministic heart of a session: turns pose frames and elapsed time into counted
/// reps, hold timers, spoken cues and a verified summary. No LLM decides anything here.
///
/// Drive it with `process(_:)` for every pose frame and `tick(at:)` on a timer (for
/// countdowns and rests when no frames arrive). Both return events for the UI and voice.
public struct SessionConductor: Sendable {
    public let plan: [PlannedExercise]
    public let kind: SessionSummary.Kind
    public let title: String
    public let mode: AppMode
    public var config: ConductorConfig
    public var programId: UUID?
    public var templateId: String?
    public var streamId: UUID?

    public private(set) var phase: ConductorPhase = .setup
    public private(set) var exerciseIndex = 0
    public private(set) var setIndex = 0
    public private(set) var results: [ExerciseResult] = []
    public private(set) var symptoms: [SymptomReport] = []
    public private(set) var escalation: EscalationLevel?
    public private(set) var lastAngle: Double?
    public private(set) var setupIssues: [SetupIssue] = []

    let startDate: Date
    let startTime: TimeInterval
    var now: TimeInterval
    var side: Side?
    var current: ExerciseResult?
    var repCounter: RepCounter?
    var holdTimer: HoldTimer?
    var smoother = AngleSmoother()
    var setupReadySince: TimeInterval?
    var lastSetupCueAt: TimeInterval = -.infinity
    var countdownNextAt: TimeInterval = 0
    var lastSeenAt: TimeInterval
    var trackingLostAnnounced = false
    var formViolationSince: [String: TimeInterval] = [:]
    var lastFormCueAt: [String: TimeInterval] = [:]
    var lastPartialCueAt: TimeInterval = -.infinity
    var lastCorrectionCueAt: TimeInterval = -.infinity
    var phaseBeforePause: ConductorPhase?

    public init(plan: [PlannedExercise], kind: SessionSummary.Kind, title: String, mode: AppMode, config: ConductorConfig,
                startDate: Date = Date(), startTime: TimeInterval, programId: UUID? = nil, templateId: String? = nil, streamId: UUID? = nil) {
        self.plan = plan
        self.kind = kind
        self.title = title
        self.mode = mode
        self.config = config
        self.startDate = startDate
        self.startTime = startTime
        self.now = startTime
        self.lastSeenAt = startTime
        self.programId = programId
        self.templateId = templateId
        self.streamId = streamId
    }

    // MARK: - Public API

    public var currentExercise: PlannedExercise? { plan.indices.contains(exerciseIndex) ? plan[exerciseIndex] : nil }

    public var isAwaitingPainRating: Bool { phase == .paused(.awaitingPainRating) }
    public var isClarifying: Bool { phase == .paused(.clarifying) }
    public var isFinished: Bool { phase == .finished }

    public var snapshot: ConductorSnapshot {
        let planned = currentExercise
        var restRemaining: Int?
        if case .rest(let until) = phase { restRemaining = max(0, Int((until - now).rounded(.up))) }
        return ConductorSnapshot(
            phase: phase,
            exerciseIndex: exerciseIndex,
            exerciseCount: plan.count,
            exerciseId: planned?.spec.id,
            exerciseName: planned?.spec.name ?? "",
            setIndex: setIndex,
            totalSets: planned?.dose.sets ?? 0,
            isHold: planned?.spec.kind.isHold ?? false,
            reps: repCounter?.count ?? 0,
            targetReps: planned?.dose.reps,
            holdSeconds: holdTimer?.heldSeconds ?? 0,
            targetHoldSeconds: planned?.dose.holdSeconds,
            isHolding: holdTimer?.isHolding ?? false,
            angle: lastAngle,
            repProgress: repCounter?.currentProgress ?? 0,
            setupIssues: setupIssues,
            side: side,
            restRemaining: restRemaining
        )
    }

    public mutating func start(at t: TimeInterval) -> [ConductorEvent] {
        now = t
        guard !plan.isEmpty else { return finishSession() }
        return enterSetup(introduce: true)
    }

    public mutating func process(_ frame: PoseFrame) -> [ConductorEvent] {
        var events = tick(at: frame.timestamp)
        switch phase {
        case .setup: events += processSetup(frame)
        case .active: events += processActive(frame)
        default: break
        }
        return events
    }

    public mutating func tick(at t: TimeInterval) -> [ConductorEvent] {
        now = max(now, t)
        var events: [ConductorEvent] = []
        switch phase {
        case .countdown(let remaining) where now >= countdownNextAt:
            let next = remaining - 1
            if next <= 0 {
                phase = .active
                lastSeenAt = now
                events += [.phaseChanged(.active), .say(.go)]
            } else {
                phase = .countdown(remaining: next)
                countdownNextAt = now + 1
                events += [.phaseChanged(phase), .say(.count(next))]
            }
        case .rest(let until) where now >= until:
            setIndex += 1
            beginSet()
            events += startCountdown(delay: 0.3)
        default:
            break
        }
        return events
    }

    public mutating func pause(at t: TimeInterval, reason: PauseReason = .user) -> [ConductorEvent] {
        now = max(now, t)
        guard phase != .finished else { return [] }
        if case .paused = phase {
            phase = .paused(reason)
            return [.phaseChanged(phase)]
        }
        phaseBeforePause = phase
        phase = .paused(reason)
        var events: [ConductorEvent] = [.phaseChanged(phase)]
        if reason == .user { events.append(.say(.paused)) }
        return events
    }

    public mutating func resume(at t: TimeInterval) -> [ConductorEvent] {
        now = max(now, t)
        guard case .paused = phase else { return [] }
        let previous = phaseBeforePause
        phaseBeforePause = nil
        switch previous {
        case .setup, .none:
            return enterSetup(introduce: false)
        default:
            // Re-arm with a short countdown; reps and hold time already done are kept.
            repCounter?.interrupt()
            return startCountdown(delay: 0.3)
        }
    }

    public mutating func skipExercise(at t: TimeInterval) -> [ConductorEvent] {
        now = max(now, t)
        guard phase != .finished else { return [] }
        closeCurrentSet()
        return finishExercise(stopReason: .skipped)
    }

    public mutating func endSession(at t: TimeInterval) -> [ConductorEvent] {
        now = max(now, t)
        guard phase != .finished else { return [] }
        closeCurrentSet()
        if var result = current {
            result.stopReason = .userEnded
            results.append(result)
            current = nil
        }
        return finishSession()
    }

    /// Apply something the user said (already classified by the LLM or the on-device
    /// classifier). Context is attached here; the rule engine decides the action.
    /// Pass `speakResponse: false` when the cloud coach is already speaking its own reply.
    public mutating func report(_ incoming: SymptomReport, at t: TimeInterval, speakResponse: Bool? = nil) -> [ConductorEvent] {
        now = max(now, t)
        var report = incoming
        report.timestamp = date(for: now)
        report.exerciseId = report.exerciseId ?? currentExercise?.spec.id
        report.setIndex = report.setIndex ?? (currentExercise == nil ? nil : setIndex)
        if let counter = repCounter { report.repIndex = report.repIndex ?? (counter.count + (counter.isAtStart ? 0 : 1)) }
        if let timer = holdTimer, timer.heldSeconds > 0 { report.holdSecond = report.holdSecond ?? timer.wholeSeconds }
        report.angle = report.angle ?? lastAngle

        // An answer to our follow-up ("stretch or sharp?", "0–10?") completes the previous
        // report rather than creating a second one, so the clinician sees one event.
        if isAwaitingPainRating || isClarifying, let previous = symptoms.last {
            symptoms.removeLast()
            report.utterance = "\(previous.utterance) → \(report.utterance)"
            report.bodyLocation = report.bodyLocation ?? previous.bodyLocation
            report.side = report.side ?? previous.side
            report.quality = report.quality ?? previous.quality
            report.exerciseId = previous.exerciseId ?? report.exerciseId
            report.setIndex = previous.setIndex ?? report.setIndex
            report.repIndex = previous.repIndex ?? report.repIndex
            report.holdSecond = previous.holdSecond ?? report.holdSecond
            report.angle = previous.angle ?? report.angle
            report.timestamp = previous.timestamp
            if isAwaitingPainRating, report.category == .normal, (report.severity ?? 0) > 0 { report.category = .pain }
        }

        let decision = SymptomRules.decide(report, policy: config.symptomPolicy)
        report.action = decision.action
        if let flag = decision.redFlag {
            report.category = .redFlag
            report.redFlagReason = flag.reason
        }
        symptoms.append(report)

        var events: [ConductorEvent] = [.symptomLogged(report)]
        let isEscalation: Bool
        if case .endSession = decision.action { isEscalation = true } else { isEscalation = false }
        if speakResponse ?? config.speaksSymptomResponses || isEscalation,
           let line = SymptomResponses.line(for: decision.action, category: report.category, policy: config.symptomPolicy) {
            events.append(.say(line))
        }

        switch decision.action {
        case .continueExercise:
            if case .paused(let reason) = phase, reason != .user { events += resume(at: now) }
        case .clarify:
            events += pause(at: now, reason: .clarifying)
        case .pauseAndRate:
            events += pause(at: now, reason: .awaitingPainRating)
        case .stopSet:
            let effectivePhase: ConductorPhase? = { if case .paused = phase { return phaseBeforePause }; return phase }()
            switch effectivePhase {
            case .active?, .countdown?:
                phaseBeforePause = nil
                events += completeSet()
            default:
                // Not mid-set (setup or rest): nothing to stop, just carry on.
                if case .paused = phase { events += resume(at: now) }
            }
        case .stopExercise:
            phaseBeforePause = nil
            closeCurrentSet()
            events += finishExercise(stopReason: .symptom)
        case .endSession(let level):
            escalation = level
            closeCurrentSet()
            if var result = current {
                result.stopReason = .redFlag
                results.append(result)
                current = nil
            }
            events += finishSession(sayDone: false)
        }
        return events
    }

    public func summary(painBefore: Int? = nil, painAfter: Int? = nil) -> SessionSummary {
        SessionSummary(
            kind: kind, title: title, mode: mode, startedAt: startDate, endedAt: date(for: now),
            programId: programId, templateId: templateId, streamId: streamId,
            exercises: results, symptoms: symptoms, painBefore: painBefore, painAfter: painAfter, escalation: escalation
        )
    }

    // MARK: - Phases

    mutating func enterSetup(introduce: Bool) -> [ConductorEvent] {
        guard let planned = currentExercise else { return finishSession() }
        phase = .setup
        setupReadySince = nil
        lastSetupCueAt = now
        if current == nil {
            current = ExerciseResult(exerciseId: planned.spec.id, side: planned.side, plannedSets: planned.dose.sets)
            beginSet()
        }
        var events: [ConductorEvent] = [.phaseChanged(.setup)]
        if introduce {
            let previousPosture = exerciseIndex > 0 ? plan[exerciseIndex - 1].spec.posture : nil
            events.append(.say(CueCatalog.intro(planned.spec, first: exerciseIndex == 0)))
            if let careCue = planned.careCue { events.append(.say(careCue)) }
            events.append(.say(CueCatalog.setup(planned.spec, withCameraTip: previousPosture != planned.spec.posture)))
        }
        return events
    }

    mutating func processSetup(_ frame: PoseFrame) -> [ConductorEvent] {
        guard let planned = currentExercise else { return [] }
        let status = SetupCheck.evaluate(frame, spec: planned.spec, preferredSide: planned.side, minConfidence: config.minConfidence)
        setupIssues = status.issues
        var events: [ConductorEvent] = [.setupStatus(status)]
        if status.isReady {
            if setupReadySince == nil { setupReadySince = now }
            if let since = setupReadySince, now - since >= config.setupStableSeconds {
                side = status.side
                current?.side = status.side
                setupIssues = []
                events.append(.say(CueCatalog.go(planned.spec)))
                events += startCountdown(delay: 2.5)
            }
        } else {
            setupReadySince = nil
            if let issue = status.issues.first, now - lastSetupCueAt >= config.setupCueCooldown {
                lastSetupCueAt = now
                events.append(.say(issue.guidance))
            }
        }
        return events
    }

    mutating func startCountdown(delay: TimeInterval) -> [ConductorEvent] {
        phase = .countdown(remaining: 4)
        countdownNextAt = now + delay
        return [.phaseChanged(phase)]
    }

    mutating func beginSet() {
        guard let planned = currentExercise else { return }
        if let rule = planned.repRule { repCounter = RepCounter(rule: rule) } else { repCounter = nil }
        if planned.spec.kind.isHold {
            holdTimer = HoldTimer(targetSeconds: Double(planned.dose.holdSeconds ?? planned.spec.defaultDose.holdSeconds ?? 30))
        } else {
            holdTimer = nil
        }
        formViolationSince = [:]
        trackingLostAnnounced = false
    }

    mutating func processActive(_ frame: PoseFrame) -> [ConductorEvent] {
        guard let planned = currentExercise, let side else { return [] }
        var events: [ConductorEvent] = []

        var angle: Double?
        if let definition = planned.spec.kind.trackedAngle, let raw = frame.angle(definition, side: side, minConfidence: config.minConfidence) {
            angle = smoother.update(raw)
        }
        let present = planned.spec.kind.trackedAngle == nil
            ? SetupCheck.evaluate(frame, spec: planned.spec, preferredSide: side, minConfidence: config.minConfidence).issues.allSatisfy { if case .noPerson = $0 { return false }; return true }
            : angle != nil

        if present {
            lastSeenAt = now
            trackingLostAnnounced = false
        } else if !trackingLostAnnounced && now - lastSeenAt >= config.trackingLostSeconds {
            trackingLostAnnounced = true
            repCounter?.interrupt()
            events += [.trackingLost, .say(.cantSee)]
        }

        if let angle {
            lastAngle = angle
            let previousMin = current?.minAngle ?? angle
            let previousMax = current?.maxAngle ?? angle
            current?.minAngle = min(previousMin, angle)
            current?.maxAngle = max(previousMax, angle)
        }

        if repCounter != nil, let angle {
            switch repCounter?.update(angle: angle) {
            case .rep(let count, let peak):
                current?.repPeakAngles.append(peak)
                events.append(.repCompleted(count: count, peakAngle: peak))
                let target = planned.dose.reps ?? Int.max
                if count >= target {
                    events += completeSet()
                    return events
                }
                events.append(.say(.count(count)))
            case .partial(let peak, _):
                events.append(.partialRep(peakAngle: peak))
                if now - lastPartialCueAt >= config.formCueCooldown {
                    lastPartialCueAt = now
                    events.append(.say(CueCatalog.further))
                }
            case nil:
                break
            }
        }

        if var timer = holdTimer {
            let satisfied: Bool
            if case .hold(let rule) = planned.spec.kind, let condition = rule.condition {
                satisfied = angle.map(condition.isSatisfied) ?? false
            } else {
                satisfied = present
            }
            let update = timer.update(satisfied: satisfied, at: now)
            holdTimer = timer
            if update.startedHolding && timer.heldSeconds < 0.5 { events.append(.say(.holdIt)) }
            let target = Int(timer.targetSeconds)
            for second in update.crossedSeconds {
                events.append(.holdProgress(seconds: second, target: target))
                if second < target, let line = holdCountLine(second: second, target: target) { events.append(.say(line)) }
            }
            if update.stoppedHolding, case .hold(let rule) = planned.spec.kind, let correction = rule.correction,
               now - lastCorrectionCueAt >= config.formCueCooldown {
                lastCorrectionCueAt = now
                events.append(.say(CueCatalog.correction(correction)))
            }
            if update.completed {
                events += completeSet()
                return events
            }
        }

        for check in planned.spec.formChecks {
            guard let value = frame.angle(check.angle, side: side, minConfidence: config.minConfidence) else { continue }
            if check.condition.isSatisfied(by: value) {
                formViolationSince[check.id] = nil
                continue
            }
            let since = formViolationSince[check.id] ?? now
            formViolationSince[check.id] = since
            if now - since >= 0.6, now - (lastFormCueAt[check.id] ?? -.infinity) >= config.formCueCooldown {
                lastFormCueAt[check.id] = now
                current?.formWarnings += 1
                events += [.formWarning(checkId: check.id, message: check.cue), .say(CueCatalog.form(check))]
            }
        }
        return events
    }

    /// Short holds count every second; long holds every five, then a final three-two-one.
    func holdCountLine(second: Int, target: Int) -> CueLine? {
        let remaining = target - second
        if target <= 10 { return .count(second) }
        if remaining <= 3 { return .count(remaining) }
        if second % 5 == 0 { return second <= 30 ? .count(second) : CueCatalog.seconds(second) }
        return nil
    }

    /// Records the in-progress set (full or partial) into the current result.
    mutating func closeCurrentSet() {
        guard current != nil else { return }
        let alreadyRecorded = (current?.completedSets ?? 0) > setIndex
        guard !alreadyRecorded else { return }
        if let counter = repCounter {
            if counter.count > 0 || counter.partials > 0 {
                current?.repsPerSet.append(counter.count)
                current?.partialReps += counter.partials
            }
        } else if let timer = holdTimer, timer.wholeSeconds > 0 {
            current?.holdSecondsPerSet.append(timer.wholeSeconds)
        }
    }

    mutating func completeSet() -> [ConductorEvent] {
        guard let planned = currentExercise else { return [] }
        if let counter = repCounter {
            current?.repsPerSet.append(counter.count)
            current?.partialReps += counter.partials
        } else if let timer = holdTimer {
            current?.holdSecondsPerSet.append(timer.wholeSeconds)
        }
        var events: [ConductorEvent] = [.setCompleted(exerciseIndex: exerciseIndex, setIndex: setIndex)]
        if planned.spec.kind.isHold { events.append(.say(.relax)) }

        if setIndex + 1 < planned.dose.sets {
            let rest = planned.dose.restSeconds
            phase = .rest(until: now + Double(rest))
            events.append(.phaseChanged(phase))
            if rest > 10 {
                events.append(.say(CueCatalog.rest(seconds: rest)))
            } else if !planned.spec.kind.isHold {
                events.append(.say(.rest))
            }
            return events
        }
        events.append(.say(.niceWork))
        return events + finishExercise(stopReason: nil)
    }

    mutating func finishExercise(stopReason: StopReason?) -> [ConductorEvent] {
        var events: [ConductorEvent] = []
        if var result = current {
            result.stopReason = stopReason
            results.append(result)
            events.append(.exerciseCompleted(result))
        }
        current = nil
        exerciseIndex += 1
        setIndex = 0
        repCounter = nil
        holdTimer = nil
        smoother.reset()
        lastAngle = nil
        guard exerciseIndex < plan.count else { return events + finishSession() }
        // Keep the tracked side when the next exercise uses the same posture and view.
        let previous = plan[exerciseIndex - 1].spec
        let next = plan[exerciseIndex].spec
        if previous.posture != next.posture || previous.cameraView != next.cameraView { side = nil }
        return events + enterSetup(introduce: true)
    }

    mutating func finishSession(sayDone: Bool = true) -> [ConductorEvent] {
        phase = .finished
        var events: [ConductorEvent] = [.phaseChanged(.finished)]
        if sayDone { events.append(.say(.sessionDone)) }
        events.append(.sessionCompleted(summary()))
        return events
    }

    func date(for t: TimeInterval) -> Date {
        startDate.addingTimeInterval(t - startTime)
    }
}
