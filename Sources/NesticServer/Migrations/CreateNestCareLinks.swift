import Fluent

struct CreateNestCareLinks: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(NestCareLink.schema)
            .id()
            .field("nest_id", .uuid, .required, .references("nests", "id", onDelete: .cascade))
            .field("created_by_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("token_hash", .string, .required)
            .field("label", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("entity_ids", .json, .required)
            .field("action_ids", .json, .required)
            .field("can_log", .bool, .required)
            .field("can_view_history", .bool, .required)
            .field("revoked_at", .datetime)
            .field("created_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(NestCareLink.schema).delete()
    }
}
