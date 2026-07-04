import Fluent
import FluentPostgresDriver
import Vapor

public func configure(_ app: Application) async throws {
    // Railway sets PORT dynamically; bind 0.0.0.0 so the container's port mapping reaches us.
    app.http.server.configuration.hostname = "0.0.0.0"
    if let port = Environment.get("PORT").flatMap(Int.init) {
        app.http.server.configuration.port = port
    }

    try configureDatabase(app)
    try configureStorage(app)
    try configureInviteAndAdmin(app)
    configureGrading(app)

    app.migrations.add(CreateParticipant())
    app.migrations.add(CreateEnrollSession())
    app.migrations.add(CreateTake())

    // Migrations on boot: a single-instance service, so this is safe (no concurrent-migration race).
    try await app.autoMigrate()

    try routes(app)
}

private func configureDatabase(_ app: Application) throws {
    if let databaseURL = Environment.get("DATABASE_URL") {
        try app.databases.use(.postgres(url: databaseURL), as: .psql)
    } else {
        // Local dev fallback — matches a `docker run postgres` or Postgres.app default.
        app.databases.use(
            .postgres(
                configuration: .init(
                    hostname: Environment.get("DB_HOST") ?? "localhost",
                    port: Environment.get("DB_PORT").flatMap(Int.init) ?? 5432,
                    username: Environment.get("DB_USER") ?? "postgres",
                    password: Environment.get("DB_PASSWORD") ?? "postgres",
                    database: Environment.get("DB_NAME") ?? "breath_enroll",
                    tls: .disable
                )
            ),
            as: .psql
        )
    }
}

private func configureStorage(_ app: Application) throws {
    let root = Environment.get("STORAGE_DIR") ?? app.directory.workingDirectory + "data"
    app.storageDriver = LocalDiskStorage(root: URL(fileURLWithPath: root, isDirectory: true))
    app.logger.info("Storage root: \(root)")
}

private func configureGrading(_ app: Application) {
    let assetsDir = URL(fileURLWithPath: app.directory.workingDirectory)
        .appendingPathComponent("Resources/gold-refs", isDirectory: true)
    app.gradingSessions = GradingSessionStore(assetsDir: assetsDir)
}

private func configureInviteAndAdmin(_ app: Application) throws {
    app.inviteCode = Environment.get("INVITE_CODE")
    app.adminToken = Environment.get("ADMIN_TOKEN")
    if app.inviteCode == nil {
        app.logger.warning("INVITE_CODE not set — participant enrollment is unauthenticated")
    }
    if app.adminToken == nil {
        app.logger.warning("ADMIN_TOKEN not set — admin routes are unauthenticated")
    }
}
