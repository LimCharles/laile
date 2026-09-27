import Foundation
import LaileCore

/// On-device backend. Persists a small JSON file and runs the exact same LaileCore engines
/// the server does, so rewards, PBs and program safety behave identically offline.
@MainActor
public final class DemoBackend: LaileBackend {
    struct State: Codable {
        var user: API.UserProfile
        var activity: [ActivityRecord] = []
        var sessions: [SessionSummary] = []
        var samples: [MetricSample] = []
        var program: Program?
        var clinicianName: String?
        var medications: [Medication] = []
        var medicationLog: [MedicationLogEntry] = []
    }

    public static let inviteCode = "LAI-DEMO42"

    public let isDemo = true
    public var displayName: String { "On-device demo" }
    private var state: State
    private let fileURL: URL
    private let library = ExerciseLibrary.standard
    private var engine: RewardEngine { RewardEngine(timeZone: .current) }

    public init(fileURL: URL? = nil) {
        let url = fileURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("laile-demo.json")
        self.fileURL = url
        if let data = try? Data(contentsOf: url), let saved = try? LaileJSON.decoder().decode(State.self, from: data) {
            state = saved
        } else {
            state = State(user: API.UserProfile(id: UUID(), email: "you@device", displayName: "You", role: .mover, mode: .move,
                                                timeZone: TimeZone.current.identifier))
            seedHistory()
            save()
        }
    }

    public func setDisplayName(_ name: String) {
        state.user.displayName = name
        save()
    }

    public func resetDemo() {
        try? FileManager.default.removeItem(at: fileURL)
        state = State(user: API.UserProfile(id: UUID(), email: "you@device", displayName: state.user.displayName, role: .mover,
                                            mode: .move, timeZone: TimeZone.current.identifier))
        seedHistory()
        save()
    }

    private func save() {
        try? FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? LaileJSON.encoder().encode(state) { try? data.write(to: fileURL, options: .atomic) }
    }

    // MARK: LaileBackend

    public func currentUser() async throws -> API.UserProfile {
        var user = state.user
        user.clinicianName = state.clinicianName
        return user
    }

    public func rewards() async throws -> RewardsSummary { engine.summary(now: Date(), history: state.activity) }

    public func checkIn() async throws -> API.CheckInResponse {
        let outcome = engine.checkIn(now: Date(), history: state.activity)
        state.activity += outcome.records
        save()
        return API.CheckInResponse(outcome: outcome, summary: engine.summary(now: Date(), history: state.activity))
    }

    public func today() async throws -> API.TodayPlan {
        let templates = SessionTemplate.builtIn.filter { $0.mode == .move || state.user.mode == .rehab }
        guard state.user.mode == .rehab else {
            return API.TodayPlan(mode: .move, program: nil, clinicianName: nil, templates: templates, medicationDoses: [])
        }
        let day = DayKey(Date(), timeZone: .current)
        return API.TodayPlan(mode: .rehab, program: state.program, clinicianName: state.clinicianName, templates: templates,
                             medicationDoses: MedicationSchedule.doses(for: state.medications, on: day, log: state.medicationLog))
    }

    public func submit(_ summary: SessionSummary) async throws -> API.SessionSubmitResponse {
        guard !state.sessions.contains(where: { $0.id == summary.id }) else { throw BackendError.http(409, "Already saved.") }
        let newSamples = MetricExtractor.samples(from: summary, library: library)
        let achievements = ProgressAnalyzer.achievements(adding: newSamples, to: state.samples, milestones: Milestone.defaults(for: state.user.mode))
        state.sessions.append(summary)
        state.samples += newSamples

        let kind: ActivityKind = switch summary.kind {
        case .baseline: .baseline
        case .stream: .stream
        case .snack: summary.isStretchOnly ? .stretch : .snack
        case .program, .workout: .session
        }
        var extras: [ActivityRecord] = []
        if achievements.contains(where: { if case .personalBest = $0 { return true }; return false }) {
            extras.append(ActivityRecord(day: engine.today(summary.endedAt), kind: .bonus, xp: 30, at: summary.endedAt,
                                         refId: "pb-\(summary.id)", note: "Personal best"))
        }
        let movement = engine.recordMovement(kind: kind, reps: summary.verifiedReps, refId: summary.id.uuidString,
                                             now: summary.endedAt, history: state.activity, extraBonuses: extras)
        state.activity += movement.records
        save()
        return API.SessionSubmitResponse(movement: movement, achievements: achievements,
                                         summary: engine.summary(now: Date(), history: state.activity))
    }

    public func progress() async throws -> API.ProgressOverview {
        let kinds = MetricKind.allCases.filter { kind in state.samples.contains { $0.kind == kind } }
        let trends = kinds.map { ProgressAnalyzer.trend(kind: $0, samples: state.samples, milestones: Milestone.defaults(for: state.user.mode)) }
        return API.ProgressOverview(trends: trends, recentSessions: Array(state.sessions.sorted { $0.startedAt > $1.startedAt }.prefix(10)))
    }

    public func streams() async throws -> [StreamEvent] {
        let now = Date()
        return DemoStreams.schedule(around: now).filter { $0.endsAt > now.addingTimeInterval(-600) }
    }

    public func serverTimeOffset() async -> TimeInterval { 0 }

    public func link(inviteCode: String) async throws -> API.UserProfile {
        guard InviteCode.normalize(inviteCode) == Self.inviteCode else { throw BackendError.invalidInviteCode }
        let clinician = "Dr. Priya Nair (demo)"
        let context = PatientContext(displayName: state.user.displayName, age: nil, procedure: .totalKneeReplacement,
                                     procedureDate: Date().addingTimeInterval(-9 * 86_400),
                                     precautions: Precautions(weightBearing: .partial, maxImpact: .low, affectedSide: .left),
                                     goals: ["Get back to gardening"])
        var program = TemplateDrafter.draft(context: context, patientId: nil)
        program.status = .signed
        program.signedAt = Date()
        program.signedBy = clinician
        state.program = program
        state.clinicianName = clinician
        state.medications = [
            Medication(name: "Paracetamol", doseText: "2 tablets", purpose: "Pain relief.",
                       howToTake: "As prescribed. Ask your physio about timing a dose before exercise.",
                       times: [TimeOfDay(8), TimeOfDay(14), TimeOfDay(20)], prescribedBy: clinician),
            Medication(name: "Rivaroxaban", doseText: "1 tablet", purpose: "A blood thinner that lowers the risk of clots after surgery.",
                       howToTake: "Once a day at the same time. Don't stop without talking to your doctor.",
                       times: [TimeOfDay(9)], prescribedBy: clinician),
        ]
        state.user.mode = .rehab
        state.user.role = .patient
        save()
        return try await currentUser()
    }

    /// Leave rehab (e.g. "graduated") and return to Move mode.
    public func graduate() {
        state.user.mode = .move
        state.user.role = .mover
        save()
    }

    public func markMedicationTaken(_ medicationId: UUID, scheduled: TimeOfDay) async throws {
        state.medicationLog.append(MedicationLogEntry(medicationId: medicationId, day: DayKey(Date(), timeZone: .current),
                                                      scheduled: scheduled, takenAt: Date()))
        save()
    }

    public func coachTurn(_ utterance: String, context: API.VoiceContext) async throws -> API.CoachTurnResponse {
        if MedicationBoundary.isDoseQuestion(utterance) {
            return API.CoachTurnResponse(reply: MedicationBoundary.referral, report: nil)
        }
        let report = UtteranceClassifier.classify(utterance, awaitingRating: context.awaitingPainRating)
        return API.CoachTurnResponse(reply: "", report: report.category == .normal && !context.awaitingPainRating ? nil : report)
    }

    public func streamSocketURL(_ streamId: UUID) -> URL? { nil }

    /// Demo mode speaks only fixed lines, which are pre-generated in the app bundle.
    public func speech(_ text: String) async -> Data? { nil }

    // MARK: Seed

    /// A few days of history so progress charts and streaks aren't empty on first launch.
    private func seedHistory() {
        let cal = Calendar.current
        let pushUps = [5, 6, 6, 8, 9]
        for (i, reps) in pushUps.enumerated() {
            let daysAgo = pushUps.count - i
            // Midday on each past day, so the demo streak is intact whatever time it is now.
            guard let day = cal.date(byAdding: .day, value: -daysAgo, to: cal.startOfDay(for: Date())) else { continue }
            let start = day.addingTimeInterval(12.5 * 3600)
            var push = ExerciseResult(exerciseId: "knee-push-up", side: .left, plannedSets: 1)
            push.repsPerSet = [reps]
            var squat = ExerciseResult(exerciseId: "squat", side: .left, plannedSets: 1)
            squat.repsPerSet = [12 + i * 2]
            var plank = ExerciseResult(exerciseId: "plank", side: .left, plannedSets: 1)
            plank.holdSecondsPerSet = [25 + i * 5]
            let summary = SessionSummary(kind: i == 0 ? .baseline : .snack, title: i == 0 ? "Fitness check" : "Lunch-break blast",
                                         mode: .move, startedAt: start, endedAt: start.addingTimeInterval(420),
                                         templateId: i == 0 ? "move-baseline" : "lunch-blast", exercises: [push, squat, plank])
            state.activity += engine.checkIn(now: start.addingTimeInterval(-120), history: state.activity).records
            state.sessions.append(summary)
            let samples = MetricExtractor.samples(from: summary, library: library)
            state.samples += samples
            state.activity += engine.recordMovement(kind: i == 0 ? .baseline : .snack, reps: summary.verifiedReps,
                                                    refId: summary.id.uuidString, now: summary.endedAt, history: state.activity).records
        }
    }
}
