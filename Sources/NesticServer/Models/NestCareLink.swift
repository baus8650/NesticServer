import Fluent
import Vapor

/// A bearer link for short-lived, deliberately scoped caregiver access.
/// The raw token is only returned when the link is created; the database stores
/// its SHA-256 hash so a database read cannot be used to reconstruct a link.
final class NestCareLink: Model, Content, @unchecked Sendable {
    static let schema = "nest_care_links"

    @ID(key: .id)
    var id: UUID?

    @Parent(key: "nest_id")
    var nest: Nest

    @Parent(key: "created_by_user_id")
    var createdBy: User

    @Field(key: "token_hash")
    var tokenHash: String

    @Field(key: "label")
    var label: String

    @Field(key: "expires_at")
    var expiresAt: Date

    @Field(key: "entity_ids")
    var entityIDs: [UUID]

    @Field(key: "action_ids")
    var actionIDs: [UUID]

    @Field(key: "can_log")
    var canLog: Bool

    @Field(key: "can_view_history")
    var canViewHistory: Bool

    @OptionalField(key: "revoked_at")
    var revokedAt: Date?

    @Timestamp(key: "created_at", on: .create)
    var createdAt: Date?

    init() {}

    init(id: UUID? = nil, nestID: UUID, createdByUserID: UUID, tokenHash: String,
         label: String, expiresAt: Date, entityIDs: [UUID], actionIDs: [UUID],
         canLog: Bool, canViewHistory: Bool) {
        self.id = id
        self.$nest.id = nestID
        self.$createdBy.id = createdByUserID
        self.tokenHash = tokenHash
        self.label = label
        self.expiresAt = expiresAt
        self.entityIDs = entityIDs
        self.actionIDs = actionIDs
        self.canLog = canLog
        self.canViewHistory = canViewHistory
    }
}
