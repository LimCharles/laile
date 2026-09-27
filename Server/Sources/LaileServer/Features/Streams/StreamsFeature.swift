import Fluent
import LaileCore
import Vapor

final class StreamModel: Model, @unchecked Sendable {
    static let schema = "streams"

    @ID(key: .id) var id: UUID?
    @Field(key: "scheduled_start") var scheduledStart: Date
    @Field(key: "payload") var stream: StreamEvent

    init() {}

    init(stream: StreamEvent) {
        self.id = stream.id
        self.scheduledStart = stream.scheduledStart
        self.stream = stream
    }
}

struct CreateStreams: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(StreamModel.schema)
            .id()
            .field("scheduled_start", .datetime, .required)
            .field("payload", .json, .required)
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(StreamModel.schema).delete()
    }
}

/// Live presence and rep leaderboards for streams. Reps come from each phone's
/// camera-verified counter; the hub only aggregates and broadcasts.
actor StreamHub {
    struct Participant {
        let id: UUID
        let userID: UUID
        let displayName: String
        let socket: WebSocket
        var reps: Int
    }

    private var rooms: [UUID: [UUID: Participant]] = [:]

    func join(stream: UUID, participant: Participant) async {
        rooms[stream, default: [:]][participant.id] = participant
        await broadcast(stream)
    }

    func leave(stream: UUID, participantID: UUID) async {
        rooms[stream]?[participantID] = nil
        await broadcast(stream)
    }

    func updateReps(stream: UUID, participantID: UUID, total: Int) async {
        guard var participant = rooms[stream]?[participantID] else { return }
        // Totals only go up; ignore obviously bogus jumps.
        participant.reps = max(participant.reps, min(total, participant.reps + 60))
        rooms[stream]?[participantID] = participant
        await broadcast(stream)
    }

    func leaderboard(stream: UUID) -> [LeaderboardEntry] {
        (rooms[stream] ?? [:]).values
            .sorted { $0.reps > $1.reps }
            .map { LeaderboardEntry(id: $0.userID.uuidString, displayName: $0.displayName, verifiedReps: $0.reps) }
    }

    private func broadcast(_ stream: UUID) async {
        let participants = Array((rooms[stream] ?? [:]).values)
        let entries = leaderboard(stream: stream)
        for participant in participants {
            let personalised = entries.map { entry -> LeaderboardEntry in
                var e = entry
                e.isYou = entry.id == participant.userID.uuidString
                return e
            }
            let message = StreamSocketMessage.leaderboard(entries: Array(personalised.prefix(20)), participants: participants.count)
            guard let data = try? LaileJSON.encoder().encode(message) else { continue }
            try? await participant.socket.send(String(decoding: data, as: UTF8.self))
        }
    }
}

struct StreamsFeature: LaileFeature {
    let name = "streams"
    var migrations: [any Migration] { [CreateStreams()] }

    func boot(_ app: Application) async throws {
        let streams = app.protected.grouped("streams")
        streams.get { req async throws -> [StreamEvent] in
            try await Self.schedule(on: req.db, now: Date())
        }
        streams.get(":id") { req async throws -> StreamEvent in
            guard let id = req.parameters.get("id", as: UUID.self),
                  let stream = try await Self.schedule(on: req.db, now: Date()).first(where: { $0.id == id }) else {
                throw Abort(.notFound)
            }
            return stream
        }

        // WebSocket auth uses ?token= because browsers/phones can't always set headers on upgrade.
        app.webSocket("v1", "streams", ":id", "live") { req, ws async in
            guard let id = req.parameters.get("id", as: UUID.self),
                  let user = try? await Self.userFromQueryToken(req) else {
                try? await ws.close(code: .policyViolation)
                return
            }
            let participantID = UUID()
            let hub = req.laile.streamHub
            await hub.join(stream: id, participant: .init(id: participantID, userID: (try? user.requireID()) ?? UUID(),
                                                          displayName: user.displayName, socket: ws, reps: 0))
            ws.onText { _, text async in
                guard let message = try? LaileJSON.decoder().decode(StreamSocketMessage.self, from: Data(text.utf8)),
                      case .reps(let total) = message else { return }
                await hub.updateReps(stream: id, participantID: participantID, total: total)
            }
            ws.onClose.whenComplete { _ in
                Task { await hub.leave(stream: id, participantID: participantID) }
            }
        }
    }

    /// Scheduled streams from the database plus the always-on demo rotation.
    static func schedule(on db: Database, now: Date) async throws -> [StreamEvent] {
        let windowStart = now.addingTimeInterval(-2 * 3600)
        let stored = try await StreamModel.query(on: db).filter(\.$scheduledStart >= windowStart).all().map(\.stream)
        return (stored + DemoStreams.schedule(around: now))
            .filter { $0.endsAt > now.addingTimeInterval(-600) }
            .sorted { $0.scheduledStart < $1.scheduledStart }
    }

    static func userFromQueryToken(_ req: Request) async throws -> UserModel {
        guard let token = req.query[String.self, at: "token"],
              let model = try await UserTokenModel.query(on: req.db).filter(\.$value == token).with(\.$user).first(),
              model.isValid else {
            throw Abort(.unauthorized)
        }
        return model.user
    }
}
