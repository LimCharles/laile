import Fluent
import FluentPostgresDriver
import FluentSQLiteDriver
import LaileCore
import Leaf
import LeafKit
import Vapor

/// The feature list. Adding a feature = a new folder under Features/ plus one line here.
func makeFeatures() -> [any LaileFeature] {
    [
        AuthFeature(),
        RewardsFeature(),
        PatientsFeature(),
        ProgramsFeature(),
        SessionsFeature(),
        CareNotesFeature(),
        EnrollmentsFeature(),
        LeleFeature(),
        RequestsFeature(),
        LiveFeature(),
        ProgressFeature(),
        StreamsFeature(),
        VoiceFeature(),
        SpeechFeature(),
        PortalFeature(),
        DemoFeature(),
    ]
}

public func configure(_ app: Application) async throws {
    // Outbound calls (ADP, Hunyuan, ElevenLabs) give up well before the app's 90 s, so a stalled
    // model never leaves a request hanging. Set before anything touches app.client.
    app.http.client.configuration.timeout = .init(connect: .seconds(10), read: .seconds(45))

    let config = LaileConfig.fromEnvironment(app.environment)
    let llm = makeLLMProvider(config: config, app: app)
    app.laile = AppServices(config: config, llm: llm, planner: makePlanner(config: config, llm: llm, app: app),
                            speech: SpeechFactory.make(config: config.speech, tencent: config.tencent, client: app.client))

    // JSON: ISO-8601 dates everywhere, matching the iOS client (LaileJSON).
    ContentConfiguration.global.use(encoder: LaileJSON.encoder(), for: .json)
    ContentConfiguration.global.use(decoder: LaileJSON.decoder(), for: .json)

    // Database: Postgres when DATABASE_URL is set (TencentDB for PostgreSQL), SQLite otherwise.
    if let url = config.databaseURL {
        try app.databases.use(.postgres(url: url), as: .psql)
    } else if app.environment == .testing {
        app.databases.use(.sqlite(.memory), as: .sqlite)
    } else {
        app.databases.use(.sqlite(.file(config.sqlitePath)), as: .sqlite)
    }

    app.views.use(.leaf)
    // Sandboxed to the Views directory. `.toVisibleFiles` is dropped because it rejects any
    // dot-directory anywhere in the absolute path (e.g. a checkout under ~/.something/).
    app.leaf.sources = .singleSource(NIOLeafFiles(
        fileio: app.fileio, limits: [.toSandbox, .requireExtensions],
        sandboxDirectory: app.directory.viewsDirectory, viewDirectory: app.directory.viewsDirectory
    ))
    app.middleware.use(FileMiddleware(publicDirectory: app.directory.publicDirectory))
    app.sessions.use(.fluent)
    app.migrations.add(SessionRecord.migration)
    app.middleware.use(app.sessions.middleware)

    let features = makeFeatures()
    for feature in features {
        feature.migrations.forEach { app.migrations.add($0) }
    }
    try await app.autoMigrate()
    for feature in features {
        try await feature.boot(app)
    }

    app.asyncCommands.use(GenerateCuesCommand(), as: "generate-cues")
    app.get("health") { _ in ["status": "ok", "llm": app.laile.llm.name, "planner": app.laile.planner.name] }
    app.get { req in req.redirect(to: "/portal") }
    app.logger.info("Laile features: \(features.map(\.name).joined(separator: ", "))")
    app.logger.info("LLM: \(app.laile.llm.name) · Planner: \(app.laile.planner.name) · Voice: \(app.laile.speech?.name ?? "none (on-device fallback)") · TRTC: \(config.trtc == nil ? "off" : "on")")
}

func makeLLMProvider(config: LaileConfig, app: Application) -> any LLMProvider {
    guard let llm = config.llm else { return MockLLMProvider() }
    return HunyuanProvider(config: llm, client: app.client, logger: app.logger)
}

/// Drafts go to the configured model when there is one, otherwise to Lele's ADP agent.
func makePlanner(config: LaileConfig, llm: any LLMProvider, app: Application) -> any LLMProvider {
    if llm.isLive { return llm }
    guard let appKey = config.adpAppKey else { return llm }
    return ADPPlannerProvider(appKey: appKey, client: app.client, logger: app.logger)
}
