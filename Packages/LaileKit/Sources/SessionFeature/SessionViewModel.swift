import AppCore
import DesignSystem
import Foundation
import LaileCore
import Observation
import PoseKit
import VoiceKit

/// Wires camera → conductor → voice for one session, and hands the verified summary to the backend.
@MainActor
@Observable
public final class SessionViewModel {
    public enum Stage: Equatable {
        case painBefore
        case running
        case painAfter
        case submitting
        case done
    }

    public enum QuickReply: String, CaseIterable, Identifiable {
        case fine = "Feels fine"
        case stretch = "Stretching"
        case sharp = "Sharp pain"
        case wrong = "Feels wrong"
        public var id: String { rawValue }

        var report: SymptomReport {
            switch self {
            case .fine: SymptomReport(category: .normal, utterance: "Feels fine (tapped)", source: .tapped)
            case .stretch: SymptomReport(category: .expectedStretch, utterance: "Stretching feeling (tapped)", quality: "pulling", source: .tapped)
            case .sharp: SymptomReport(category: .pain, utterance: "Sharp pain (tapped)", quality: "sharp", source: .tapped)
            case .wrong: SymptomReport(category: .wrongSensation, utterance: "Something feels wrong (tapped)", source: .tapped)
            }
        }
    }

    public let launch: SessionLaunch
    let app: AppModel
    public private(set) var stage: Stage
    public private(set) var snapshot: ConductorSnapshot
    public private(set) var latestFrame: PoseFrame?
    public private(set) var caption = ""
    public private(set) var heard = ""
    public private(set) var toast: String?
    public private(set) var repPulse = 0
    public private(set) var cameraError: String?
    public private(set) var listening = false
    public private(set) var result: API.SessionSubmitResponse?
    public private(set) var summary: SessionSummary?
    public var painBefore: Int?
    public var painAfter: Int?

    let pose: any PoseProvider
    let speaker = CueSpeaker()
    let listener = SpeechListener()
    private var conductor: SessionConductor
    private var ticker: Timer?
    private var toastTask: Task<Void, Never>?

    public init(launch: SessionLaunch, app: AppModel) {
        self.launch = launch
        self.app = app
        self.stage = launch.askPain ? .painBefore : .running
        let config = ConductorConfig(symptomPolicy: launch.policy)
        let conductor = SessionConductor(plan: launch.plan, kind: launch.kind, title: launch.title, mode: launch.mode, config: config,
                                         startDate: Date(), startTime: PoseClock.now, programId: launch.programId, templateId: launch.templateId)
        self.conductor = conductor
        self.snapshot = conductor.snapshot
        self.pose = PoseProviderFactory.make(preferFront: app.settings.preferFrontCamera)
    }

    public var isAwaitingRating: Bool { conductor.isAwaitingPainRating }
    public var isClarifying: Bool { conductor.isClarifying }
    public var currentExercise: PlannedExercise? { conductor.currentExercise }
    public var escalation: EscalationLevel? { summary?.escalation ?? conductor.escalation }
    public var emergencyNumber: String { launch.policy.emergencyNumber }
    public var mirrored: Bool { pose.isFrontCamera }

    /// Joints to highlight on the skeleton (the ones being measured).
    public var highlightedJoints: [LaileCore.Joint] {
        guard let definition = currentExercise?.spec.kind.trackedAngle, let side = snapshot.side else { return [] }
        return definition.parts.map { LaileCore.Joint($0, side) }
    }

    // MARK: Lifecycle

    public func setPainBefore(_ value: Int?) {
        painBefore = value
        stage = .running
        Task { await begin() }
    }

    public func begin() async {
        VoiceAudioSession.activate()
        speaker.isEnabled = app.settings.speakCues
        let backend = app.backend
        speaker.remoteVoice = { text in await backend.speech(text) }
        speaker.onSpeakingChanged = { [weak self] speaking, priority in
            // Mute the mic for anything longer than a count so the coach never hears itself.
            if priority > .low { self?.listener.setMuted(speaking) }
        }
        pose.onFrame = { [weak self] frame in self?.onFrame(frame) }
        do {
            try await pose.start()
        } catch {
            cameraError = error.localizedDescription
        }
        if app.settings.listenForFeedback, await SpeechListener.requestPermissions() {
            listener.onPartial = { [weak self] text in self?.heard = text }
            listener.onUtterance = { [weak self] text in
                guard let self else { return }
                Task { await self.userSaid(text, source: .voiceOnDevice) }
            }
            try? listener.start()
            listening = listener.isListening
        }
        handle(conductor.start(at: PoseClock.now))
        ticker = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        handle(conductor.tick(at: PoseClock.now))
    }

    private func onFrame(_ frame: PoseFrame) {
        latestFrame = frame
        handle(conductor.process(frame))
    }

    public func teardown() {
        ticker?.invalidate()
        ticker = nil
        pose.stop()
        listener.stop()
        speaker.stop()
        VoiceAudioSession.deactivate()
    }

    // MARK: Conductor events

    private func handle(_ events: [ConductorEvent]) {
        for event in events {
            switch event {
            case .say(let line):
                speaker.say(line)
                if line.priority > .low { caption = line.text }
            case .repCompleted:
                repPulse += 1
                Haptics.rep()
            case .phaseChanged, .exerciseCompleted:
                pose.perform(conductor.currentExercise)
            case .symptomLogged(let report):
                showToast(Self.toastText(for: report))
            case .formWarning(_, let message):
                showToast(message)
            case .sessionCompleted(let summary):
                finish(summary)
            case .setupStatus, .partialRep, .holdProgress, .trackingLost, .setCompleted:
                break
            }
        }
        snapshot = conductor.snapshot
    }

    static func toastText(for report: SymptomReport) -> String {
        switch report.action {
        case .continueExercise?: return report.category == .normal ? "Good to go" : "Noted — carry on gently"
        case .clarify?: return "Stretch or sharp pain?"
        case .pauseAndRate?: return "Paused — rate your pain"
        case .stopSet?: return "Set stopped and noted"
        case .stopExercise?: return "Exercise stopped and noted"
        case .endSession?: return "Session stopped for your safety"
        case nil: return "Noted"
        }
    }

    private func showToast(_ text: String) {
        toast = text
        toastTask?.cancel()
        toastTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            if !Task.isCancelled { self?.toast = nil }
        }
    }

    // MARK: Talking to the coach

    var voiceContext: API.VoiceContext {
        API.VoiceContext(exerciseName: snapshot.exerciseName, exerciseId: snapshot.exerciseId, setIndex: snapshot.setIndex,
                         totalSets: snapshot.totalSets, reps: snapshot.reps, holdSeconds: Int(snapshot.holdSeconds),
                         angle: snapshot.angle, phase: "\(snapshot.phase)", awaitingPainRating: conductor.isAwaitingPainRating)
    }

    public func userSaid(_ text: String, source: SymptomSource) async {
        heard = text
        guard stage == .running else { return }

        if let turn = try? await app.backend.coachTurn(text, context: voiceContext) {
            if var report = turn.report {
                report.source = .voiceLLM
                handle(conductor.report(report, at: PoseClock.now, speakResponse: false))
                if case .endSession? = report.action { return } // conductor already spoke the fixed escalation line
            }
            if !turn.reply.isEmpty {
                speaker.say(CueLine(turn.reply))
                caption = turn.reply
            }
            return
        }

        // Offline: same rules on-device, and the conductor speaks the fixed responses.
        if MedicationBoundary.isDoseQuestion(text) {
            speaker.say(CueCatalog.medicationReferral)
            caption = MedicationBoundary.referral
            return
        }
        var report = UtteranceClassifier.classify(text, awaitingRating: conductor.isAwaitingPainRating)
        report.source = source
        // Plain "fine"/counting doesn't need logging unless we asked a question.
        if report.category == .normal && !conductor.isAwaitingPainRating && !conductor.isClarifying { return }
        handle(conductor.report(report, at: PoseClock.now))
    }

    public func quickReply(_ reply: QuickReply) {
        handle(conductor.report(reply.report, at: PoseClock.now))
    }

    public func rate(_ severity: Int) {
        var report = SymptomReport(category: severity == 0 ? .normal : .pain, utterance: "Rated \(severity)/10 (tapped)", severity: severity, source: .tapped)
        if severity == 0 { report.quality = nil }
        handle(conductor.report(report, at: PoseClock.now))
    }

    // MARK: Controls

    public var isPaused: Bool { if case .paused = snapshot.phase { return true }; return false }

    public func togglePause() {
        handle(isPaused ? conductor.resume(at: PoseClock.now) : conductor.pause(at: PoseClock.now))
    }

    public func skip() { handle(conductor.skipExercise(at: PoseClock.now)) }
    public func endEarly() { handle(conductor.endSession(at: PoseClock.now)) }

    private func finish(_ summary: SessionSummary) {
        ticker?.invalidate()
        pose.stop()
        listener.stop()
        self.summary = summary
        if launch.askPain && summary.escalation == nil && !summary.exercises.isEmpty {
            stage = .painAfter
        } else {
            Task { await submit() }
        }
    }

    public func setPainAfter(_ value: Int?) {
        painAfter = value
        Task { await submit() }
    }

    private func submit() async {
        guard var summary else { return }
        summary.painBefore = painBefore
        summary.painAfter = painAfter
        self.summary = summary
        stage = .submitting
        if summary.exercises.isEmpty && summary.symptoms.isEmpty {
            stage = .done
            return
        }
        result = await app.submit(summary)
        stage = .done
        if result != nil { Haptics.success() }
    }
}
