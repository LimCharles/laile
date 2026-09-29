import Foundation

/// The coach voices users can pick from. All are ElevenLabs built-in voices, which every
/// ElevenLabs plan can use through the API. The server only ever renders these (a whitelist),
/// so the app can't make it spend credits on arbitrary voices.
public enum CoachVoice: String, Codable, Sendable, CaseIterable, Identifiable, Hashable {
    case sarah, jessica, matilda, chris

    public static let `default`: CoachVoice = .sarah

    public var id: String { rawValue }

    public var displayName: String {
        switch self {
        case .sarah: return "Sarah"
        case .jessica: return "Jessica"
        case .matilda: return "Matilda"
        case .chris: return "Chris"
        }
    }

    public var blurb: String {
        switch self {
        case .sarah: return "Calm and reassuring"
        case .jessica: return "Warm and bright"
        case .matilda: return "Upbeat and clear"
        case .chris: return "Friendly and down-to-earth"
        }
    }

    public var elevenLabsVoiceId: String {
        switch self {
        case .sarah: return "EXAVITQu4vr4xnSDxMaL"
        case .jessica: return "cgSgspJ2msm6clMCkdW9"
        case .matilda: return "XrExE9yKIg1WjnnlVkGX"
        case .chris: return "iP95p4xoKVk53GoZ742B"
        }
    }

    /// Played when previewing a voice.
    public static let sampleLine = CueLine("Hi, I'm Lele, your coach from Laile. Hold it there... three, two, one, and relax. Nice work!", key: "voice.sample")
}
