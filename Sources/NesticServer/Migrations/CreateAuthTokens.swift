import Fluent

struct CreateAuthTokens: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema(AuthToken.schema)
            .id()
            .field("user_id", .uuid, .required)
            .field("token_hash", .string, .required)
            .field("kind", .string, .required)
            .field("expires_at", .datetime, .required)
            .field("used_at", .datetime)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .unique(on: "token_hash")
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema(AuthToken.schema).delete()
    }
}
