import Foundation
import LaileCore

/// Everything the app needs from the Laile API. `RemoteBackend` is the implementation; the
/// protocol exists so previews and tests can stub it.
@MainActor
public protocol LaileBackend: AnyObject {
    var isSignedIn: Bool { get }
    func signIn(email: String, password: String) async throws -> API.UserProfile
    func register(email: String, password: String, name: String) async throws -> API.UserProfile
    /// A fresh demo account with realistic history (replaces the current demo account, if any).
    func startDemo(_ persona: API.DemoPersona) async throws -> API.UserProfile
    func signOut()

    func currentUser() async throws -> API.UserProfile
    func rewards() async throws -> RewardsSummary
    func checkIn() async throws -> API.CheckInResponse
    func today() async throws -> API.TodayPlan
    func submit(_ summary: SessionSummary) async throws -> API.SessionSubmitResponse
    func progress() async throws -> API.ProgressOverview
    func streams() async throws -> [StreamEvent]
    /// Seconds to add to the local clock to match the server (streams stay in sync).
    func serverTimeOffset() async -> TimeInterval
    func link(inviteCode: String) async throws -> API.UserProfile
    func markMedicationTaken(_ medicationId: UUID, scheduled: TimeOfDay) async throws
    /// Lele's notes (care memory), open ones first, with their history.
    func careNotes() async throws -> [CareNote]
    /// The person says a sore spot feels better: Lele closes the note.
    func markCareNoteBetter(_ id: UUID) async throws -> CareNote
    /// One conversational turn with the coach (Hunyuan + server-side safety rules).
    func coachTurn(_ utterance: String, context: API.VoiceContext) async throws -> API.CoachTurnResponse
    /// WebSocket URL for a stream's live leaderboard.
    func streamSocketURL(_ streamId: UUID) -> URL?
    /// Natural-sounding speech (MP3) for free-form lines, rendered server-side with ElevenLabs
    /// so no API key ever ships in the app. Nil = use the on-device voice.
    nonisolated func speech(_ text: String, voice: CoachVoice) async -> Data?
}

public enum BackendError: LocalizedError {
    case http(Int, String)
    case notSignedIn
    case invalidInviteCode

    public var errorDescription: String? {
        switch self {
        case .http(let code, let reason): return reason.isEmpty ? "Server error (\(code))." : reason
        case .notSignedIn: return "Please sign in."
        case .invalidInviteCode: return "That invite code wasn't recognised. Check it with your clinician."
        }
    }
}

/// What to run in a session sheet.
public struct SessionLaunch: Identifiable, Sendable {
    public var id = UUID()
    public var title: String
    public var kind: SessionSummary.Kind
    public var mode: AppMode
    public var plan: [PlannedExercise]
    public var policy: SymptomPolicy
    public var programId: UUID?
    public var templateId: String?
    public var askPain: Bool

    public init(title: String, kind: SessionSummary.Kind, mode: AppMode, plan: [PlannedExercise], policy: SymptomPolicy,
                programId: UUID? = nil, templateId: String? = nil, askPain: Bool) {
        self.title = title
        self.kind = kind
        self.mode = mode
        self.plan = plan
        self.policy = policy
        self.programId = programId
        self.templateId = templateId
        self.askPain = askPain
    }

    public static func template(_ template: SessionTemplate, gentleOnly: Bool = false) -> SessionLaunch {
        var plan = template.plan()
        if gentleOnly { plan = plan.filter { $0.spec.loads.impact <= .low && $0.spec.intensity <= 2 } }
        let isBaseline = template.id.hasSuffix("baseline")
        return SessionLaunch(
            title: template.title,
            kind: isBaseline ? .baseline : (template.isSnack ? .snack : .workout),
            mode: template.mode,
            plan: plan,
            policy: template.mode == .rehab ? .rehabDefault : .moveDefault,
            templateId: template.id,
            askPain: template.mode == .rehab
        )
    }

    public static func program(_ program: Program) -> SessionLaunch {
        SessionLaunch(title: program.title, kind: .program, mode: .rehab, plan: program.plan(), policy: program.symptomPolicy,
                      programId: program.id, askPain: true)
    }
}
