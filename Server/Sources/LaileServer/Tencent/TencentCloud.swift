import Crypto
import Foundation
import LaileCore
import Vapor

/// Tencent Cloud API v3 request signing (TC3-HMAC-SHA256).
struct TC3Signer: Sendable {
    let secretId: String
    let secretKey: String

    struct Signed: Sendable {
        var authorization: String
        var timestamp: Int
    }

    func sign(service: String, host: String, payload: Data, timestamp: Int, contentType: String = "application/json; charset=utf-8") -> Signed {
        let date = DayKey(Date(timeIntervalSince1970: TimeInterval(timestamp)), timeZone: TimeZone(identifier: "UTC")!).description
        let signedHeaders = "content-type;host"
        let canonicalRequest = [
            "POST", "/", "",
            "content-type:\(contentType)\nhost:\(host)\n",
            signedHeaders,
            Self.hex(SHA256.hash(data: payload)),
        ].joined(separator: "\n")
        let scope = "\(date)/\(service)/tc3_request"
        let stringToSign = ["TC3-HMAC-SHA256", "\(timestamp)", scope, Self.hex(SHA256.hash(data: Data(canonicalRequest.utf8)))].joined(separator: "\n")

        let secretDate = hmac(key: Data("TC3\(secretKey)".utf8), date)
        let secretService = hmac(key: secretDate, service)
        let secretSigning = hmac(key: secretService, "tc3_request")
        let signature = Self.hex(HMAC<SHA256>.authenticationCode(for: Data(stringToSign.utf8), using: SymmetricKey(data: secretSigning)))

        return Signed(
            authorization: "TC3-HMAC-SHA256 Credential=\(secretId)/\(scope), SignedHeaders=\(signedHeaders), Signature=\(signature)",
            timestamp: timestamp
        )
    }

    private func hmac(key: Data, _ message: String) -> Data {
        Data(HMAC<SHA256>.authenticationCode(for: Data(message.utf8), using: SymmetricKey(data: key)))
    }

    static func hex<D: Sequence>(_ digest: D) -> String where D.Element == UInt8 {
        digest.map { String(format: "%02x", $0) }.joined()
    }
}

/// Calls any Tencent Cloud API action (TRTC, TTS, ...).
struct TencentCloudClient: Sendable {
    let credentials: LaileConfig.TencentCredentials
    let client: any Client

    struct APIError: Error, CustomStringConvertible {
        var code: String
        var message: String
        var description: String { "Tencent Cloud \(code): \(message)" }
    }

    func call<Body: Encodable>(service: String, host: String, action: String, version: String, region: String? = nil, body: Body) async throws -> [String: JSONValue] {
        let payload = try JSONEncoder().encode(body)
        let timestamp = Int(Date().timeIntervalSince1970)
        let signed = TC3Signer(secretId: credentials.secretId, secretKey: credentials.secretKey)
            .sign(service: service, host: host, payload: payload, timestamp: timestamp)

        var headers = HTTPHeaders()
        headers.add(name: "Authorization", value: signed.authorization)
        headers.add(name: "Content-Type", value: "application/json; charset=utf-8")
        headers.add(name: "Host", value: host)
        headers.add(name: "X-TC-Action", value: action)
        headers.add(name: "X-TC-Timestamp", value: "\(timestamp)")
        headers.add(name: "X-TC-Version", value: version)
        headers.add(name: "X-TC-Region", value: region ?? credentials.region)

        let response = try await client.post(URI(string: "https://\(host)/"), headers: headers) { req in
            req.body = ByteBuffer(data: payload)
        }
        let json = try response.content.decode([String: JSONValue].self, using: JSONDecoder())
        guard case .object(let inner)? = json["Response"] else { throw APIError(code: "BadResponse", message: "Missing Response") }
        if case .object(let error)? = inner["Error"] {
            var code = "Unknown", message = ""
            if case .string(let c)? = error["Code"] { code = c }
            if case .string(let m)? = error["Message"] { message = m }
            throw APIError(code: code, message: message)
        }
        return inner
    }
}

/// TRTC UserSig (TLSSigAPIv2): HMAC-SHA256 over the identity fields, zlib-wrapped, URL-safe base64.
enum TRTCUserSig {
    static func generate(userId: String, sdkAppId: Int, secretKey: String, expireSeconds: Int = 86_400, now: Int = Int(Date().timeIntervalSince1970)) -> String {
        let content = "TLS.identifier:\(userId)\nTLS.sdkappid:\(sdkAppId)\nTLS.time:\(now)\nTLS.expire:\(expireSeconds)\n"
        let sig = Data(HMAC<SHA256>.authenticationCode(for: Data(content.utf8), using: SymmetricKey(data: Data(secretKey.utf8)))).base64EncodedString()
        let document: [String: Any] = [
            "TLS.ver": "2.0", "TLS.identifier": userId, "TLS.sdkappid": sdkAppId,
            "TLS.expire": expireSeconds, "TLS.time": now, "TLS.sig": sig,
        ]
        let json = (try? JSONSerialization.data(withJSONObject: document, options: [.sortedKeys])) ?? Data()
        return zlibStored(json).base64EncodedString()
            .replacingOccurrences(of: "+", with: "*")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: "=", with: "_")
    }

    /// A valid zlib stream using uncompressed ("stored") deflate blocks — any inflater accepts
    /// it, and it needs no native zlib on Linux.
    static func zlibStored(_ data: Data) -> Data {
        var out = Data([0x78, 0x01])
        let bytes = [UInt8](data)
        var offset = 0
        repeat {
            let chunk = min(65_535, bytes.count - offset)
            let isFinal = offset + chunk >= bytes.count
            out.append(isFinal ? 0x01 : 0x00)
            let len = UInt16(chunk), nlen = ~len
            out.append(contentsOf: [UInt8(len & 0xFF), UInt8(len >> 8), UInt8(nlen & 0xFF), UInt8(nlen >> 8)])
            out.append(contentsOf: bytes[offset..<(offset + chunk)])
            offset += chunk
        } while offset < bytes.count
        var a: UInt32 = 1, b: UInt32 = 0
        for byte in bytes {
            a = (a + UInt32(byte)) % 65_521
            b = (b + a) % 65_521
        }
        let adler = (b << 16) | a
        out.append(contentsOf: [UInt8(adler >> 24), UInt8((adler >> 16) & 0xFF), UInt8((adler >> 8) & 0xFF), UInt8(adler & 0xFF)])
        return out
    }
}

/// TRTC Conversational AI: starts/stops a server-side voice agent in a TRTC room. The agent
/// does streaming speech recognition + TTS and calls our /v1/voice/llm endpoint for each turn.
struct TRTCConversationClient: Sendable {
    let cloud: TencentCloudClient
    let trtc: LaileConfig.TRTC
    /// JSON string for TRTC's TTSConfig (see `SpeechConfig.trtcTTSConfigJSON`).
    let ttsConfigJSON: String
    /// International TRTC API host (regions incl. ap-singapore).
    var host: String = Environment.get("TRTC_API_HOST") ?? "trtc.intl.tencentcloudapi.com"

    struct StartRequest: Encodable {
        struct AgentConfig: Encodable {
            var UserId: String
            var UserSig: String
            var TargetUserId: String
            var MaxIdleTime: Int
            var WelcomeMessage: String
            var InterruptMode: Int
        }

        struct STTConfig: Encodable {
            var Language: String
            var VadSilenceTime: Int
        }

        var SdkAppId: Int
        var RoomId: String
        var RoomIdType: Int
        var AgentConfig: AgentConfig
        var STTConfig: STTConfig
        /// JSON string, per the TRTC API.
        var LLMConfig: String
        /// JSON string, per the TRTC API.
        var TTSConfig: String
    }

    func start(roomId: String, userId: String, agentUserId: String, sessionKey: String, welcome: String) async throws -> String? {
        let llmConfig: [String: Any] = [
            // TRTC's name for the chat-completions wire format; the model behind it is our Hunyuan coach.
            "LLMType": "openai",
            "Model": "laile-coach",
            "APIKey": sessionKey,
            "APIUrl": "\(trtc.publicBaseURL)/v1/voice/llm/chat/completions",
            "Streaming": true,
        ]
        let body = StartRequest(
            SdkAppId: trtc.sdkAppId, RoomId: roomId, RoomIdType: 1,
            AgentConfig: .init(UserId: agentUserId,
                               UserSig: TRTCUserSig.generate(userId: agentUserId, sdkAppId: trtc.sdkAppId, secretKey: trtc.sdkSecretKey),
                               TargetUserId: userId, MaxIdleTime: 120, WelcomeMessage: welcome, InterruptMode: 0),
            STTConfig: .init(Language: trtc.sttLanguage, VadSilenceTime: 600),
            LLMConfig: jsonString(llmConfig),
            TTSConfig: ttsConfigJSON
        )
        let response = try await cloud.call(service: "trtc", host: host, action: "StartAIConversation", version: "2019-07-22", body: body)
        if case .string(let taskId)? = response["TaskId"] { return taskId }
        return nil
    }

    func stop(taskId: String) async throws {
        _ = try await cloud.call(service: "trtc", host: host, action: "StopAIConversation", version: "2019-07-22", body: ["TaskId": taskId])
    }

    private func jsonString(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}
