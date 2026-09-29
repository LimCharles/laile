import Foundation

/// Request/response types shared by the iOS app and the Vapor server.
public enum API {
    public enum UserRole: String, Codable, Sendable, CaseIterable, Hashable {
        case mover, patient, clinician, admin
    }

    public struct UserProfile: Codable, Sendable, Hashable, Identifiable {
        public var id: UUID
        public var email: String
        public var displayName: String
        public var role: UserRole
        public var mode: AppMode
        public var timeZone: String
        public var clinicianName: String?
        /// Demo account: data resets whenever the demo is started or the account signs in.
        public var isDemo: Bool

        public init(id: UUID, email: String, displayName: String, role: UserRole, mode: AppMode, timeZone: String,
                    clinicianName: String? = nil, isDemo: Bool = false) {
            self.id = id
            self.email = email
            self.displayName = displayName
            self.role = role
            self.mode = mode
            self.timeZone = timeZone
            self.clinicianName = clinicianName
            self.isDemo = isDemo
        }
    }

    public enum DemoPersona: String, Codable, Sendable, CaseIterable {
        /// Knee-replacement patient, linked to the demo clinician, two weeks into rehab.
        case patient
        /// Everyday Move-mode user with a week of quick sessions.
        case mover
    }

    public struct DemoStartRequest: Codable, Sendable {
        public var persona: DemoPersona
        public var timeZone: String
        public init(persona: DemoPersona, timeZone: String) { self.persona = persona; self.timeZone = timeZone }
    }

    public struct LoginRequest: Codable, Sendable {
        public var email: String
        public var password: String
        public init(email: String, password: String) { self.email = email; self.password = password }
    }

    public struct RegisterRequest: Codable, Sendable {
        public var email: String
        public var password: String
        public var displayName: String
        public var timeZone: String
        public init(email: String, password: String, displayName: String, timeZone: String) {
            self.email = email; self.password = password; self.displayName = displayName; self.timeZone = timeZone
        }
    }

    public struct AuthResponse: Codable, Sendable {
        public var token: String
        public var user: UserProfile
        public init(token: String, user: UserProfile) { self.token = token; self.user = user }
    }

    public struct CheckInResponse: Codable, Sendable {
        public var outcome: CheckInOutcome
        public var summary: RewardsSummary
        public init(outcome: CheckInOutcome, summary: RewardsSummary) { self.outcome = outcome; self.summary = summary }
    }

    public struct SessionSubmitResponse: Codable, Sendable {
        public var movement: MovementOutcome
        public var achievements: [Achievement]
        public var summary: RewardsSummary
        /// Lele's notes that this session created or moved on (e.g. "heel slides eased for next time").
        public var careNotes: [CareNote]
        public init(movement: MovementOutcome, achievements: [Achievement], summary: RewardsSummary, careNotes: [CareNote] = []) {
            self.movement = movement; self.achievements = achievements; self.summary = summary; self.careNotes = careNotes
        }
    }

    public struct TodayPlan: Codable, Sendable {
        public var mode: AppMode
        public var program: Program?
        public var clinicianName: String?
        public var templates: [SessionTemplate]
        public var medicationDoses: [MedicationDose]
        /// Lele's active notes. Sessions apply them (easier targets) with `CareMemory.adjust`.
        public var careNotes: [CareNote]
        public init(mode: AppMode, program: Program?, clinicianName: String?, templates: [SessionTemplate], medicationDoses: [MedicationDose],
                    careNotes: [CareNote] = []) {
            self.mode = mode; self.program = program; self.clinicianName = clinicianName
            self.templates = templates; self.medicationDoses = medicationDoses; self.careNotes = careNotes
        }
    }

    public struct ProgressOverview: Codable, Sendable {
        public var trends: [MetricTrend]
        public var recentSessions: [SessionSummary]
        public init(trends: [MetricTrend], recentSessions: [SessionSummary]) { self.trends = trends; self.recentSessions = recentSessions }
    }

    public struct LinkClinicianRequest: Codable, Sendable {
        public var inviteCode: String
        public init(inviteCode: String) { self.inviteCode = inviteCode }
    }

    public struct MedicationTakenRequest: Codable, Sendable {
        public var medicationId: UUID
        public var scheduled: TimeOfDay
        public init(medicationId: UUID, scheduled: TimeOfDay) { self.medicationId = medicationId; self.scheduled = scheduled }
    }

    public struct ServerTime: Codable, Sendable {
        public var now: Date
        public init(now: Date) { self.now = now }
    }

    /// Live context the phone pushes to the voice agent so it knows what you're doing.
    public struct VoiceContext: Codable, Sendable, Hashable {
        public var exerciseName: String?
        public var exerciseId: String?
        public var setIndex: Int?
        public var totalSets: Int?
        public var reps: Int?
        public var holdSeconds: Int?
        public var angle: Double?
        public var phase: String
        public var awaitingPainRating: Bool

        public init(exerciseName: String? = nil, exerciseId: String? = nil, setIndex: Int? = nil, totalSets: Int? = nil,
                    reps: Int? = nil, holdSeconds: Int? = nil, angle: Double? = nil, phase: String, awaitingPainRating: Bool = false) {
            self.exerciseName = exerciseName; self.exerciseId = exerciseId; self.setIndex = setIndex; self.totalSets = totalSets
            self.reps = reps; self.holdSeconds = holdSeconds; self.angle = angle; self.phase = phase
            self.awaitingPainRating = awaitingPainRating
        }
    }

    public struct VoiceSessionRequest: Codable, Sendable {
        public var language: String
        public var context: VoiceContext
        public var voice: CoachVoice?
        public init(language: String, context: VoiceContext, voice: CoachVoice? = nil) {
            self.language = language; self.context = context; self.voice = voice
        }
    }

    /// Text to speak in one of the coach voices (server-side ElevenLabs).
    public struct SpeakRequest: Codable, Sendable {
        public var text: String
        public var voice: CoachVoice?
        public init(text: String, voice: CoachVoice? = nil) { self.text = text; self.voice = voice }
    }

    /// Everything the phone needs to join the TRTC room the voice agent is in.
    public struct VoiceSessionResponse: Codable, Sendable {
        public var sessionKey: String
        public var sdkAppId: Int
        public var roomId: String
        public var userId: String
        public var userSig: String
        public var agentUserId: String
        public var taskId: String?
        public init(sessionKey: String, sdkAppId: Int, roomId: String, userId: String, userSig: String, agentUserId: String, taskId: String?) {
            self.sessionKey = sessionKey; self.sdkAppId = sdkAppId; self.roomId = roomId; self.userId = userId
            self.userSig = userSig; self.agentUserId = agentUserId; self.taskId = taskId
        }
    }

    /// Messages on the voice-events WebSocket.
    public enum VoiceSocketMessage: Codable, Sendable, Hashable {
        /// Phone → server: current exercise state.
        case context(VoiceContext)
        /// Server → phone: the agent heard a symptom; the phone's conductor applies the rules.
        case symptom(SymptomReport)
        /// Server → phone: a transcript line for on-screen captions.
        case caption(speaker: String, text: String)
    }

    /// One coach turn without TRTC: the phone transcribes on-device, the server's coach
    /// (Hunyuan + safety rules) replies, and the phone speaks the reply.
    public struct CoachTurnRequest: Codable, Sendable {
        public var utterance: String
        public var context: VoiceContext
        public init(utterance: String, context: VoiceContext) { self.utterance = utterance; self.context = context }
    }

    public struct CoachTurnResponse: Codable, Sendable {
        public var reply: String
        public var report: SymptomReport?
        public init(reply: String, report: SymptomReport?) { self.reply = reply; self.report = report }
    }

    public struct ErrorResponse: Codable, Sendable {
        public var error: Bool
        public var reason: String
    }
}

public enum LaileJSON {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.sortedKeys]
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}

/// Clinician invite codes ("LAI-7KQ2MX"). Typed codes are normalised so smart-punctuation
/// dashes, spaces and case never cause a mismatch.
public enum InviteCode {
    public static func normalize(_ raw: String) -> String {
        let alphanumerics = raw.uppercased().unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) && $0.isASCII }
        let compact = String(String.UnicodeScalarView(alphanumerics))
        guard compact.hasPrefix("LAI"), compact.count > 3 else { return compact }
        return "LAI-" + compact.dropFirst(3)
    }
}
