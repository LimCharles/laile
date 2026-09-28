import Fluent
import LaileCore
import Vapor

/// A self-contained slice of the backend: its tables, its routes, its services.
protocol LaileFeature {
    var name: String { get }
    var migrations: [any Migration] { get }
    func boot(_ app: Application) async throws
}

extension LaileFeature {
    var migrations: [any Migration] { [] }
}

struct LaileConfig: Sendable {
    struct LLM: Sendable {
        /// Hunyuan chat-completions base URL.
        var baseURL: String
        var apiKey: String
        var model: String
    }

    struct TencentCredentials: Sendable {
        var secretId: String
        var secretKey: String
        var region: String
    }

    struct TRTC: Sendable {
        var sdkAppId: Int
        var sdkSecretKey: String
        /// Public URL TRTC's Conversational AI calls back into for LLM turns.
        var publicBaseURL: String
        var sttLanguage: String
    }

    var databaseURL: String?
    var sqlitePath: String
    var llm: LLM?
    var tencent: TencentCredentials?
    var trtc: TRTC?
    var seedDemoData: Bool
    var emergencyNumber: String
    var speech: SpeechConfig?

    static func fromEnvironment(_ env: Environment) -> LaileConfig {
        func value(_ key: String) -> String? {
            guard let v = Environment.get(key), !v.isEmpty else { return nil }
            return v
        }
        let llm = value("LLM_API_KEY").map { key in
            LLM(baseURL: value("LLM_BASE_URL") ?? "https://api.hunyuan.cloud.tencent.com/v1",
                apiKey: key,
                model: value("LLM_MODEL") ?? "hunyuan-turbos-latest")
        }
        let tencent: TencentCredentials? = {
            guard let id = value("TENCENTCLOUD_SECRET_ID"), let key = value("TENCENTCLOUD_SECRET_KEY") else { return nil }
            return TencentCredentials(secretId: id, secretKey: key, region: value("TENCENTCLOUD_REGION") ?? "ap-singapore")
        }()
        let trtc: TRTC? = {
            guard let app = value("TRTC_SDK_APP_ID").flatMap(Int.init), let secret = value("TRTC_SDK_SECRET_KEY"),
                  let base = value("PUBLIC_BASE_URL") else { return nil }
            return TRTC(sdkAppId: app, sdkSecretKey: secret, publicBaseURL: base,
                        sttLanguage: value("TRTC_STT_LANGUAGE") ?? "en")
        }()
        return LaileConfig(
            databaseURL: value("DATABASE_URL"),
            sqlitePath: value("SQLITE_PATH") ?? "laile.sqlite",
            llm: llm,
            tencent: tencent,
            trtc: trtc,
            seedDemoData: value("SEED_DEMO_DATA").map { $0 == "true" } ?? (env != .production),
            emergencyNumber: value("EMERGENCY_NUMBER") ?? "995",
            speech: SpeechConfig.fromEnvironment()
        )
    }
}

/// Shared services, reachable as `app.laile` / `req.laile`.
final class AppServices: Sendable {
    let config: LaileConfig
    let llm: any LLMProvider
    /// The coach's voice (ElevenLabs, or Tencent TTS as fallback), if configured.
    let speech: (any SpeechSynthesizer)?
    let speechCache: SpeechCache
    let library = ExerciseLibrary.standard
    let streamHub = StreamHub()
    let voiceSessions = VoiceSessionStore()

    init(config: LaileConfig, llm: any LLMProvider, speech: (any SpeechSynthesizer)? = nil) {
        self.config = config
        self.llm = llm
        self.speech = speech
        self.speechCache = SpeechCache(directory: config.speech?.cacheDirectory ?? "voice-cache")
    }

    func rewardEngine(timeZone: String) -> RewardEngine {
        RewardEngine(timeZone: TimeZone(identifier: timeZone) ?? TimeZone(identifier: "Asia/Singapore")!)
    }
}

extension Application {
    private struct ServicesKey: StorageKey { typealias Value = AppServices }

    var laile: AppServices {
        get {
            guard let services = storage[ServicesKey.self] else { fatalError("configure(_:) must set app.laile") }
            return services
        }
        set { storage[ServicesKey.self] = newValue }
    }
}

extension Request {
    var laile: AppServices { application.laile }
}

extension Abort {
    static func badRequest(_ reason: String) -> Abort { Abort(.badRequest, reason: reason) }
}
