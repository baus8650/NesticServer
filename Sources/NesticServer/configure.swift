import Foundation
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
    // The browser client is hosted separately from the API in production. Vapor's
    // origin-based configuration mirrors the requesting site without allowing
    // credentialed wildcard access.
    app.middleware.use(CORSMiddleware(configuration: .default()))
    // Subject avatars are compressed on-device before their binary upload to R2.
    app.routes.defaultMaxBodySize = "2mb"

    if let r2Configuration = R2StorageConfiguration() {
        app.r2Storage = R2Storage(configuration: r2Configuration)
        app.r2UsageLimiter = R2UsageLimiter()
        app.lifecycle.use(R2StorageLifecycle())
        app.logger.info("Cloudflare R2 photo storage is configured with usage limits", metadata: ["bucket": .string(r2Configuration.bucket)])
    } else {
        app.logger.warning("Cloudflare R2 photo storage is not configured; subject photo endpoints will return 503")
    }

    _ = app.authRateLimiter

    if let databaseURL = Environment.get("DATABASE_URL") {
        let postgresConfiguration = try postgresConfiguration(for: databaseURL)
        app.databases.use(.postgres(configuration: postgresConfiguration), as: .psql)
    } else {
        let postgresConfiguration = SQLPostgresConfiguration(
            hostname: Environment.get("DATABASE_HOST") ?? "localhost",
            port: Environment.get("DATABASE_PORT").flatMap(Int.init) ?? SQLPostgresConfiguration.ianaPortNumber,
            username: Environment.get("DATABASE_USERNAME") ?? "vapor_username",
            password: Environment.get("DATABASE_PASSWORD") ?? "vapor_password",
            database: Environment.get("DATABASE_NAME") ?? "vapor_database",
            tls: .disable
        )
        app.databases.use(.postgres(configuration: postgresConfiguration), as: .psql)
    }

    app.migrations.add(CreateUsers())
    app.migrations.add(AddAppleIdentity())
    app.migrations.add(CreateNests())
    app.migrations.add(CreateNestMembers())
    app.migrations.add(CreateEntities())
    app.migrations.add(CreateTrackableActions())
    app.migrations.add(AddTrackerSymbols())
    app.migrations.add(AddTrackerColors())
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

private func postgresConfiguration(for databaseURL: String) throws -> SQLPostgresConfiguration {
    guard Environment.get("DATABASE_TLS_MODE")?.lowercased() == "require-unverified" else {
        return try SQLPostgresConfiguration(url: databaseURL)
    }

    guard let url = URL(string: databaseURL),
          let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
          let hostname = components.host,
          hostname.hasSuffix(".railway.internal"),
          let username = components.user?.removingPercentEncoding else {
        throw Abort(.internalServerError, reason: "DATABASE_TLS_MODE=require-unverified requires Railway's private DATABASE_URL.")
    }

    var tlsConfiguration = TLSConfiguration.makeClientConfiguration()
    // Railway's stock Postgres image uses a deployment-local self-signed certificate.
    // Keep the connection encrypted, but do not require a public CA or hostname match.
    tlsConfiguration.certificateVerification = .none
    let tls = try PostgresConnection.Configuration.TLS.require(
        NIOSSLContext(configuration: tlsConfiguration)
    )

    let databasePath = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
    return SQLPostgresConfiguration(
        hostname: hostname,
        port: components.port ?? SQLPostgresConfiguration.ianaPortNumber,
        username: username,
        password: components.password?.removingPercentEncoding,
        database: databasePath.isEmpty ? nil : databasePath.removingPercentEncoding,
        tls: tls
    )
}
