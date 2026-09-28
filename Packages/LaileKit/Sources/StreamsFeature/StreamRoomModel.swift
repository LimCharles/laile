import AppCore
import DesignSystem
import Foundation
import LaileCore
import Observation
import PoseKit
import VoiceKit

/// A timed follow-along: the wall clock decides which segment everyone is on; your own camera
/// counts your reps; a leaderboard shows everyone's camera-verified totals.
@MainActor
@Observable
final class StreamRoomModel {
    let stream: StreamEvent
    let app: AppModel
    let pose: any PoseProvider
    let speaker = CueSpeaker()

    private(set) var phase: StreamPhase = .ended
    private(set) var segmentReps = 0
    private(set) var segmentHold: Double = 0
    private(set) var totalReps = 0
    private(set) var leaderboard: [LeaderboardEntry] = []
    /// Everyone connected to this stream right now, including you (0 until you join).
    private(set) var participants = 0
    private(set) var latestFrame: PoseFrame?
    private(set) var joined = false
    private(set) var result: API.SessionSubmitResponse?
    private(set) var finished = false
    private(set) var cameraError: String?

    private var timer: Timer?
    private var currentSegment = -1
    private var counter: RepCounter?
    private var hold: HoldTimer?
    private var smoother = AngleSmoother()
    private var side: Side?
    private var results: [String: ExerciseResult] = [:]
    private var order: [String] = []
    private var joinedAt = Date()
    private var socket: URLSessionWebSocketTask?
    private var lastAnnouncedCountdown = -1

    init(stream: StreamEvent, app: AppModel) {
        self.stream = stream
        self.app = app
        self.pose = PoseProviderFactory.make(preferFront: app.settings.preferFrontCamera)
        phase = StreamClock.phase(of: stream, at: app.now)
    }

    var now: Date { app.now }

    var segment: StreamSegment? {
        if case .live(let p) = phase { return stream.segments[p.segmentIndex] }
        return nil
    }

    var nextSegment: StreamSegment? {
        guard case .live(let p) = phase, p.segmentIndex + 1 < stream.segments.count else { return nil }
        return stream.segments[p.segmentIndex + 1]
    }

    var spec: ExerciseSpec? { segment.flatMap { ExerciseLibrary.standard.spec($0.exerciseId) } }

    // MARK: Lifecycle

    func open() {
        let backend = app.backend
        speaker.voice = app.settings.voice
        speaker.remoteVoice = { text, voice in await backend.speech(text, voice: voice) }
        let lines = CueCatalog.lines(for: stream)
        let speaker = self.speaker
        Task { await speaker.prefetch(lines) }
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
        tick()
    }

    func join() async {
        guard !joined else { return }
        joined = true
        joinedAt = Date()
        VoiceAudioSession.activate()
        speaker.isEnabled = app.settings.speakCues
        pose.onFrame = { [weak self] frame in self?.onFrame(frame) }
        do { try await pose.start() } catch { cameraError = error.localizedDescription }
        connectLeaderboard()
        speaker.say(CueCatalog.streamWelcome)
        currentSegment = -1
        tick()
    }

    func leave() async {
        timer?.invalidate()
        timer = nil
        pose.stop()
        speaker.stop()
        socket?.cancel(with: .normalClosure, reason: nil)
        VoiceAudioSession.deactivate()
        if joined && !finished { await submit() }
    }

    // MARK: Clock

    private func tick() {
        phase = StreamClock.phase(of: stream, at: now)
        switch phase {
        case .live(let position):
            if position.segmentIndex != currentSegment { enterSegment(position.segmentIndex) }
            let remaining = Int(position.segmentRemaining.rounded(.up))
            if joined, remaining <= 3, remaining >= 1, remaining != lastAnnouncedCountdown {
                lastAnnouncedCountdown = remaining
                speaker.say(.count(remaining))
            }
            if let hold, hold.isHolding { segmentHold = hold.heldSeconds }
        case .ended:
            if joined && !finished { Task { await submit() } }
        default:
            break
        }
    }

    private func enterSegment(_ index: Int) {
        closeSegment()
        currentSegment = index
        lastAnnouncedCountdown = -1
        segmentReps = 0
        segmentHold = 0
        smoother.reset()
        let segment = stream.segments[index]
        guard let spec = ExerciseLibrary.standard.spec(segment.exerciseId), !segment.isRest else {
            counter = nil
            hold = nil
            pose.perform(nil)
            if joined { speaker.say(CueCatalog.streamRest(next: nextSegment.flatMap { ExerciseLibrary.standard.spec($0.exerciseId) })) }
            return
        }
        let dose = Dose(sets: 1, reps: spec.kind.isHold ? nil : 999, holdSeconds: spec.kind.isHold ? segment.durationSeconds : nil)
        let planned = PlannedExercise(spec: spec, dose: dose)
        pose.perform(planned)
        counter = planned.repRule.map(RepCounter.init)
        hold = spec.kind.isHold ? HoldTimer(targetSeconds: Double(segment.durationSeconds)) : nil
        if results[spec.id] == nil {
            results[spec.id] = ExerciseResult(exerciseId: spec.id, side: nil, plannedSets: 0)
            order.append(spec.id)
        }
        results[spec.id]?.plannedSets += 1
        if joined {
            speaker.say(CueCatalog.streamSegment(spec, seconds: segment.durationSeconds, coachLine: segment.coachLine))
        }
    }

    private func closeSegment() {
        guard currentSegment >= 0, let spec else { return }
        if counter != nil, segmentReps > 0 { results[spec.id]?.repsPerSet.append(segmentReps) }
        if let hold, hold.wholeSeconds > 0 { results[spec.id]?.holdSecondsPerSet.append(hold.wholeSeconds) }
    }

    // MARK: Camera

    private func onFrame(_ frame: PoseFrame) {
        latestFrame = frame
        guard joined, case .live = phase, let spec else { return }
        if side == nil || frame.meanConfidence(of: spec.requiredParts, side: side!) < 0.3 {
            side = frame.meanConfidence(of: spec.requiredParts, side: .left) >= frame.meanConfidence(of: spec.requiredParts, side: .right) ? .left : .right
        }
        guard let side else { return }
        let angle = spec.kind.trackedAngle.flatMap { frame.angle($0, side: side) }.map { smoother.update($0) }

        if var counter, let angle {
            if case .rep = counter.update(angle: angle) {
                segmentReps += 1
                totalReps += 1
                Haptics.rep()
                speaker.say(.count(segmentReps))
                sendReps()
            }
            self.counter = counter
        }
        if var hold {
            let satisfied: Bool
            if case .hold(let rule) = spec.kind, let condition = rule.condition {
                satisfied = angle.map(condition.isSatisfied) ?? false
            } else {
                satisfied = frame.landmarks.values.filter { $0.confidence > 0.3 }.count >= 4
            }
            _ = hold.update(satisfied: satisfied, at: frame.timestamp)
            self.hold = hold
            segmentHold = hold.heldSeconds
        }
    }

    // MARK: Leaderboard

    private func connectLeaderboard() {
        guard let url = app.backend.streamSocketURL(stream.id) else { return }
        let task = URLSession.shared.webSocketTask(with: url)
        socket = task
        task.resume()
        receive()
    }

    private func receive() {
        socket?.receive { [weak self] result in
            Task { @MainActor in
                guard let self else { return }
                if case .success(.string(let text)) = result,
                   let message = try? LaileJSON.decoder().decode(StreamSocketMessage.self, from: Data(text.utf8)),
                   case .leaderboard(let entries, let participants) = message {
                    self.leaderboard = entries
                    self.participants = participants
                }
                if case .success = result { self.receive() }
            }
        }
    }

    private func sendReps() {
        guard let socket, let data = try? LaileJSON.encoder().encode(StreamSocketMessage.reps(total: totalReps)) else { return }
        socket.send(.string(String(decoding: data, as: UTF8.self))) { _ in }
    }

    // MARK: Finish

    private func submit() async {
        guard !finished else { return }
        finished = true
        closeSegment()
        let exercises = order.compactMap { results[$0] }.filter { $0.completedSets > 0 }
        guard !exercises.isEmpty else { return }
        let summary = SessionSummary(kind: .stream, title: stream.title, mode: app.mode, startedAt: joinedAt, endedAt: Date(),
                                     streamId: stream.id, exercises: exercises)
        result = await app.submit(summary)
        if result != nil { Haptics.success() }
    }
}
