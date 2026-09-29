import Fluent
import LaileCore
import Vapor

/// What each person is doing in a session right now. In memory: it only matters while it's live.
actor LiveSessionStore {
    struct Entry: Sendable {
        var update: API.LiveSessionUpdate
        var receivedAt: Date
    }

    private var entries: [UUID: Entry] = [:]

    func set(_ update: API.LiveSessionUpdate, for userID: UUID, at date: Date = Date()) {
        entries[userID] = Entry(update: update, receivedAt: date)
    }

    /// Live if an update arrived in the last 15 seconds and the session hasn't ended.
    func current(for userID: UUID, now: Date = Date()) -> Entry? {
        guard let entry = entries[userID], now.timeIntervalSince(entry.receivedAt) < 15, !entry.update.ended else { return nil }
        return entry
    }

    func liveUserIDs(now: Date = Date()) -> Set<UUID> {
        Set(entries.filter { now.timeIntervalSince($0.value.receivedAt) < 15 && !$0.value.update.ended }.keys)
    }
}

struct LiveFeature: LaileFeature {
    let name = "live"

    struct LiveVM: Content {
        var live: Bool
        var update: API.LiveSessionUpdate?
        var secondsAgo: Int?
    }

    func boot(_ app: Application) async throws {
        // The app posts a snapshot every couple of seconds while a session runs.
        app.protected.post("sessions", "live") { req async throws -> HTTPStatus in
            let update = try req.content.decode(API.LiveSessionUpdate.self)
            await req.laile.live.set(update, for: try req.user.requireID())
            return .noContent
        }
        // The clinician's patient page polls this.
        let portal = app.grouped("portal").grouped(UserModel.sessionAuthenticator()).grouped(ClinicianOnlyMiddleware())
        portal.get("patients", ":patientID", "live") { req async throws -> LiveVM in
            guard let id = req.parameters.get("patientID", as: UUID.self), let profile = try await PatientProfileModel.find(id, on: req.db),
                  profile.$clinician.id == (try req.user.id) else { throw Abort(.notFound) }
            guard let userID = profile.$user.id, let entry = await req.laile.live.current(for: userID) else {
                return LiveVM(live: false, update: nil, secondsAgo: nil)
            }
            return LiveVM(live: true, update: entry.update, secondsAgo: Int(Date().timeIntervalSince(entry.receivedAt)))
        }
    }
}
