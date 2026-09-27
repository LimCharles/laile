import Fluent
import LaileCore
import Vapor

/// State for one live voice session (one TRTC room / one exercise session).
actor VoiceSessionStore {
    struct Session {
        var key: String
        var userID: UUID
        var userName: String
        var mode: AppMode
        var policy: SymptomPolicy
        var context: API.VoiceContext?
        var history: [ChatMessage] = []
        var socket: WebSocket?
        var taskId: String?
        var createdAt = Date()
    }

    private var sessions: [String: Session] = [:]

    func create(_ session: Session) { sessions[session.key] = session }
    func get(_ key: String) -> Session? { sessions[key] }
    func remove(_ key: String) -> Session? { sessions.removeValue(forKey: key) }
    func setTask(_ key: String, _ taskId: String?) { sessions[key]?.taskId = taskId }
    func setContext(_ key: String, _ context: API.VoiceContext) { sessions[key]?.context = context }
    func attach(_ key: String, socket: WebSocket) { sessions[key]?.socket = socket }

    func appendTurn(_ key: String, user: String, assistant: String) {
        sessions[key]?.history.append(.user(user))
        sessions[key]?.history.append(.assistant(assistant))
        if let count = sessions[key]?.history.count, count > 20 { sessions[key]?.history.removeFirst(count - 20) }
    }

    func push(_ key: String, _ message: API.VoiceSocketMessage) async {
        guard let socket = sessions[key]?.socket, let data = try? LaileJSON.encoder().encode(message) else { return }
        try? await socket.send(String(decoding: data, as: UTF8.self))
    }

    /// Drop sessions older than six hours.
    func sweep(now: Date = Date()) {
        sessions = sessions.filter { now.timeIntervalSince($0.value.createdAt) < 6 * 3600 }
    }
}

/// Chat-completions request TRTC Conversational AI sends to our custom LLM endpoint.
struct ChatCompletionRequest: Content {
    var model: String?
    var messages: [ChatMessage]
    var stream: Bool?
}

struct VoiceFeature: LaileFeature {
    let name = "voice"

    func boot(_ app: Application) async throws {
        let api = app.protected.grouped("voice")
        api.post("sessions", use: startSession)
        api.delete("sessions", ":key", use: stopSession)
        api.post("turn", use: coachTurn)

        app.webSocket("v1", "voice", "sessions", ":key", "events") { req, ws async in
            guard let key = req.parameters.get("key"),
                  let user = try? await StreamsFeature.userFromQueryToken(req),
                  let session = await req.laile.voiceSessions.get(key),
                  session.userID == user.id else {
                try? await ws.close(code: .policyViolation)
                return
            }
            let store = req.laile.voiceSessions
            await store.attach(key, socket: ws)
            ws.onText { _, text async in
                guard let message = try? LaileJSON.decoder().decode(API.VoiceSocketMessage.self, from: Data(text.utf8)),
                      case .context(let context) = message else { return }
                await store.setContext(key, context)
            }
        }

        // TRTC → us, once per user utterance. Authenticated by the per-session key we gave TRTC.
        app.post("v1", "voice", "llm", "chat", "completions", use: trtcLLMTurn)
        app.post("v1", "voice", "llm", use: trtcLLMTurn)
    }

    func policy(for user: UserModel, on db: Database) async throws -> SymptomPolicy {
        guard user.mode == .rehab, let profile = try await user.patientProfile(on: db) else { return .moveDefault }
        if let program = try await ProgramModel.activeSigned(for: profile.requireID(), on: db)?.program {
            return program.symptomPolicy
        }
        return SymptomPolicy(painStopSetAbove: profile.painStopSetAbove, painStopExerciseAt: max(profile.painStopSetAbove + 2, 6), mode: .rehab)
    }

    func startSession(req: Request) async throws -> API.VoiceSessionResponse {
        guard let trtc = req.laile.config.trtc, let credentials = req.laile.config.tencent else {
            throw Abort(.serviceUnavailable, reason: "Cloud voice isn't configured on this server; the app will use on-device voice.")
        }
        let user = try req.user
        let body = try req.content.decode(API.VoiceSessionRequest.self)
        let key = [UInt8].random(count: 24).base64.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "+", with: "-")
        let short = String(try user.requireID().uuidString.prefix(8)).lowercased()
        let roomId = "laile-\(short)-\(Int(Date().timeIntervalSince1970))"
        let userId = "user-\(short)"
        let agentId = "coach-\(short)"

        await req.laile.voiceSessions.create(.init(key: key, userID: try user.requireID(), userName: user.displayName, mode: user.mode,
                                                   policy: try await policy(for: user, on: req.db), context: body.context))
        let ttsJSON = req.laile.config.speech?.trtcTTSConfigJSON
            ?? #"{"TTSType":"flow","Model":"flow_01_turbo","VoiceId":"v-female-R2s4N9qJ","Language":"en"}"#
        let conversation = TRTCConversationClient(cloud: TencentCloudClient(credentials: credentials, client: req.client), trtc: trtc,
                                                  ttsConfigJSON: ttsJSON)
        let taskId = try await conversation.start(roomId: roomId, userId: userId, agentUserId: agentId, sessionKey: key,
                                                  welcome: "Hi \(user.displayName)! I'm listening — tell me how things feel as we go.")
        await req.laile.voiceSessions.setTask(key, taskId)
        return API.VoiceSessionResponse(sessionKey: key, sdkAppId: trtc.sdkAppId, roomId: roomId, userId: userId,
                                        userSig: TRTCUserSig.generate(userId: userId, sdkAppId: trtc.sdkAppId, secretKey: trtc.sdkSecretKey),
                                        agentUserId: agentId, taskId: taskId)
    }

    func stopSession(req: Request) async throws -> HTTPStatus {
        guard let key = req.parameters.get("key"), let session = await req.laile.voiceSessions.remove(key) else { return .noContent }
        guard session.userID == (try req.user.id) else { throw Abort(.forbidden) }
        if let taskId = session.taskId, let trtc = req.laile.config.trtc, let credentials = req.laile.config.tencent {
            try? await TRTCConversationClient(cloud: TencentCloudClient(credentials: credentials, client: req.client), trtc: trtc,
                                              ttsConfigJSON: "{}").stop(taskId: taskId)
        }
        try? await session.socket?.close()
        return .noContent
    }

    /// Phone-driven turn (on-device speech recognition, cloud coach). Works without TRTC.
    func coachTurn(req: Request) async throws -> API.CoachTurnResponse {
        let user = try req.user
        let body = try req.content.decode(API.CoachTurnRequest.self)
        let agent = CoachAgent(llm: req.laile.llm, logger: req.logger)
        let turn = await agent.respond(to: body.utterance, history: [], context: body.context, mode: user.mode,
                                       userName: user.displayName, policy: try await policy(for: user, on: req.db))
        return API.CoachTurnResponse(reply: turn.reply, report: turn.report)
    }

    func trtcLLMTurn(req: Request) async throws -> Response {
        guard let key = req.headers.bearerAuthorization?.token, let session = await req.laile.voiceSessions.get(key) else {
            throw Abort(.unauthorized)
        }
        let body = try req.content.decode(ChatCompletionRequest.self, using: JSONDecoder())
        let utterance = body.messages.last { $0.role == "user" }?.content ?? ""
        let agent = CoachAgent(llm: req.laile.llm, logger: req.logger)
        let turn = await agent.respond(to: utterance, history: session.history, context: session.context, mode: session.mode,
                                       userName: session.userName, policy: session.policy)

        let store = req.laile.voiceSessions
        await store.appendTurn(key, user: utterance, assistant: turn.reply)
        await store.push(key, .caption(speaker: "you", text: utterance))
        await store.push(key, .caption(speaker: "coach", text: turn.reply))
        if let report = turn.report { await store.push(key, .symptom(report)) }

        return try ChatCompletionWriter.response(text: turn.reply, stream: body.stream ?? false)
    }
}

/// Formats a reply in the chat-completions format TRTC Conversational AI expects.
enum ChatCompletionWriter {
    static func response(text: String, stream: Bool) throws -> Response {
        let id = "chatcmpl-\(UUID().uuidString.prefix(12))"
        let created = Int(Date().timeIntervalSince1970)
        if stream {
            // Chunk by sentence-ish pieces so TTS can start speaking early.
            let pieces = text.split(separator: " ", omittingEmptySubsequences: false).chunked(into: 6).map { $0.joined(separator: " ") }
            var sse = ""
            for (i, piece) in pieces.enumerated() {
                let content = i == 0 ? piece : " " + piece
                let chunk: [String: Any] = [
                    "id": id, "object": "chat.completion.chunk", "created": created, "model": "laile-coach",
                    "choices": [["index": 0, "delta": ["role": "assistant", "content": content], "finish_reason": NSNull()]],
                ]
                sse += "data: \(json(chunk))\n\n"
            }
            let done: [String: Any] = [
                "id": id, "object": "chat.completion.chunk", "created": created, "model": "laile-coach",
                "choices": [["index": 0, "delta": [String: Any](), "finish_reason": "stop"]],
            ]
            sse += "data: \(json(done))\n\ndata: [DONE]\n\n"
            var headers = HTTPHeaders()
            headers.contentType = HTTPMediaType(type: "text", subType: "event-stream")
            headers.add(name: .cacheControl, value: "no-cache")
            return Response(status: .ok, headers: headers, body: .init(string: sse))
        }
        let full: [String: Any] = [
            "id": id, "object": "chat.completion", "created": created, "model": "laile-coach",
            "choices": [["index": 0, "message": ["role": "assistant", "content": text], "finish_reason": "stop"]],
        ]
        var headers = HTTPHeaders()
        headers.contentType = .json
        return Response(status: .ok, headers: headers, body: .init(string: json(full)))
    }

    private static func json(_ object: [String: Any]) -> String {
        (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])).map { String(decoding: $0, as: UTF8.self) } ?? "{}"
    }
}

extension Array {
    func chunked(into size: Int) -> [[Element]] {
        stride(from: 0, to: count, by: size).map { Array(self[$0..<Swift.min($0 + size, count)]) }
    }
}
