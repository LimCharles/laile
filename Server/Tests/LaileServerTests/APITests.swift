import Foundation
import LaileCore
@testable import LaileServer
import XCTVapor

final class APITests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    func register(_ email: String = "tester@example.com") async throws -> API.AuthResponse {
        var auth: API.AuthResponse?
        try await app.test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(API.RegisterRequest(email: email, password: "correct horse", displayName: "Tester", timeZone: "Asia/Singapore"))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            auth = try res.content.decode(API.AuthResponse.self)
        })
        return try XCTUnwrap(auth)
    }

    func bearer(_ token: String) -> HTTPHeaders {
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: token)
        return headers
    }

    func testRegisterLoginAndMe() async throws {
        let auth = try await register()
        XCTAssertEqual(auth.user.mode, .move)
        try await app.test(.POST, "v1/auth/login", beforeRequest: { req in
            try req.content.encode(API.LoginRequest(email: "TESTER@example.com", password: "correct horse"))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
        })
        try await app.test(.POST, "v1/auth/login", beforeRequest: { req in
            try req.content.encode(API.LoginRequest(email: "tester@example.com", password: "wrong"))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .unauthorized)
        })
        try await app.test(.GET, "v1/me", headers: bearer(auth.token)) { res in
            XCTAssertEqual(try res.content.decode(API.UserProfile.self).displayName, "Tester")
        }
        try await app.test(.GET, "v1/me") { res in XCTAssertEqual(res.status, .unauthorized) }
    }

    func testCheckInIsOncePerDay() async throws {
        let auth = try await register()
        try await app.test(.POST, "v1/rewards/check-in", headers: bearer(auth.token)) { res in
            let body = try res.content.decode(API.CheckInResponse.self)
            XCTAssertEqual(body.outcome.xpAwarded, 10)
            XCTAssertTrue(body.summary.checkedInToday)
        }
        try await app.test(.POST, "v1/rewards/check-in", headers: bearer(auth.token)) { res in
            XCTAssertTrue(try res.content.decode(API.CheckInResponse.self).outcome.alreadyCheckedIn)
        }
    }

    func testSessionSubmitRecordsMetricsRewardsAndSymptoms() async throws {
        let auth = try await register()
        var heel = ExerciseResult(exerciseId: "squat", side: .left, plannedSets: 1)
        heel.repsPerSet = [15]
        let summary = SessionSummary(kind: .snack, title: "Lunch-break blast", mode: .move, startedAt: Date().addingTimeInterval(-400),
                                     endedAt: Date(), exercises: [heel],
                                     symptoms: [SymptomReport(category: .effort, utterance: "burning", source: .voiceOnDevice)])
        try await app.test(.POST, "v1/sessions", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(summary)
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            let body = try res.content.decode(API.SessionSubmitResponse.self)
            XCTAssertGreaterThan(body.movement.xpAwarded, 25)
            XCTAssertTrue(body.movement.newBadges.contains { $0.id == "first-move" })
            XCTAssertTrue(body.summary.movedToday)
        })
        // Resubmitting the same session is rejected (idempotency for flaky networks).
        try await app.test(.POST, "v1/sessions", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(summary)
        }, afterResponse: { res in XCTAssertEqual(res.status, .conflict) })

        try await app.test(.GET, "v1/progress", headers: bearer(auth.token)) { res in
            let overview = try res.content.decode(API.ProgressOverview.self)
            XCTAssertEqual(overview.trends.first { $0.kind == .squatReps }?.latest?.value, 15)
            XCTAssertEqual(overview.recentSessions.count, 1)
        }
    }

    func testInviteLinkSwitchesToRehabWithSignedProgram() async throws {
        // Clinician + patient record + signed program, directly through the models.
        let clinician = UserModel(email: "doc@example.com", passwordHash: try Bcrypt.hash("x-password"), displayName: "Dr Test",
                                  role: .clinician, mode: .move, timeZone: "Asia/Singapore")
        try await clinician.create(on: app.db)
        let profile = PatientProfileModel(clinicianID: try clinician.requireID(), displayName: "P", age: 70, procedure: .totalKneeReplacement,
                                          procedureDate: Date().addingTimeInterval(-5 * 86_400), precautions: Precautions(weightBearing: .partial, maxImpact: .low),
                                          painStopSetAbove: 3, comorbidities: [], goals: [], clinicalNotes: "", medications: [])
        try await profile.create(on: app.db)
        var program = TemplateDrafter.draft(context: profile.context, patientId: try profile.requireID())
        program.status = .signed
        program.painStopSetAbove = profile.painStopSetAbove
        try await ProgramModel(patientID: profile.requireID(), program: program).create(on: app.db)

        let auth = try await register("patient@example.com")
        try await app.test(.POST, "v1/patients/link", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(API.LinkClinicianRequest(inviteCode: profile.inviteCode.lowercased()))
        }, afterResponse: { res in
            let user = try res.content.decode(API.UserProfile.self)
            XCTAssertEqual(user.mode, .rehab)
            XCTAssertEqual(user.clinicianName, "Dr Test")
        })
        try await app.test(.GET, "v1/today", headers: bearer(auth.token)) { res in
            let plan = try res.content.decode(API.TodayPlan.self)
            XCTAssertEqual(plan.program?.id, program.id)
            XCTAssertFalse(plan.program?.items.contains { $0.exerciseId == "squat" } ?? true)
        }
        // The coach uses this patient's clinician-set threshold (3): pain 4 stops the set.
        try await app.test(.POST, "v1/voice/turn", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(API.CoachTurnRequest(utterance: "sharp pain in my knee, a four", context: .init(phase: "active")))
        }, afterResponse: { res in
            let turn = try res.content.decode(API.CoachTurnResponse.self)
            XCTAssertEqual(turn.report?.action, .stopSet)
        })
    }

    func testCoachRedFlagNeverReachesModel() async throws {
        let agent = CoachAgent(llm: ExplodingLLM(), logger: app.logger)
        let turn = await agent.respond(to: "I've got chest pain", history: [], context: nil, mode: .move, userName: "T", policy: .moveDefault)
        XCTAssertEqual(turn.action, .endSession(.emergency))
        XCTAssertTrue(turn.reply.contains("995"))

        let dose = await agent.respond(to: "should I take another tablet?", history: [], context: nil, mode: .rehab, userName: "T", policy: .rehabDefault)
        XCTAssertEqual(dose.reply, MedicationBoundary.referral)
    }

    func testTRTCLLMEndpointStreamsChatCompletionChunks() async throws {
        let auth = try await register()
        await app.laile.voiceSessions.create(.init(key: "session-key-1", userID: auth.user.id, userName: "Tester", mode: .move, policy: .moveDefault))
        var headers = bearer("session-key-1")
        headers.contentType = .json
        let body = #"{"model":"x","stream":true,"messages":[{"role":"user","content":"it's pulling a bit"}]}"#
        try await app.test(.POST, "v1/voice/llm/chat/completions", headers: headers, body: ByteBuffer(string: body)) { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.subType, "event-stream")
            let text = res.body.string
            XCTAssertTrue(text.contains("chat.completion.chunk"))
            XCTAssertTrue(text.hasSuffix("data: [DONE]\n\n"))
        }
        try await app.test(.POST, "v1/voice/llm/chat/completions", headers: bearer("wrong"), body: ByteBuffer(string: body)) { res in
            XCTAssertEqual(res.status, .unauthorized)
        }
    }

    func testStreamsIncludeDemoSchedule() async throws {
        let auth = try await register()
        try await app.test(.GET, "v1/streams", headers: bearer(auth.token)) { res in
            let streams = try res.content.decode([StreamEvent].self)
            XCTAssertFalse(streams.isEmpty)
        }
    }
}

struct ExplodingLLM: LLMProvider {
    var name: String { "exploding" }
    var isLive: Bool { true }
    func complete(messages: [ChatMessage], tools: [ToolDefinition], temperature: Double) async throws -> LLMReply {
        XCTFail("Model must not be called for deterministic safety paths")
        throw Abort(.internalServerError)
    }
}

final class TencentSigningTests: XCTestCase {
    func testUserSigIsValidZlib() throws {
        let sig = TRTCUserSig.generate(userId: "user-1", sdkAppId: 1_400_000_000, secretKey: "secret", now: 1_700_000_000)
        let base64 = sig.replacingOccurrences(of: "*", with: "+").replacingOccurrences(of: "-", with: "/").replacingOccurrences(of: "_", with: "=")
        let data = try XCTUnwrap(Data(base64Encoded: base64))
        XCTAssertEqual(Array(data.prefix(2)), [0x78, 0x01])
        // Strip zlib header/trailer and inflate the raw deflate stream.
        let raw = data.dropFirst(2).dropLast(4)
        let inflated = try (Data(raw) as NSData).decompressed(using: .zlib) as Data
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: inflated) as? [String: Any])
        XCTAssertEqual(json["TLS.identifier"] as? String, "user-1")
        XCTAssertEqual(json["TLS.sdkappid"] as? Int, 1_400_000_000)
        XCTAssertNotNil(json["TLS.sig"] as? String)
    }

    func testTC3SignatureShape() {
        let signer = TC3Signer(secretId: "AKIDEXAMPLE", secretKey: "secret")
        let a = signer.sign(service: "trtc", host: "trtc.tencentcloudapi.com", payload: Data("{}".utf8), timestamp: 1_700_000_000)
        let b = signer.sign(service: "trtc", host: "trtc.tencentcloudapi.com", payload: Data("{}".utf8), timestamp: 1_700_000_000)
        XCTAssertEqual(a.authorization, b.authorization)
        XCTAssertTrue(a.authorization.hasPrefix("TC3-HMAC-SHA256 Credential=AKIDEXAMPLE/2023-11-14/trtc/tc3_request, SignedHeaders=content-type;host, Signature="))
        let c = signer.sign(service: "trtc", host: "trtc.tencentcloudapi.com", payload: Data("{\"a\":1}".utf8), timestamp: 1_700_000_000)
        XCTAssertNotEqual(a.authorization, c.authorization)
    }
}

struct FakeSynth: SpeechSynthesizer {
    var name: String { "fake" }
    func synthesize(_ text: String, live: Bool) async throws -> Data { Data("MP3:\(text)".utf8) }
}

final class SpeechTests: XCTestCase {
    func testTRTCUsesElevenLabsNatively() throws {
        let config = SpeechConfig(provider: .elevenlabs, elevenLabsKey: "xi-key", elevenLabsVoiceId: "voice-1",
                                  elevenLabsModel: "eleven_multilingual_v2", elevenLabsLiveModel: "eleven_flash_v2_5",
                                  tencentVoiceType: 0, trtcFlowVoiceId: "v")
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(config.trtcTTSConfigJSON.utf8)) as? [String: String])
        XCTAssertEqual(json["TTSType"], "elevenlabs")
        XCTAssertEqual(json["Model"], "eleven_flash_v2_5")
        XCTAssertEqual(json["VoiceId"], "voice-1")
    }

    func testSpeakEndpointReturnsCachedAudio() async throws {
        let app = try await Application.make(.testing)
        try await configure(app)
        app.laile = AppServices(config: app.laile.config, llm: MockLLMProvider(), speech: FakeSynth())
        var auth: API.AuthResponse?
        try await app.test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(API.RegisterRequest(email: "s@example.com", password: "correct horse", displayName: "S", timeZone: "UTC"))
        }, afterResponse: { res in auth = try res.content.decode(API.AuthResponse.self) })
        var headers = HTTPHeaders()
        headers.bearerAuthorization = BearerAuthorization(token: try XCTUnwrap(auth).token)
        try await app.test(.POST, "v1/voice/speak", headers: headers, beforeRequest: { req in
            try req.content.encode(SpeakRequest(text: "Okay, noted. Keep going."))
        }, afterResponse: { res in
            XCTAssertEqual(res.status, .ok)
            XCTAssertEqual(res.headers.contentType?.subType, "mpeg")
            XCTAssertEqual(res.body.string, "MP3:Okay, noted. Keep going.")
        })
        try await app.asyncShutdown()
    }
}
