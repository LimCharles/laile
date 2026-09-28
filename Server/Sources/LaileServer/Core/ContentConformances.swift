import LaileCore
import Vapor

// Shared LaileCore types are plain Codable so the iOS app doesn't depend on Vapor.
// The server makes them `Content` here.
extension API.AuthResponse: @retroactive Content {}
extension API.ServerTime: @retroactive Content {}
extension API.UserProfile: @retroactive Content {}
extension API.TodayPlan: @retroactive Content {}
extension API.CheckInResponse: @retroactive Content {}
extension API.SessionSubmitResponse: @retroactive Content {}
extension API.ProgressOverview: @retroactive Content {}
extension API.CoachTurnResponse: @retroactive Content {}
extension API.VoiceSessionResponse: @retroactive Content {}
extension Program: @retroactive Content {}
extension ExerciseSpec: @retroactive Content {}
extension RewardsSummary: @retroactive Content {}
extension SessionSummary: @retroactive Content {}
extension StreamEvent: @retroactive Content {}
extension API.RegisterRequest: @retroactive Content {}
extension API.LoginRequest: @retroactive Content {}
extension API.LinkClinicianRequest: @retroactive Content {}
extension API.CoachTurnRequest: @retroactive Content {}
extension API.MedicationTakenRequest: @retroactive Content {}
extension API.VoiceSessionRequest: @retroactive Content {}
extension API.SpeakRequest: @retroactive Content {}
