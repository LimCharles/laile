import Fluent
import LaileCore
import Vapor

final class UserModel: Model, @unchecked Sendable {
    static let schema = "users"

    @ID(key: .id) var id: UUID?
    @Field(key: "email") var email: String
    @Field(key: "password_hash") var passwordHash: String
    @Field(key: "display_name") var displayName: String
    @Field(key: "role") var roleRaw: String
    @Field(key: "mode") var modeRaw: String
    @Field(key: "time_zone") var timeZone: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(id: UUID? = nil, email: String, passwordHash: String, displayName: String, role: API.UserRole, mode: AppMode, timeZone: String) {
        self.id = id
        self.email = email.lowercased()
        self.passwordHash = passwordHash
        self.displayName = displayName
        self.roleRaw = role.rawValue
        self.modeRaw = mode.rawValue
        self.timeZone = timeZone
    }

    var role: API.UserRole {
        get { API.UserRole(rawValue: roleRaw) ?? .mover }
        set { roleRaw = newValue.rawValue }
    }

    var mode: AppMode {
        get { AppMode(rawValue: modeRaw) ?? .move }
        set { modeRaw = newValue.rawValue }
    }

    func profile(clinicianName: String? = nil) throws -> API.UserProfile {
        API.UserProfile(id: try requireID(), email: email, displayName: displayName, role: role, mode: mode,
                        timeZone: timeZone, clinicianName: clinicianName, isDemo: DemoWorld.isDemo(email: email))
    }

    func generateToken() throws -> UserTokenModel {
        try UserTokenModel(value: [UInt8].random(count: 32).base64, userID: requireID(),
                           expiresAt: Date().addingTimeInterval(60 * 60 * 24 * 30))
    }
}

extension UserModel: ModelAuthenticatable {
    static var usernameKey: KeyPath<UserModel, FieldProperty<UserModel, String>> { \UserModel.$email }
    static var passwordHashKey: KeyPath<UserModel, FieldProperty<UserModel, String>> { \UserModel.$passwordHash }

    func verify(password: String) throws -> Bool {
        try Bcrypt.verify(password, created: passwordHash)
    }
}

extension UserModel: ModelSessionAuthenticatable {}
extension UserModel: ModelCredentialsAuthenticatable {}

final class UserTokenModel: Model, @unchecked Sendable {
    static let schema = "user_tokens"

    @ID(key: .id) var id: UUID?
    @Field(key: "value") var value: String
    @Parent(key: "user_id") var user: UserModel
    @Field(key: "expires_at") var expiresAt: Date
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}

    init(value: String, userID: UUID, expiresAt: Date) {
        self.value = value
        self.$user.id = userID
        self.expiresAt = expiresAt
    }
}

extension UserTokenModel: ModelTokenAuthenticatable {
    static var valueKey: KeyPath<UserTokenModel, Field<String>> { \UserTokenModel.$value }
    static var userKey: KeyPath<UserTokenModel, Parent<UserModel>> { \UserTokenModel.$user }
    var isValid: Bool { expiresAt > Date() }
}

struct CreateUsers: AsyncMigration {
    func prepare(on database: Database) async throws {
        try await database.schema(UserModel.schema)
            .id()
            .field("email", .string, .required)
            .field("password_hash", .string, .required)
            .field("display_name", .string, .required)
            .field("role", .string, .required)
            .field("mode", .string, .required)
            .field("time_zone", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "email")
            .create()
        try await database.schema(UserTokenModel.schema)
            .id()
            .field("value", .string, .required)
            .field("user_id", .uuid, .required, .references(UserModel.schema, "id", onDelete: .cascade))
            .field("expires_at", .datetime, .required)
            .field("created_at", .datetime)
            .unique(on: "value")
            .create()
    }

    func revert(on database: Database) async throws {
        try await database.schema(UserTokenModel.schema).delete()
        try await database.schema(UserModel.schema).delete()
    }
}

struct AuthFeature: LaileFeature {
    let name = "auth"
    var migrations: [any Migration] { [CreateUsers()] }

    func boot(_ app: Application) async throws {
        let v1 = app.grouped("v1")
        v1.post("auth", "register", use: register)
        v1.post("auth", "login", use: login)
        v1.get("time") { _ in API.ServerTime(now: Date()) }
        app.protected.get("me", use: me)
    }

    func register(req: Request) async throws -> API.AuthResponse {
        let body = try req.content.decode(API.RegisterRequest.self)
        guard body.password.count >= 8 else { throw Abort.badRequest("Password must be at least 8 characters.") }
        guard try await UserModel.query(on: req.db).filter(\.$email == body.email.lowercased()).first() == nil else {
            throw Abort(.conflict, reason: "An account with that email already exists.")
        }
        let user = UserModel(email: body.email, passwordHash: try Bcrypt.hash(body.password), displayName: body.displayName,
                             role: .mover, mode: .move, timeZone: body.timeZone)
        try await user.save(on: req.db)
        let token = try user.generateToken()
        try await token.save(on: req.db)
        return API.AuthResponse(token: token.value, user: try user.profile())
    }

    func login(req: Request) async throws -> API.AuthResponse {
        let body = try req.content.decode(API.LoginRequest.self)
        guard let user = try await UserModel.query(on: req.db).filter(\.$email == body.email.lowercased()).first(),
              try user.verify(password: body.password) else {
            throw Abort(.unauthorized, reason: "Email or password is incorrect.")
        }
        // Fixed demo accounts start from the same story on every sign-in.
        if req.laile.config.seedDemoData, DemoWorld.resetsOnLogin(user) {
            try await req.db.transaction { db in try await DemoWorld(app: req.application, db: db).reset(user) }
        }
        let token = try user.generateToken()
        try await token.save(on: req.db)
        return API.AuthResponse(token: token.value, user: try await user.profileWithClinician(on: req.db))
    }

    func me(req: Request) async throws -> API.UserProfile {
        try await req.auth.require(UserModel.self).profileWithClinician(on: req.db)
    }
}

extension Application {
    /// Bearer-token protected API routes under /v1.
    var protected: any RoutesBuilder {
        grouped("v1").grouped(UserTokenModel.authenticator(), UserModel.guardMiddleware())
    }
}

extension Request {
    var user: UserModel {
        get throws { try auth.require(UserModel.self) }
    }
}
