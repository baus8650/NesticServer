import Fluent

struct CreateFeedback: AsyncMigration {
    func prepare(on db: any Database) async throws {
        try await db.schema("feedback_threads")
            .id()
            .field("user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("subject", .string, .required)
            .field("category", .string, .required)
            .field("status", .string, .required)
            .field("last_activity_at", .datetime, .required)
            .field("created_at", .datetime)
            .field("updated_at", .datetime)
            .create()

        try await db.schema("feedback_messages")
            .id()
            .field("thread_id", .uuid, .required, .references("feedback_threads", "id", onDelete: .cascade))
            .field("author_user_id", .uuid, .required, .references("users", "id", onDelete: .cascade))
            .field("body", .string, .required)
            .field("created_at", .datetime)
            .create()
    }

    func revert(on db: any Database) async throws {
        try await db.schema("feedback_messages").delete()
        try await db.schema("feedback_threads").delete()
    }
}
