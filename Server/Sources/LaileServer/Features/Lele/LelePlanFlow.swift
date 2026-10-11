import Fluent
import LaileCore
import Vapor

/// Builds a new plan from someone's goals, for the goals screen and for planning in Lele's chat.
/// On their own, the new plan replaces their previous Lele plan. While a physio supervises them,
/// Lele drafts it inside the physio's limits and sends it to the physio to approve.
struct LelePlanService {
    let app: Application
    let db: Database
    let logger: Logger

    enum Outcome {
        case enrolled(Enrollment, [LeleMessage])
        case sentToPhysio(ProgramRequest, [LeleMessage])

        var messages: [LeleMessage] {
            switch self {
            case .enrolled(_, let messages), .sentToPhysio(_, let messages): return messages
            }
        }
    }

    func build(_ input: HealthProfile, user: UserModel) async throws -> Outcome {
        let userID = try user.requireID()
        let lele = LeleService(app: app, db: db, logger: logger)
        let supervisor = try await lele.activePatientProfile(for: userID)
        var profile = input
        profile.clinicianPrecautions = try await HealthStore(db: db).get(userID)?.clinicianPrecautions
        // A supervised person's plan stays inside the limits their physio signed.
        if let supervisor, let signed = try await ProgramModel.activeSigned(for: supervisor.requireID(), on: db)?.program {
            profile.clinicianPrecautions = profile.clinicianPrecautions.map { $0.merged(with: signed.precautions) } ?? signed.precautions
        }
        profile.updatedAt = Date()
        try await HealthStore(db: db).save(profile, userID: userID)

        let draft = try await LelePlanner(llm: app.laile.planner, logger: logger).plan(for: profile, name: user.displayName)
        let now = Date()
        let first = CallName.from(user.displayName)
        let reasons = draft.reasons.prefix(4).map { "• \($0)" }.joined(separator: "\n")

        if let supervisor {
            let physio = CallName.plain(supervisor.clinician.displayName)
            let model = ProgramRequestModel(userID: userID, profileID: try supervisor.requireID(), draft: draft.program, at: now)
            try await model.create(on: db)
            let message = LeleMessage(createdAt: now, kind: .welcome,
                                      text: "Thanks, \(first). From your new goals I've drafted \u{201C}\(draft.program.title)\u{201D}:\n\(reasons)\nIt stays inside \(physio)'s limits, and I've sent it to them to approve. I'll tell you as soon as they answer. Until then, keep going with your program with them.")
            try await lele.save(message, userID: userID)
            return .sentToPhysio(model.request, [message])
        }

        let store = EnrollmentStore(db: db)
        let replacing = try await store.active(for: userID).contains { $0.kind == .personal }
        let enrollment = try await store.resolve(store.createPersonal(draft.program, userID: userID))
        var messages = [LeleMessage(createdAt: now, kind: .welcome,
                                    text: "Thanks, \(first)! I've put together \u{201C}\(enrollment.title)\u{201D} for you:\n\(reasons)\n\(replacing ? "It replaces your previous plan from me. " : "")Your first session is a quick check-in so I can set targets from what you can comfortably do.",
                                    actions: [LeleAction(id: "start", label: "Start check-in", kind: .startSession, value: enrollment.id.uuidString)])]
        if profile.shouldSeeClinician {
            // Name what they told us, so the suggestion fits ("your wrists", "an injury").
            let areas = profile.sensitiveAreas.map { $0.label.lowercased() }
            let what = profile.goals.contains(.recoverInjury) ? "an injury"
                : areas.count > 1 ? "your " + areas.dropLast().joined(separator: ", ") + " and " + areas.last! : "your " + (areas.first ?? "aches")
            messages.append(LeleMessage(createdAt: now.addingTimeInterval(1), kind: .welcome,
                                        text: "Because you mentioned \(what), I've kept things gentle. If it bothers you, a physiotherapist can check it properly and give you a program I'll coach you through. If you already have a code from one, add it in Programs."))
        }
        for message in messages { try await lele.save(message, userID: userID) }
        return .enrolled(enrollment, messages)
    }
}
