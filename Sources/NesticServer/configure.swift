import NIOSSL
import Fluent
import FluentPostgresDriver
import JWT
import Vapor

public func configure(_ app: Application) async throws {
    let configuredSecret = Environment.get("JWT_SECRET")
    if app.environment == .production && (configuredSecret?.utf8.count ?? 0) < 32 {
        throw Abort(.internalServerError, reason: "Set JWT_SECRET to a random secret of at least 32 bytes in production.")
    }
    await app.jwt.keys.add(hmac: HMACKey(from: configuredSecret ?? "local-development-only-change-before-hosting"), digestAlgorithm: .sha256)
    app.passwords.use(.bcrypt)
    app.http.server.configuration.hostname = "0.0.0.0"
    app.http.server.configuration.port = Environment.get("PORT").flatMap(Int.init) ?? 8080
    app.routes.defaultMaxBodySize = "64kb"

    if let databaseURL = Environment.get("DATABASE_URL") {
        app.databases.use(try .postgres(url: databaseURL), as: .psql)
    } else {
        app.databases.use(.postgres(configuration: .init(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
            database: Environment.get("DATABASE_NAME") ?? "vapor_database",
            tls: .disable
        )), as: .psql)
    }

    app.migrations.add(CreateUsers())
    app.migrations.add(CreateNests())
    app.migrations.add(CreateNestMembers())
    app.migrations.add(CreateEntities())
    app.migrations.add(CreateTrackableActions())
    app.migrations.add(CreateActionEvents())
    app.migrations.add(CreateEntityPinnedActions())
    app.migrations.add(AddPerformanceIndexes())
    // Real deployments and clean local accounts should never receive sample family data.
    if app.environment == .development && Environment.get("SEED_DEMO_DATA") == "true" {
        app.migrations.add(SeedDevelopmentData())
    }
    _ = app.realtimeHub
    try routes(app)
}
