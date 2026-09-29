import Foundation
import LaileCore
import Security

/// The hosted Laile API. The address is fixed at build time (`LaileAPIBaseURL` in Info.plist,
/// from the `LAILE_API_BASE_URL` build setting); the bearer token is kept in the Keychain.
@MainActor
public final class RemoteBackend: LaileBackend {
    public let baseURL: URL
    private var token: String?

    /// The API this build talks to.
    public nonisolated static var configuredBaseURL: URL {
        let raw = Bundle.main.object(forInfoDictionaryKey: "LaileAPIBaseURL") as? String ?? ""
        return URL(string: raw.trimmingCharacters(in: .whitespaces)).flatMap { $0.scheme == nil ? nil : $0 }
            ?? URL(string: "http://127.0.0.1:8080")!
    }
    private let session: URLSession

    public init(baseURL: URL = RemoteBackend.configuredBaseURL, session: URLSession = .shared) {
        self.baseURL = baseURL
        self.session = session
        self.token = Keychain.read(account: baseURL.absoluteString)
    }

    public var isSignedIn: Bool { token != nil }

    public func signIn(email: String, password: String) async throws -> API.UserProfile {
        let auth: API.AuthResponse = try await send("POST", "v1/auth/login", body: API.LoginRequest(email: email, password: password), authorized: false)
        setToken(auth.token)
        return auth.user
    }

    public func register(email: String, password: String, name: String) async throws -> API.UserProfile {
        let auth: API.AuthResponse = try await send("POST", "v1/auth/register",
                                                    body: API.RegisterRequest(email: email, password: password, displayName: name, timeZone: TimeZone.current.identifier),
                                                    authorized: false)
        setToken(auth.token)
        return auth.user
    }

    public func startDemo(_ persona: API.DemoPersona) async throws -> API.UserProfile {
        let auth: API.AuthResponse = try await send("POST", "v1/demo/sessions",
                                                    body: API.DemoStartRequest(persona: persona, timeZone: TimeZone.current.identifier),
                                                    authorized: token != nil)
        setToken(auth.token)
        return auth.user
    }

    public func signOut() { setToken(nil) }

    private func setToken(_ value: String?) {
        token = value
        if let value { Keychain.write(value, account: baseURL.absoluteString) } else { Keychain.delete(account: baseURL.absoluteString) }
    }

    // MARK: LaileBackend

    public func currentUser() async throws -> API.UserProfile { try await send("GET", "v1/me") }
    public func rewards() async throws -> RewardsSummary { try await send("GET", "v1/rewards/summary") }
    public func checkIn() async throws -> API.CheckInResponse { try await send("POST", "v1/rewards/check-in") }
    public func today() async throws -> API.TodayPlan { try await send("GET", "v1/today") }
    public func submit(_ summary: SessionSummary) async throws -> API.SessionSubmitResponse { try await send("POST", "v1/sessions", body: summary) }
    public func progress() async throws -> API.ProgressOverview { try await send("GET", "v1/progress") }
    public func streams() async throws -> [StreamEvent] { try await send("GET", "v1/streams") }

    public func serverTimeOffset() async -> TimeInterval {
        let sent = Date()
        guard let time: API.ServerTime = try? await send("GET", "v1/time", authorized: false) else { return 0 }
        let rtt = Date().timeIntervalSince(sent)
        return time.now.timeIntervalSince(sent) - rtt / 2
    }

    public func link(inviteCode: String) async throws -> API.UserProfile {
        try await send("POST", "v1/patients/link", body: API.LinkClinicianRequest(inviteCode: inviteCode))
    }

    public func markMedicationTaken(_ medicationId: UUID, scheduled: TimeOfDay) async throws {
        let _: EmptyResponse = try await send("POST", "v1/medications/taken", body: API.MedicationTakenRequest(medicationId: medicationId, scheduled: scheduled))
    }

    public func careNotes() async throws -> [CareNote] { try await send("GET", "v1/care-notes") }

    public func markCareNoteBetter(_ id: UUID) async throws -> CareNote {
        try await send("POST", "v1/care-notes/\(id.uuidString)/better")
    }

    public func coachTurn(_ utterance: String, context: API.VoiceContext) async throws -> API.CoachTurnResponse {
        try await send("POST", "v1/voice/turn", body: API.CoachTurnRequest(utterance: utterance, context: context))
    }

    public func streamSocketURL(_ streamId: UUID) -> URL? {
        guard let token, var components = URLComponents(url: baseURL.appendingPathComponent("v1/streams/\(streamId.uuidString)/live"), resolvingAgainstBaseURL: false) else { return nil }
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        components.queryItems = [URLQueryItem(name: "token", value: token)]
        return components.url
    }

    public nonisolated func speech(_ text: String, voice: CoachVoice) async -> Data? {
        guard let token = await currentToken() else { return nil }
        var request = URLRequest(url: baseURL.appendingPathComponent("v1/voice/speak"))
        request.httpMethod = "POST"
        request.timeoutInterval = 15
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        request.httpBody = try? JSONEncoder().encode(API.SpeakRequest(text: text, voice: voice))
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200, !data.isEmpty else { return nil }
        return data
    }

    private func currentToken() -> String? { token }

    // MARK: HTTP

    struct EmptyBody: Encodable {}
    struct EmptyResponse: Decodable {}

    private func send<Response: Decodable>(_ method: String, _ path: String, authorized: Bool = true) async throws -> Response {
        try await send(method, path, body: Optional<EmptyBody>.none, authorized: authorized)
    }

    private func send<Body: Encodable, Response: Decodable>(_ method: String, _ path: String, body: Body?, authorized: Bool = true) async throws -> Response {
        var request = URLRequest(url: baseURL.appendingPathComponent(path))
        request.httpMethod = method
        request.timeoutInterval = 20
        if let body {
            request.httpBody = try LaileJSON.encoder().encode(body)
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        }
        if authorized {
            guard let token else { throw BackendError.notSignedIn }
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        }
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else {
            let reason = (try? LaileJSON.decoder().decode(API.ErrorResponse.self, from: data))?.reason ?? ""
            if status == 401 { setToken(nil) }
            throw BackendError.http(status, reason)
        }
        if Response.self == EmptyResponse.self { return EmptyResponse() as! Response }
        return try LaileJSON.decoder().decode(Response.self, from: data)
    }
}

enum Keychain {
    static let service = "app.laile.token"

    static func read(account: String) -> String? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecReturnData as String: true]
        var item: CFTypeRef?
        guard SecItemCopyMatching(query as CFDictionary, &item) == errSecSuccess, let data = item as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func write(_ value: String, account: String) {
        delete(account: account)
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account, kSecValueData as String: Data(value.utf8),
                                    kSecAttrAccessible as String: kSecAttrAccessibleAfterFirstUnlock]
        SecItemAdd(query as CFDictionary, nil)
    }

    static func delete(account: String) {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: service,
                                    kSecAttrAccount as String: account]
        SecItemDelete(query as CFDictionary)
    }
}
