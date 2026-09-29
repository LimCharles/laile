import Foundation
import LaileCore
@testable import LaileServer
import Fluent
import XCTVapor

final class ProgramsFlowTests: XCTestCase {
    var app: Application!

    override func setUp() async throws {
        app = try await Application.make(.testing)
        try await configure(app)
        var config = app.laile.config
        config.seedDemoData = true
        app.laile = AppServices(config: config, llm: MockLLMProvider())
    }

    override func tearDown() async throws {
        try await app.asyncShutdown()
        app = nil
    }

    func bearer(_ token: String) -> HTTPHeaders {
        var h = HTTPHeaders()
        h.bearerAuthorization = BearerAuthorization(token: token)
        return h
    }

    func demo(_ persona: API.DemoPersona) async throws -> API.AuthResponse {
        var auth: API.AuthResponse?
        try await app.test(.POST, "v1/demo/sessions", beforeRequest: { req in
            try req.content.encode(API.DemoStartRequest(persona: persona, timeZone: "Asia/Singapore"))
        }, afterResponse: { res in auth = try res.content.decode(API.AuthResponse.self) })
        return try XCTUnwrap(auth)
    }

    func register() async throws -> API.AuthResponse {
        var auth: API.AuthResponse?
        try await app.test(.POST, "v1/auth/register", beforeRequest: { req in
            try req.content.encode(API.RegisterRequest(email: "sam@example.com", password: "correct horse", displayName: "Sam Lee", timeZone: "Asia/Singapore"))
        }, afterResponse: { res in auth = try res.content.decode(API.AuthResponse.self) })
        return try XCTUnwrap(auth)
    }

    func enrollments(_ token: String) async throws -> [Enrollment] {
        var list: [Enrollment] = []
        try await app.test(.GET, "v1/enrollments", headers: bearer(token)) { res in list = try res.content.decode([Enrollment].self) }
        return list
    }

    /// Noon today in Singapore, so Lele's quiet hours never interfere with a test.
    var noon: Date {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        return c.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testJoiningACatalogProgramStartsWithACheckInThatSetsTargets() async throws {
        let auth = try await register()
        var joined: Enrollment?
        try await app.test(.POST, "v1/enrollments", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(API.JoinProgramRequest(catalogId: "first-push-up"))
        }, afterResponse: { res in joined = try res.content.decode(Enrollment.self) })
        let enrollment = try XCTUnwrap(joined)
        XCTAssertTrue(enrollment.needsCalibration)

        var push = ExerciseResult(exerciseId: "incline-push-up", side: .left, plannedSets: 1)
        push.repsPerSet = [14]
        let summary = SessionSummary(kind: .baseline, title: "Check-in", mode: .move, startedAt: Date().addingTimeInterval(-300), endedAt: Date(),
                                     enrollmentId: enrollment.id, exercises: [push])
        try await app.test(.POST, "v1/sessions", headers: bearer(auth.token), beforeRequest: { req in try req.content.encode(summary) },
                           afterResponse: { res in XCTAssertEqual(res.status, .ok) })
        let after = try await enrollments(auth.token).first { $0.id == enrollment.id }
        XCTAssertEqual(after?.calibration?.exercise("incline-push-up")?.maxReps, 14)
        XCTAssertEqual(after?.sessionPlan().plan.first { $0.spec.id == "incline-push-up" }?.dose.reps, 10)
    }

    func testLeleBuildsAPlanFromGoalsAndSuggestsAPhysioForInjuries() async throws {
        let auth = try await register()
        let profile = HealthProfile(goals: [.recoverInjury, .getStronger], minutesPerDay: 10, experience: .new, sensitiveAreas: [.knees, .wrists])
        var response: API.PlanResponse?
        try await app.test(.POST, "v1/plan", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(API.PlanRequest(profile: profile))
        }, afterResponse: { res in response = try res.content.decode(API.PlanResponse.self) })
        let plan = try XCTUnwrap(response)
        XCTAssertEqual(plan.enrollment.kind, .personal)
        XCTAssertFalse(plan.enrollment.program.items.isEmpty)
        XCTAssertFalse(plan.enrollment.program.items.contains { $0.exerciseId == "squat" || $0.exerciseId.contains("push-up") })
        XCTAssertTrue(plan.messages.contains { $0.text.contains("physiotherapist") })
        try await app.test(.GET, "v1/today", headers: bearer(auth.token)) { res in
            let today = try res.content.decode(API.TodayPlan.self)
            XCTAssertEqual(today.health?.sensitiveAreas, [.knees, .wrists])
            XCTAssertTrue(today.precautions.noWristLoading)
        }
    }

    func testOnlyTheClinicianCanEndPhysio() async throws {
        let auth = try await demo(.patient)
        let clinicalFound = try await enrollments(auth.token).first(where: \.isSupervised)
        let clinical = try XCTUnwrap(clinicalFound)
        XCTAssertNotNil(clinical.calibration, "the seeded first session calibrates the program")
        try await app.test(.POST, "v1/enrollments/\(clinical.id)/leave", headers: bearer(auth.token)) { res in
            XCTAssertEqual(res.status, .forbidden)
        }
    }

    func testMorningCheckInWorseMakesTodayGentlerAndIsNoted() async throws {
        let auth = try await demo(.patient)
        let userFound = try await UserModel.find(auth.user.id, on: app.db)
        let user = try XCTUnwrap(userFound)
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "Asia/Singapore")!
        let morning = c.date(bySettingHour: 8, minute: 30, second: 0, of: Date())!
        let service = LeleService(app: app, db: app.db, logger: app.logger)
        // The seeded story has a session "today"-ish only in the past, so the morning check-in fires.
        try await SessionModel.query(on: app.db).filter(\.$user.$id == auth.user.id).filter(\.$startedAt >= c.startOfDay(for: Date())).delete()
        let messages = try await service.round(for: user, now: morning)
        let checkIn = try XCTUnwrap(messages.first { $0.kind == .morningCheckIn })
        XCTAssertTrue(checkIn.text.contains("knee"))

        var turn: API.LeleTurnResponse?
        try await app.test(.POST, "v1/lele/messages/\(checkIn.id)/reply", headers: bearer(auth.token), beforeRequest: { req in
            try req.content.encode(API.LeleReplyRequest(actionId: "worse"))
        }, afterResponse: { res in turn = try res.content.decode(API.LeleTurnResponse.self) })
        XCTAssertEqual(turn?.careNotes.first?.kind, .flare)
        XCTAssertTrue(turn?.messages.last?.text.contains("gentler") ?? false)
        try await app.test(.GET, "v1/today", headers: bearer(auth.token)) { res in
            let today = try res.content.decode(API.TodayPlan.self)
            XCTAssertTrue(today.careNotes.contains { $0.kind == .flare })
        }
    }

    func testChatSafetyAndOfflineAnswers() async throws {
        let auth = try await demo(.patient)
        func chat(_ text: String) async throws -> String {
            var reply = ""
            try await app.test(.POST, "v1/lele/chat", headers: bearer(auth.token), beforeRequest: { req in
                try req.content.encode(API.LeleChatRequest(text: text))
            }, afterResponse: { res in reply = try res.content.decode(API.LeleTurnResponse.self).messages.last?.text ?? "" })
            return reply
        }
        let redFlag = try await chat("my calf is swollen and hot since last night")
        XCTAssertTrue(redFlag.contains("care team"))
        let dose = try await chat("should I take 2 panadol before my session?")
        XCTAssertTrue(dose.lowercased().contains("pharmacist") || dose.lowercased().contains("doctor"))
        let exercise = try await chat("why am I doing heel slides?")
        XCTAssertTrue(exercise.contains("Heel slides"))
    }

    func testRememberLineBecomesACareNote() throws {
        let (text, remember) = LeleAgent.extractRemember("""
        Thanks for telling me. I've noted that, so next time I'll make it easier.
        {"remember":{"kind":"sore_spot","exercise_id":"knee-push-up","body_location":"wrist","severity":4,"note":"Knee push-ups hurt the right wrist"}}
        """)
        XCTAssertFalse(text.contains("remember"))
        let note = try XCTUnwrap(remember?.careNote(at: Date()))
        XCTAssertEqual(note.exerciseId, "knee-push-up")
        XCTAssertEqual(note.source, .lele)
        XCTAssertNotNil(note.adjustment)
    }

    func testADPStreamParsing() throws {
        let stream = """
        event: text.delta
        data: {"Type":"text.delta","MessageId":"rpl_1","Text":"Heel slides help "}

        event: text.delta
        data: {"Type":"text.delta","MessageId":"rpl_1","Text":"your knee bend."}

        event: response.completed
        data: {"Type":"response.completed","Response":{"Status":"success","ConversationId":"abc"}}
        """
        XCTAssertEqual(try ADPClient.parse(stream), "Heel slides help your knee bend.")
        XCTAssertThrowsError(try ADPClient.parse("event: error\ndata: {\"Type\":\"error\",\"Error\":{\"Message\":\"bad key\"}}"))
    }

    // MARK: Clinician portal

    func portalCookie() async throws -> HTTPHeaders {
        var cookie = HTTPHeaders()
        try await app.test(.POST, "portal/login", beforeRequest: { req in
            try req.content.encode(["email": DemoSeed.clinicianEmail, "password": DemoSeed.password], as: .urlEncodedForm)
        }, afterResponse: { res in
            let value = try XCTUnwrap(res.headers.setCookie?["vapor-session"]?.string)
            cookie.add(name: .cookie, value: "vapor-session=\(value)")
        })
        return cookie
    }

    func testDischargeHandsTheirHistoryOverToSelfGuided() async throws {
        let auth = try await demo(.patient)
        let cookie = try await portalCookie()
        let profileFound = try await PatientProfileModel.query(on: app.db).filter(\.$user.$id == auth.user.id).first()
        let profile = try XCTUnwrap(profileFound)
        try await app.test(.POST, "portal/patients/\(try profile.requireID())/discharge", headers: cookie, beforeRequest: { req in
            try req.content.encode(["note": "Great work!", "follow_on": "strong-knees", "carry_precautions": "on"], as: .urlEncodedForm)
        }, afterResponse: { res in XCTAssertEqual(res.status, .seeOther) })

        let all = try await enrollments(auth.token)
        let clinical = try XCTUnwrap(all.first(where: \.isSupervised))
        XCTAssertEqual(clinical.status, .completed)
        XCTAssertEqual(clinical.followOnCatalogId, "strong-knees")
        var messages: [LeleMessage] = []
        try await app.test(.GET, "v1/lele/messages", headers: bearer(auth.token)) { res in messages = try res.content.decode([LeleMessage].self) }
        let discharge = try XCTUnwrap(messages.first { $0.kind == .discharge })
        XCTAssertEqual(discharge.actions.first?.value, "strong-knees")
        let notNilValue = try await HealthStore(db: app.db).get(auth.user.id)?.clinicianPrecautions
        XCTAssertNotNil(notNilValue)
        try await app.test(.GET, "v1/me", headers: bearer(auth.token)) { res in
            XCTAssertEqual(try res.content.decode(API.UserProfile.self).mode, .move)
        }
    }

    func testClinicianSeesTheSessionLive() async throws {
        let auth = try await demo(.patient)
        let cookie = try await portalCookie()
        let profileFound = try await PatientProfileModel.query(on: app.db).filter(\.$user.$id == auth.user.id).first()
        let profile = try XCTUnwrap(profileFound)
        let update = API.LiveSessionUpdate(sessionTitle: "Knee program", exerciseName: "Heel slides", exerciseIndex: 2, exerciseCount: 5,
                                           setIndex: 0, totalSets: 2, phase: "active", reps: 6, targetReps: 10, holdSeconds: 0,
                                           targetHoldSeconds: nil, angleLabel: "Knee bent to 88°", lastHeard: nil, symptomsLogged: 0, ended: false)
        try await app.test(.POST, "v1/sessions/live", headers: bearer(auth.token), beforeRequest: { req in try req.content.encode(update) },
                           afterResponse: { res in XCTAssertEqual(res.status, .noContent) })
        try await app.test(.GET, "portal/patients/\(try profile.requireID())/live", headers: cookie) { res in
            let live = try res.content.decode(LiveFeature.LiveVM.self)
            XCTAssertTrue(live.live)
            XCTAssertEqual(live.update?.reps, 6)
        }
    }

    func testPhysicianAsksLeleToMakeItGentler() async throws {
        let auth = try await demo(.patient)
        let cookie = try await portalCookie()
        let profileFound = try await PatientProfileModel.query(on: app.db).filter(\.$user.$id == auth.user.id).first()
        let profile = try XCTUnwrap(profileFound)
        let signedModel = try await ProgramModel.activeSigned(for: profile.requireID(), on: app.db)
        let signed = try XCTUnwrap(signedModel).program
        try await app.test(.POST, "portal/programs/\(signed.id)/ask-lele", headers: cookie, beforeRequest: { req in
            try req.content.encode(["instruction": "Make it gentler, she had a flare"], as: .urlEncodedForm)
        }, afterResponse: { res in XCTAssertEqual(res.status, .seeOther) })
        let versions = try await ProgramModel.all(for: profile.requireID(), on: app.db)
        let draft = try XCTUnwrap(versions.first { $0.program.status == .draft }).program
        XCTAssertEqual(draft.version, signed.version + 1)
        XCTAssertTrue(draft.summary.hasPrefix("Lele"))
        let before = signed.items.first { $0.exerciseId == "heel-slide" }?.dose.reps ?? 0
        let after = draft.items.first { $0.exerciseId == "heel-slide" }?.dose.reps ?? 0
        XCTAssertLessThan(after, before)
        // The patient still runs the signed version until the physician signs the draft.
        let clinicalFound = try await enrollments(auth.token).first(where: \.isSupervised)
        let clinical = try XCTUnwrap(clinicalFound)
        XCTAssertEqual(clinical.program.id, signed.id)
    }

    func testShoulderDemoPatientHasAnArmLiftTrend() async throws {
        try await DemoWorld(app: app).ensureBase()
        let userFound = try await UserModel.query(on: app.db).filter(\.$email == DemoSeed.shoulderEmail).first()
        let user = try XCTUnwrap(userFound)
        let samples = try await MetricSampleModel.samples(for: user.requireID(), on: app.db).filter { $0.kind == .shoulderElevation }
        XCTAssertEqual(samples.first?.value, 95)
        XCTAssertEqual(samples.last?.value, 128)
        let notNilValue = try await EnrollmentStore(db: app.db).active(for: user.requireID()).first?.calibration
        XCTAssertNotNil(notNilValue)
    }
}
