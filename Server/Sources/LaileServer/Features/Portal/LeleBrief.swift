import Fluent
import LaileCore
import Vapor

/// Lele's written brief for the physio. It reads the person's own record (what Lele has learned
/// about them: programs, goals, measurements, care notes, what they reported) and the portal's
/// review list, and the ADP agent writes it with the knowledge base for context. The numbers and
/// flags come from code; the model only summarises them.
struct LeleBriefWriter {
    let req: Request

    func brief(for profile: PatientProfileModel) async throws -> String? {
        let planner = req.laile.planner
        guard planner.isLive, let userID = profile.$user.id, let user = try await UserModel.find(userID, on: req.db) else { return nil }
        let id = try profile.requireID()
        if let cached = await req.laile.briefs.get(id) { return cached }

        let snapshot = try await PatientSnapshot.load(profile, on: req.db)
        var lines = ["CLINICIAN BRIEF",
                     "For: \(CallName.plain(try req.user.displayName)), physiotherapist.",
                     "Patient: \(profile.displayName), \(profile.procedure.label)\(profile.context.daysSinceProcedure(now: Date()).map { ", day \($0) after the procedure" } ?? "").",
                     "Adherence: \(snapshot.adherenceLabel)."]
        lines.append(try await LeleContext.build(for: user, db: req.db))
        let reports = snapshot.symptoms.prefix(5).map { s in
            "\(Formatters.relative(s.reportedAt)): \"\(s.report.utterance)\"\(s.report.severity.map { ", \($0)/10" } ?? "")"
        }
        if !reports.isEmpty { lines.append("RECENT REPORTS: " + reports.joined(separator: " | ")) }
        if !snapshot.flags.isEmpty { lines.append("TO REVIEW: " + snapshot.flags.joined(separator: " | ")) }
        let pending = try await RequestStore(db: req.db).all(for: userID).filter { $0.status == .pending }
        if !pending.isEmpty { lines.append("WAITING FOR APPROVAL: " + pending.map(\.title).joined(separator: ", ")) }

        do {
            let reply = try await planner.complete(messages: [.user(lines.joined(separator: "\n"))], tools: [], temperature: 0.2)
            let text = LeleAgent.tidy(reply.content ?? "")
            guard !text.isEmpty else { return nil }
            await req.laile.briefs.set(id, text)
            return text
        } catch {
            req.logger.warning("Lele brief failed (\(error))")
            return nil
        }
    }
}

/// Briefs are rewritten at most every 30 minutes per patient.
actor LeleBriefCache {
    private var entries: [UUID: (at: Date, text: String)] = [:]

    func get(_ id: UUID, now: Date = Date()) -> String? {
        guard let entry = entries[id], now.timeIntervalSince(entry.at) < 30 * 60 else { return nil }
        return entry.text
    }

    func set(_ id: UUID, _ text: String, now: Date = Date()) { entries[id] = (now, text) }
}
