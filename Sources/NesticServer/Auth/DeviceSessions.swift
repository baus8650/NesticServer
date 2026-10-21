import Foundation
import Fluent
import Vapor
import JWT

/// Device credentials have no inactivity expiry. Only their hash is stored;
/// deleting the row revokes the credential on every server instance.
final class DeviceSession: Model, @unchecked Sendable {
    static let schema = "device_sessions"
    @ID(key: .id) var id: UUID?
    @Field(key: "user_id") var userID: UUID
    @Field(key: "token_hash") var tokenHash: String
    @Timestamp(key: "created_at", on: .create) var createdAt: Date?

    init() {}
    init(userID: UUID, token: String) {
        self.userID = userID
        self.tokenHash = authTokenHash(token)
    }
}

struct CreateDeviceSessions: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(DeviceSession.schema).id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("created_at", .datetime)
            .unique(on: "token_hash").create()
    }
    func revert(on db: any Database) async throws {
        try await db.schema(DeviceSession.schema).delete()
    }
}

struct NesticSessionAuthenticator: AsyncBearerAuthenticator {
    func authenticate(bearer: BearerAuthorization, for request: Request) async throws {
        if let session = try await request.resolveSession(bearer.token) {
            request.auth.login(session)
        }
    }
}

extension Request {
    func resolveSession(_ token: String) async throws -> SessionToken? {
        if token.hasPrefix("nestic_device_") {
            guard token.utf8.count == 57,
                  let device = try await DeviceSession.query(on: db)
                    .filter(\.$tokenHash == authTokenHash(token)).first(),
                  try await User.find(device.userID, on: db) != nil else { return nil }
            var session = SessionToken(userId: device.userID)
            session.deviceSessionID = try device.requireID()
            return session
        }
        return try? await application.jwt.keys.verify(token, as: SessionToken.self)
    }

    func issueDeviceSession(for user: User) async throws -> String {
        let value = "nestic_device_" + authTokenValue()
        try await DeviceSession(userID: user.requireID(), token: value).save(on: db)
        return value
    }

    func issueLoginToken(for user: User) async throws -> String {
        if headers.first(name: "X-Nestic-Persistent-Session") == "1" {
            return try await issueDeviceSession(for: user)
        }
        return try await jwt.sign(SessionToken(with: user))
    }
}
