import Crypto
import Foundation
import LaileCore
import Vapor

/// Which voice the coach uses. Configured with environment variables; see `.env.example`.
///
/// - `elevenlabs` (default): the coach's voice. Used for pre-generated cues, for live replies via
///   `/v1/voice/speak`, and — natively — as the TTS inside TRTC Conversational AI.
/// - `tencent`: fallback — Tencent Cloud TTS for cues; TRTC's built-in "flow" voices for live calls.
struct SpeechConfig: Sendable {
    enum Provider: String, Sendable { case elevenlabs, tencent }

    var provider: Provider
    // ElevenLabs
    var elevenLabsKey: String?
    var elevenLabsVoiceId: String
    /// Model for pre-generated cues (quality first).
    var elevenLabsModel: String
    /// Model for live replies (latency first).
    var elevenLabsLiveModel: String
    // Tencent
    var tencentVoiceType: Int
    var trtcFlowVoiceId: String

    static func fromEnvironment() -> SpeechConfig? {
        func value(_ key: String) -> String? {
            guard let v = Environment.get(key), !v.isEmpty else { return nil }
            return v
        }
        let eleven = value("ELEVENLABS_API_KEY")
        let hasTencent = value("TENCENTCLOUD_SECRET_ID") != nil && value("TENCENTCLOUD_SECRET_KEY") != nil
        let provider: Provider? = value("TTS_PROVIDER").flatMap(Provider.init(rawValue:))
            ?? (eleven != nil ? .elevenlabs : hasTencent ? .tencent : nil)
        guard let provider else { return nil }
        return SpeechConfig(
            provider: provider,
            elevenLabsKey: eleven,
            elevenLabsVoiceId: value("ELEVENLABS_VOICE_ID") ?? "21m00Tcm4TlvDq8ikWAM",
            elevenLabsModel: value("ELEVENLABS_MODEL") ?? "eleven_multilingual_v2",
            elevenLabsLiveModel: value("ELEVENLABS_LIVE_MODEL") ?? "eleven_flash_v2_5",
            tencentVoiceType: value("TENCENT_TTS_VOICE_TYPE").flatMap(Int.init) ?? 601005,
            trtcFlowVoiceId: value("TRTC_FLOW_VOICE_ID") ?? "v-female-R2s4N9qJ"
        )
    }

    /// TTSConfig for TRTC Conversational AI. ElevenLabs is a native TRTC TTS provider, so the
    /// live agent speaks with the same voice as the pre-generated cues.
    var trtcTTSConfigJSON: String {
        let object: [String: Any]
        if provider == .elevenlabs, let key = elevenLabsKey {
            object = ["TTSType": "elevenlabs", "Model": elevenLabsLiveModel, "APIKey": key, "VoiceId": elevenLabsVoiceId]
        } else {
            // No ElevenLabs key: fall back to TRTC's built-in voices.
            object = ["TTSType": "flow", "Model": "flow_01_turbo", "VoiceId": trtcFlowVoiceId, "Language": "en", "Speed": 1.0]
        }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}

protocol SpeechSynthesizer: Sendable {
    var name: String { get }
    /// MP3 audio. `live` trades a little quality for latency.
    func synthesize(_ text: String, live: Bool) async throws -> Data
}

struct SpeechError: Error, CustomStringConvertible {
    var description: String
}

struct ElevenLabsSynthesizer: SpeechSynthesizer {
    let apiKey: String
    let voiceId: String
    let model: String
    let liveModel: String
    let client: any Client

    var name: String { "ElevenLabs (\(model))" }

    struct Body: Content {
        struct VoiceSettings: Codable { var stability: Double; var similarity_boost: Double }
        var text: String
        var model_id: String
        var voice_settings: VoiceSettings
    }

    func synthesize(_ text: String, live: Bool) async throws -> Data {
        var headers = HTTPHeaders()
        headers.add(name: "xi-api-key", value: apiKey)
        headers.add(name: .accept, value: "audio/mpeg")
        let url = URI(string: "https://api.elevenlabs.io/v1/text-to-speech/\(voiceId)?output_format=mp3_44100_128")
        let body = Body(text: text, model_id: live ? liveModel : model, voice_settings: .init(stability: 0.5, similarity_boost: 0.8))
        let response = try await client.post(url, headers: headers) { req in try req.content.encode(body, using: JSONEncoder()) }
        guard response.status == .ok, let buffer = response.body else {
            let detail = response.body.map { String(buffer: $0) } ?? ""
            throw SpeechError(description: "ElevenLabs HTTP \(response.status.code): \(detail.prefix(200))")
        }
        return Data(buffer: buffer)
    }
}

/// Tencent Cloud Text-To-Speech (TextToVoice).
struct TencentSynthesizer: SpeechSynthesizer {
    let cloud: TencentCloudClient
    let voiceType: Int
    var host = "tts.tencentcloudapi.com"

    var name: String { "Tencent Cloud TTS (\(voiceType))" }

    struct TextToVoiceRequest: Encodable {
        var Text: String
        var SessionId: String
        var VoiceType: Int
        var Codec: String
        var SampleRate: Int
        var PrimaryLanguage: Int
        var ModelType: Int
        var Speed: Double
    }

    func synthesize(_ text: String, live: Bool) async throws -> Data {
        let body = TextToVoiceRequest(Text: text, SessionId: UUID().uuidString, VoiceType: voiceType, Codec: "mp3",
                                      SampleRate: 16_000, PrimaryLanguage: 2, ModelType: 1, Speed: 0)
        let response = try await cloud.call(service: "tts", host: host, action: "TextToVoice", version: "2019-08-23", body: body)
        guard case .string(let base64)? = response["Audio"], let data = Data(base64Encoded: base64) else {
            throw SpeechError(description: "Tencent TTS returned no audio")
        }
        return data
    }
}

enum SpeechFactory {
    static func make(config: SpeechConfig?, tencent: LaileConfig.TencentCredentials?, client: any Client) -> (any SpeechSynthesizer)? {
        guard let config else { return nil }
        switch config.provider {
        case .elevenlabs:
            guard let key = config.elevenLabsKey else { return nil }
            return ElevenLabsSynthesizer(apiKey: key, voiceId: config.elevenLabsVoiceId, model: config.elevenLabsModel,
                                         liveModel: config.elevenLabsLiveModel, client: client)
        case .tencent:
            guard let tencent else { return nil }
            return TencentSynthesizer(cloud: TencentCloudClient(credentials: tencent, client: client), voiceType: config.tencentVoiceType)
        }
    }
}

/// Small in-memory cache so repeated live lines ("Okay, noted. Keep going.") cost nothing.
actor SpeechCache {
    private var entries: [String: Data] = [:]
    private var order: [String] = []
    private let limit = 200

    func get(_ key: String) -> Data? { entries[key] }

    func put(_ key: String, _ data: Data) {
        if entries[key] == nil { order.append(key) }
        entries[key] = data
        while order.count > limit { entries[order.removeFirst()] = nil }
    }
}

struct SpeakRequest: Content {
    var text: String
}

struct SpeechFeature: LaileFeature {
    let name = "speech"

    func boot(_ app: Application) async throws {
        // Live TTS for the phone (LLM replies that can't be pre-generated). Keys stay server-side.
        app.protected.post("voice", "speak") { req async throws -> Response in
            guard let synth = req.laile.speech else {
                throw Abort(.serviceUnavailable, reason: "No TTS provider configured; the app will use its on-device voice.")
            }
            let text = try req.content.decode(SpeakRequest.self).text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, text.count <= 600 else { throw Abort(.badRequest, reason: "Text must be 1–600 characters.") }
            let key = CueLine(text).audioKey
            let audio: Data
            if let cached = await req.laile.speechCache.get(key) {
                audio = cached
            } else {
                audio = try await synth.synthesize(text, live: true)
                await req.laile.speechCache.put(key, audio)
            }
            var headers = HTTPHeaders()
            headers.contentType = HTTPMediaType(type: "audio", subType: "mpeg")
            headers.add(name: .cacheControl, value: "private, max-age=86400")
            return Response(status: .ok, headers: headers, body: .init(data: audio))
        }
    }
}

/// `swift run LaileServer generate-cues --output <dir>` — renders every line in `CueCatalog`
/// with the ElevenLabs voice into `<audioKey>.mp3` files plus a
/// manifest, for bundling in the iOS app. Existing files are skipped unless `--force`.
struct GenerateCuesCommand: AsyncCommand {
    struct Signature: CommandSignature {
        @Option(name: "output", help: "Directory for <audioKey>.mp3 files (default ../iOS/Laile/Resources/Cues)")
        var output: String?

        @Flag(name: "force", help: "Re-render files that already exist")
        var force: Bool

        @Flag(name: "prune", help: "Delete .mp3 files that are no longer in the catalog")
        var prune: Bool
    }

    var help: String { "Pre-generate the coach's voice lines with the configured TTS provider." }

    func run(using context: CommandContext, signature: Signature) async throws {
        let app = context.application
        guard let synth = app.laile.speech else {
            context.console.error("No voice configured. Set ELEVENLABS_API_KEY (or Tencent Cloud credentials for the fallback voice).")
            return
        }
        let output = URL(fileURLWithPath: signature.output ?? "../iOS/Laile/Resources/Cues")
        try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
        let lines = CueCatalog.all(emergencyNumber: app.laile.config.emergencyNumber)
        context.console.print("Rendering \(lines.count) lines with \(synth.name) → \(output.path)")

        var manifest: [String: [String: String]] = [:]
        var rendered = 0, skipped = 0
        for line in lines {
            manifest[line.audioKey] = ["text": line.text, "label": line.key ?? ""]
            let file = output.appendingPathComponent("\(line.audioKey).mp3")
            if !signature.force && FileManager.default.fileExists(atPath: file.path) {
                skipped += 1
                continue
            }
            do {
                let audio = try await synth.synthesize(line.text, live: false)
                try audio.write(to: file)
                rendered += 1
                context.console.print("✓ \(line.text.prefix(70))")
            } catch {
                context.console.error("✗ \(line.text.prefix(50)): \(error)")
            }
        }
        let manifestData = try JSONSerialization.data(withJSONObject: ["voice": synth.name, "lines": manifest], options: [.prettyPrinted, .sortedKeys])
        try manifestData.write(to: output.appendingPathComponent("manifest.json"))

        if signature.prune {
            let keep = Set(lines.map { "\($0.audioKey).mp3" })
            for file in (try? FileManager.default.contentsOfDirectory(atPath: output.path)) ?? [] where file.hasSuffix(".mp3") && !keep.contains(file) {
                try? FileManager.default.removeItem(at: output.appendingPathComponent(file))
            }
        }
        context.console.success("Done: \(rendered) rendered, \(skipped) already present.")
    }
}
