import Fluent
import LaileCore
import Vapor

/// The patient web app at /app: the same account, programs and Lele as the iPhone app, in a browser.
/// Its files live in Public/app; this feature serves the page, the landing page at /, and the two
/// things only a browser needs from the server: a ready-to-run session plan and the catalog.
struct WebFeature: LaileFeature {
    let name = "web"

    func boot(_ app: Application) async throws {
        // Ahead of the file middleware, so a redeploy reaches browsers straight away.
        app.middleware.use(RevalidateWebAppMiddleware(), at: .beginning)
        let page = app.directory.publicDirectory + "app/index.html"
        app.get("app") { req async throws -> Response in try await req.fileio.asyncStreamFile(at: page) }
        app.get { req async throws -> Response in try await req.fileio.asyncStreamFile(at: app.directory.publicDirectory + "index.html") }

        app.protected.get("sessions", "plan", use: plan)
        // The phone app ships the catalog in LaileCore; the browser reads it from here.
        app.get("v1", "catalog") { _ in SessionTemplate.catalogPrograms }
    }

    /// The session the phone would run: the check-in first, then targets tuned from it, inside the
    /// person's limits, with exercises Lele eased after a sore spot. Built by the same LaileCore
    /// code as the app, so a web session counts and reports exactly like a phone session.
    func plan(req: Request) async throws -> WebSessionPlan {
        let user = try req.user
        let userID = try user.requireID()
        let precautions = try await HealthStore(db: req.db).get(userID)?.precautions ?? .none
        let notes = try await CareNoteStore(db: req.db).all(for: userID).filter(\.isActive)

        if let id = req.query[UUID.self, at: "enrollment"] {
            guard let enrollment = try await EnrollmentStore(db: req.db).all(for: userID).first(where: { $0.id == id && $0.isActive }) else {
                throw Abort(.notFound)
            }
            let supervised = enrollment.isSupervised
            let policy = supervised ? enrollment.program.symptomPolicy : .moveDefault
            let checkIn = enrollment.needsCalibration
            let plan = checkIn ? enrollment.calibrationPlan(precautions: precautions) : enrollment.sessionPlan(precautions: precautions).plan
            return WebSessionPlan(title: checkIn ? "Check-in: \(enrollment.title)" : enrollment.title,
                                  kind: checkIn ? .baseline : (supervised ? .program : .workout), mode: supervised ? .rehab : .move,
                                  programId: supervised ? enrollment.program.id : nil, templateId: enrollment.catalogId, enrollmentId: enrollment.id,
                                  isCheckIn: checkIn, isSupervised: supervised, policy: policy, plan: CareMemory.adjust(plan, notes: notes))
        }
        if let id = req.query[String.self, at: "template"], let template = SessionTemplate.builtIn(id) {
            let plan = ContraindicationChecker.filter(template.plan(), precautions: precautions).kept
            let policy: SymptomPolicy = template.mode == .rehab ? .rehabDefault : .moveDefault
            return WebSessionPlan(title: template.title, kind: template.isSnack ? .snack : .workout, mode: template.mode,
                                  programId: nil, templateId: template.id, enrollmentId: nil, isCheckIn: false, isSupervised: false,
                                  policy: policy, plan: CareMemory.adjust(plan, notes: notes))
        }
        throw Abort(.badRequest, reason: "Pass enrollment=<id> or template=<id>.")
    }
}

/// The web app's pages and scripts are revalidated on every load (a cheap ETag check), so a
/// browser never runs yesterday's app.js against today's server.
struct RevalidateWebAppMiddleware: AsyncMiddleware {
    func respond(to request: Request, chainingTo next: any AsyncResponder) async throws -> Response {
        let response = try await next.respond(to: request)
        let path = request.url.path
        if path == "/" || path == "/app" || path.hasPrefix("/app/") || path == "/index.html" {
            response.headers.replaceOrAdd(name: .cacheControl, value: "no-cache")
        }
        return response
    }
}

struct WebSessionPlan: Content {
    var title: String
    var kind: SessionSummary.Kind
    var mode: AppMode
    var programId: UUID?
    var templateId: String?
    var enrollmentId: UUID?
    var isCheckIn: Bool
    var isSupervised: Bool
    var policy: SymptomPolicy
    var plan: [PlannedExercise]
}
