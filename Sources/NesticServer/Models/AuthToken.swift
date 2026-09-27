import Fluent
import Vapor

final class AuthToken: Model, Content, @unchecked Sendable {
    static let schema = "auth_tokens"

    enum Kind: String, Codable, Sendable {
        case emailVerification = "email_verification"
        case passwordReset = "password_reset"
    }

    @ID(key: .id)
    var id: UUID?

    @Field(key: "user_id")
    var userID: UUID

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "kind")
    var kind: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @OptionalField(key: "used_at")
    var usedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    @Timestamp(key: "updated_at", on: .update)
    var updatedAt: Date?

    init() {}

    init(userID: UUID, kind: Kind, tokenHash: String, expiresAt: Date) {
        self.userID = userID
        self.kind = kind.rawValue
        self.tokenHash = tokenHash
        self.expiresAt = expiresAt
    }
}
